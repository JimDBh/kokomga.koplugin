--[[
    Bookshelf Integration
    Makes Komga a shelf source in the Bookshelf home screen plugin
    (AndyHazz/bookshelf.koplugin).

    A Komga shelf is an ordinary Bookshelf chip whose source is
    { kind = "komga", list = <list> }. It can be created from Bookshelf's own
    "Shelf source" picker or from kokomga's menu, and is then renamed, moved,
    given an icon or deleted in Bookshelf like any other chip.

    Bookshelf has no API for another plugin to add a source, so this wraps a
    handful of its module functions at runtime, the same way main.lua wraps
    kosync and readest. The data side is all-or-nothing: if any function it relies
    on is missing we install nothing, and Bookshelf behaves as if kokomga were not
    there (a saved Komga chip then shows an empty shelf -- getBySource returns
    nothing for a kind it does not know). The source picker entry is installed
    separately, so losing it costs only the picker row. Each wrapper guards its
    own work and falls back to Bookshelf's original, so a Bookshelf change should
    cost the Komga shelf, never the home screen.

    Books that are not downloaded yet behave like Bookshelf's OPDS catalog books:
    the first tap previews one in the hero, and the second tap, a long-press or a
    tap on the hero opens an info dialog offering the download. Downloaded books
    carry their real path and are ordinary local books.

    Written against Bookshelf v5.1.5.
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")

local KomgaBookshelf = {}

local SOURCE_KIND = "komga"
local SERIES_DRILL = "komga_series"
local PATH_PREFIX = "KOMGA://"

local LIST_LIMIT = 50            -- items on a shelf's own list
local RECENT_READ_SCAN = 200     -- books scanned to find the recently read series
local SERIES_BOOKS_LIMIT = 1000  -- books fetched when drilling into a series
local WANT_ALL_LIMIT = 100000    -- Bookshelf's select-all fetch wants everything
local MAX_CACHED_SERIES = 20     -- series drill-downs kept in the cache file
local RETRY_SECONDS = 60         -- minimum gap before retrying a failed refresh

KomgaBookshelf.LIST_MODES = { "recent_series", "new_series", "new_books" }
local DEFAULT_MODE = "recent_series"

local installed = false
local shelf_widget = nil      -- last Bookshelf widget that asked us for items
local pending_refresh = {}    -- "section|key" -> true while a refresh is queued
local last_failure = {}       -- "section|key" -> os.time() of the last failed refresh
local cover_attempted = {}    -- "type_id" -> true; a cover is tried once per session
local covers_pending = false

-- ---------------------------------------------------------------------------
-- Live state
-- ---------------------------------------------------------------------------

-- Bookshelf lives in the file manager, but its in-reader launcher can show it
-- over a book too, and KOReader replaces both instances whenever it switches
-- between them. Resolve per call rather than holding a reference.
local function liveModule(name)
    for _, mod in ipairs({ "apps/filemanager/filemanager", "apps/reader/readerui" }) do
        local ok, M = pcall(require, mod)
        local found = ok and M and M.instance and M.instance[name]
        if found then return found end
    end
end

-- The kokomga instance, only when it can talk to a Komga server.
local function livePlugin()
    local plugin = liveModule("kokomga")
    if plugin and plugin.settings and plugin.api and plugin.sync and plugin.cache then
        return plugin
    end
end

local function isOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return ok and NetworkMgr and NetworkMgr:isOnline() or false
end

local function fileExists(path)
    if type(path) ~= "string" then return false end
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(path, "mode") == "file"
end

local function isKomgaPath(path)
    return type(path) == "string" and path:sub(1, #PATH_PREFIX) == PATH_PREFIX
end

-- The Bookshelf widget currently on screen, if any.
local function shownShelf()
    if shelf_widget and UIManager:isWidgetShown(shelf_widget) then
        return shelf_widget
    end
    local bookshelf = liveModule("bookshelf")
    local widget = bookshelf and bookshelf._widget
    if widget and UIManager:isWidgetShown(widget) then
        return widget
    end
end

local function rebuildShelf()
    local widget = shownShelf()
    if not widget then return end
    local ok, err = xpcall(function() widget:_rebuild() end, debug.traceback)
    if not ok then
        logger.warn("KomgaBookshelf: shelf rebuild failed:", tostring(err))
    end
    UIManager:setDirty(widget, "ui")
end

local function listMode(source)
    local mode = type(source) == "table" and source.list
    for _, known in ipairs(KomgaBookshelf.LIST_MODES) do
        if known == mode then return mode end
    end
    return DEFAULT_MODE
end

function KomgaBookshelf.listLabel(plugin, mode)
    local _ = plugin and plugin.i18n and plugin.i18n._ or function(s) return s end
    if mode == "new_series" then return _("Recently Added Series") end
    if mode == "new_books" then return _("Recently Added Books") end
    return _("Recently Read Series")
end

-- ---------------------------------------------------------------------------
-- Cache file
-- ---------------------------------------------------------------------------

-- Kept out of kokomga.lua: a series drill can hold hundreds of chapters, and the
-- main settings file is rewritten on every save.
local cache_store = nil
local function store()
    if not cache_store then
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        cache_store = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_bookshelf.lua")
    end
    return cache_store
end

local function readEntry(section, key)
    local entries = store():readSetting(section) or {}
    return entries[key]
end

local function writeEntry(section, key, entry)
    local s = store()
    local entries = s:readSetting(section) or {}
    entries[key] = entry

    if section == "series" then
        local keys = {}
        for k, v in pairs(entries) do
            keys[#keys + 1] = { key = k, at = v.fetched_at or 0 }
        end
        if #keys > MAX_CACHED_SERIES then
            table.sort(keys, function(a, b) return a.at > b.at end)
            for i = MAX_CACHED_SERIES + 1, #keys do
                entries[keys[i].key] = nil
            end
        end
    end

    s:saveSetting(section, entries)
    s:flush()
end

local function isStale(plugin, entry)
    if not entry or not entry.fetched_at then return true end
    local minutes = tonumber(plugin.settings.cache_expiry_mins) or 60
    return os.time() - entry.fetched_at > minutes * 60
end

-- ---------------------------------------------------------------------------
-- Fetching from Komga
-- ---------------------------------------------------------------------------

-- Komga sends null for absent values (readProgress on any unread book, for
-- one), and KOReader's JSON decoder turns a null into a function sentinel, not
-- nil -- so `x or default` and `if x then` both let it through. Keep only
-- values of the type we expect: a null must never reach a field access, or the
-- cache file, which cannot store a function.
local function asTable(v) return type(v) == "table" and v or nil end
local function asString(v) return type(v) == "string" and v or nil end
local function asNumber(v) return type(v) == "number" and v or nil end
local function asScalar(v)
    local t = type(v)
    if t == "string" or t == "number" then return v end
end

-- Only the fields the record builders and getBookLocalPath need. A download
-- re-fetches the full book first, so nothing here has to be complete.
local function trimBook(book)
    local md = asTable(book.metadata) or {}
    local media = asTable(book.media) or {}
    local progress = asTable(book.readProgress)
    local authors = {}
    for _, a in ipairs(asTable(md.authors) or {}) do
        local name = asTable(a) and asString(a.name)
        if name and name ~= "" then
            authors[#authors + 1] = name
        end
    end
    return {
        id = asString(book.id),
        name = asString(book.name),
        seriesId = asString(book.seriesId),
        seriesTitle = asString(book.seriesTitle),
        oneshot = book.oneshot == true,
        lastModified = asString(book.lastModified),
        media = { mediaType = asString(media.mediaType), pagesCount = asNumber(media.pagesCount) },
        metadata = {
            title = asString(md.title),
            number = asScalar(md.number),
            summary = asString(md.summary),
        },
        authors = authors,
        readProgress = progress and {
            page = asNumber(progress.page),
            completed = progress.completed == true,
        } or nil,
    }
end

local function trimSeries(series)
    local md = asTable(series.metadata) or {}
    return {
        id = asString(series.id),
        title = asString(md.title) or asString(series.name),
        lastModified = asString(series.lastModified),
    }
end

local function contentOf(response)
    if type(response) == "table" and type(response.content) == "table" then
        return response.content
    end
end

local function listItemType(mode)
    return mode == "new_books" and "book" or "series"
end

local function fetchList(plugin, mode)
    local api = plugin.api
    local items = {}

    if mode == "new_series" then
        local content = contentOf(api:get_new_series(0, LIST_LIMIT))
        if not content then return nil end
        for _, series in ipairs(content) do
            local item = asTable(series) and trimSeries(series)
            if item and item.id then items[#items + 1] = item end
        end
    elseif mode == "new_books" then
        local content = contentOf(api:get_latest_books(0, LIST_LIMIT))
        if not content then return nil end
        for _, book in ipairs(content) do
            local item = asTable(book) and trimBook(book)
            if item and item.id then items[#items + 1] = item end
        end
    else
        -- Komga has no "recently read series" query, so walk the most recently
        -- read books and keep each series the first time it appears.
        local content = contentOf(api:get_books({
            read_status = { "IN_PROGRESS", "READ" },
            sort = "readProgress.readDate,desc",
        }, 0, RECENT_READ_SCAN))
        if not content then return nil end
        local seen = {}
        for _, book in ipairs(content) do
            local series_id = asTable(book) and asString(book.seriesId)
            if series_id and not seen[series_id] then
                seen[series_id] = true
                items[#items + 1] = {
                    id = series_id,
                    title = asString(book.seriesTitle) or asString(book.name),
                }
                if #items >= LIST_LIMIT then break end
            end
        end
    end

    return items
end

local function fetchSeriesBooks(plugin, series_id)
    local content = contentOf(plugin.api:get_books_for_series(series_id,
        { sort = "metadata.numberSort,asc" }, 0, SERIES_BOOKS_LIMIT))
    if not content then return nil end
    local items = {}
    for _, book in ipairs(content) do
        local item = asTable(book) and trimBook(book)
        if item and item.id then items[#items + 1] = item end
    end
    return items
end

-- Refresh one cache entry on the next tick, then repaint the shelf. Runs after
-- Bookshelf has painted, so a slow server never holds up the home screen.
local function scheduleRefresh(section, key, fetch)
    local id = section .. "|" .. tostring(key)
    if pending_refresh[id] then return end
    if last_failure[id] and os.time() - last_failure[id] < RETRY_SECONDS then return end
    if not isOnline() then return end

    pending_refresh[id] = true
    UIManager:nextTick(function()
        pending_refresh[id] = nil
        local plugin = livePlugin()
        if not plugin then return end

        local ok, items = pcall(fetch, plugin)
        if ok and items then
            last_failure[id] = nil
            logger.info("KomgaBookshelf: fetched", #items, "items for", id)
            writeEntry(section, key, { fetched_at = os.time(), items = items })
            rebuildShelf()
        else
            last_failure[id] = os.time()
            logger.warn("KomgaBookshelf: refresh failed for", id, ok and "" or tostring(items))
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Covers
-- ---------------------------------------------------------------------------

-- Same location KomgaCache:cacheThumbnail writes to.
local function coverFile(type_label, id)
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir() .. "/komga_covers/" .. type_label .. "_" .. id .. ".jpg"
end

local function existingCover(type_label, id)
    local path = coverFile(type_label, id)
    if fileExists(path) then return path end
end

local function noteMissingCover(missing, type_label, dto)
    local key = type_label .. "_" .. tostring(dto.id)
    if cover_attempted[key] then return end
    missing[#missing + 1] = { key = key, type_label = type_label, id = dto.id, lastModified = dto.lastModified }
end

-- Covers are fetched for the page on screen only: a series drill can hold
-- hundreds of chapters, and fetching all of their covers up front would stall
-- the shelf for minutes. Each cover is tried once per session, so a cover the
-- server cannot supply never loops the shelf through rebuilds. A cover counts
-- as tried only once it is actually queued: one skipped here because another
-- batch is still running, or because the device is offline, is picked up by a
-- later rebuild.
local function scheduleCovers(missing)
    if covers_pending or #missing == 0 or not isOnline() then return end
    for _, m in ipairs(missing) do cover_attempted[m.key] = true end
    covers_pending = true
    UIManager:nextTick(function()
        covers_pending = false
        local plugin = livePlugin()
        if not plugin then return end

        local fetched = 0
        for _, m in ipairs(missing) do
            local ok, path = pcall(plugin.cache.cacheThumbnail, plugin.cache,
                m.type_label, m.id, m.lastModified, true)
            if ok and path then fetched = fetched + 1 end
        end
        if fetched > 0 then rebuildShelf() end
    end)
end

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

local FORMATS = {
    ["application/zip"] = "CBZ",
    ["application/x-zip-compressed"] = "CBZ",
    ["application/pdf"] = "PDF",
    ["application/epub+zip"] = "EPUB",
    ["application/x-rar-compressed"] = "CBR",
    ["application/x-rar"] = "CBR",
}

-- getBookLocalPath shows an error popup when no download folder is set, which
-- would fire once per record. Check first and treat everything as not
-- downloaded instead.
local function hasDownloadDir(plugin)
    local dir = plugin.settings.download_dir
    if dir and dir ~= "" then return true end
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    return home ~= nil and home ~= ""
end

local function localPathIfDownloaded(plugin, dto)
    if not hasDownloadDir(plugin) then return nil end
    local ok, path = pcall(plugin.sync.getBookLocalPath, plugin.sync, dto, dto.seriesTitle)
    if ok and fileExists(path) then return path end
end

-- A book, shaped like the records Bookshelf's own Kobo source produces.
local function bookRecord(plugin, dto)
    local md = dto.metadata or {}
    local title = md.title or dto.name or "?"
    local local_path = localPathIfDownloaded(plugin, dto)

    local status, pct = "unread", 0
    local progress = dto.readProgress
    if progress then
        local pages = dto.media and dto.media.pagesCount
        if progress.completed then
            status, pct = "finished", 1
        else
            status = "reading"
            if pages and pages > 0 and progress.page then
                pct = math.min(progress.page / pages, 0.99)
            end
        end
    end

    local authors = dto.authors or {}
    local cover = existingCover("book", dto.id)

    return {
        -- The real file once downloaded, so Bookshelf opens it like any other
        -- local book; a synthetic path until then.
        filepath = local_path or (PATH_PREFIX .. "book/" .. dto.id),
        filename = dto.name or title,
        title = title,
        display_title = title,
        author = authors[1],
        authors = #authors > 0 and authors or nil,
        series_name = dto.seriesTitle,
        series_num = md.number and tostring(md.number) or nil,
        book_pct = pct,
        percent_finished = pct,
        status = status,
        read_status = status,
        added_time = 0,
        last_read_time = 0,
        last_opened = 0,
        attr = { mode = "file", size = 0, modification = 0 },
        format = FORMATS[dto.media and dto.media.mediaType or ""],
        cover_image_path = cover,
        has_cover = cover ~= nil,
        downloaded = local_path ~= nil,
        is_komga = true,
        komga_book_id = dto.id,
        komga_dto = dto,
    }
end

-- A series, as a folder card. Bookshelf draws the card's cover from first_book,
-- and SpineWidget renders any record carrying cover_image_path whatever its
-- filepath, so the series thumbnail stands in for a book.
local function seriesItem(dto)
    local path = PATH_PREFIX .. "series/" .. dto.id
    local title = dto.title or "?"
    local cover = existingCover("series", dto.id)
    return {
        kind = "folder",
        path = path,
        label = title,
        komga_series_id = dto.id,
        komga_series_title = title,
        first_book = cover and {
            filepath = path,
            title = title,
            display_title = title,
            cover_image_path = cover,
            has_cover = true,
            status = "unread",
            read_status = "unread",
            is_komga = true,
        } or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Shelf contents
-- ---------------------------------------------------------------------------

local function listSpec(mode)
    return {
        section = "lists", key = mode, item_type = listItemType(mode),
        fetch = function(plugin) return fetchList(plugin, mode) end,
    }
end

local function seriesSpec(series_id)
    return {
        section = "series", key = series_id, item_type = "book",
        fetch = function(plugin) return fetchSeriesBooks(plugin, series_id) end,
    }
end

-- One page of a shelf, as (items, total) -- the shape getBySource and
-- _fetchChipItems return. Only the shelf on screen may reach the network
-- (allow_network): Bookshelf also calls getBySource for every chip in the
-- background to preload them, and those calls must stay cache-only.
local function buildView(plugin, spec, offset, limit, allow_network, want_all)
    local entry = readEntry(spec.section, spec.key)
    if allow_network and isStale(plugin, entry) then
        scheduleRefresh(spec.section, spec.key, spec.fetch)
    end

    local all = entry and entry.items or {}
    local page, missing = {}, {}
    for i = offset + 1, math.min(offset + limit, #all) do
        local dto = all[i]
        if spec.item_type == "series" then
            local item = seriesItem(dto)
            if not item.first_book then noteMissingCover(missing, "series", dto) end
            page[#page + 1] = item
        else
            local record = bookRecord(plugin, dto)
            if not record.cover_image_path then noteMissingCover(missing, "book", dto) end
            page[#page + 1] = record
        end
    end

    if allow_network and not want_all then scheduleCovers(missing) end
    logger.dbg("KomgaBookshelf: view", spec.section, tostring(spec.key), "->", #page,
        "of", #all, "items, offset", offset, entry and "" or "(not fetched yet)")
    return page, #all
end

-- ---------------------------------------------------------------------------
-- Book info, download and open
-- ---------------------------------------------------------------------------

local function downloadAndOpen(plugin, record, open)
    local _ = plugin.i18n._
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local live = livePlugin() or plugin
        -- The cached record is trimmed; the download and the metadata written
        -- alongside it want the full book.
        local book = live.api:get_book(record.komga_book_id)
        if type(book) ~= "table" or not asString(book.id) then
            live:notify(_("Couldn't load this book from Komga."), "error")
            return
        end
        live.sync:downloadBook(book, asString(book.seriesTitle), open)
    end)
end

-- The counterpart of Bookshelf's OPDS catalog dialog (_showRemoteBookInfo),
-- built from the same pieces: its header (cover, title, author, summary) and
-- its Description view, with kokomga's download in place of the feed's formats.
local function showBookInfo(widget, plugin, record, open)
    local _ = plugin.i18n._
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}

    local local_path = localPathIfDownloaded(plugin, record.komga_dto or {})
    if local_path then
        buttons[#buttons + 1] = { {
            text = _("Open"),
            callback = function()
                UIManager:close(dialog)
                open(local_path)
            end,
        } }
    else
        buttons[#buttons + 1] = { {
            text = _("Download & Open"),
            callback = function()
                UIManager:close(dialog)
                downloadAndOpen(plugin, record, open)
            end,
        } }
    end

    -- Bookshelf's header and Description view read the summary from
    -- book.opds.summary. Hand them a copy carrying it, so the shelf's own
    -- records never look like OPDS entries to the rest of Bookshelf.
    local header_book = {}
    for k, v in pairs(record) do header_book[k] = v end
    local md = record.komga_dto and record.komga_dto.metadata
    header_book.opds = { summary = md and md.summary }

    local last_row = {}
    local ok_desc, desc_args = pcall(widget._remoteDescriptionArgs, widget, header_book)
    if ok_desc and desc_args then
        last_row[#last_row + 1] = {
            text = _("Description"),
            callback = function()
                UIManager:close(dialog)
                desc_args.bw = widget
                desc_args.header_builder = function(avail_w)
                    return widget:_buildRemoteBookHeader(header_book, avail_w, { summary_lines = 0 })
                end
                UIManager:show(require("lib/bookshelf_reviews_modal"):new(desc_args))
            end,
        }
    end
    last_row[#last_row + 1] = {
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    }
    buttons[#buttons + 1] = last_row

    dialog = ButtonDialog:new{ buttons = buttons }
    local ok_header, header = pcall(widget._buildRemoteBookHeader, widget, header_book,
        dialog:getAddedWidgetAvailableWidth(), { summary_lines = 5 })
    if ok_header and header then dialog:addWidget(header) end
    UIManager:show(dialog)
end

-- Komga shelves are always cover grids: series come through as folder cards,
-- which Bookshelf cannot stand on a spine shelf, and the list and spine views
-- are untested with them. A chip's display mode lives on the chip itself.
local function pinToCovers(tab)
    local ok, ViewMode = pcall(require, "lib/bookshelf_view_mode")
    local key = ok and ViewMode and ViewMode.CHIP_KEY or "view_mode"
    tab[key] = ok and ViewMode and ViewMode.COVERS or "covers"
end

-- ---------------------------------------------------------------------------
-- Bookshelf's shelf editor
-- ---------------------------------------------------------------------------

-- The editor's label table is local to its module, but the resolver it exports
-- for tests closes over it. Registering there names the source "Komga" in the
-- editor, and lets the editor's own defaults rename a fresh "New shelf" chip.
local function registerSourceLabel(resolve)
    if type(resolve) ~= "function" or type(debug) ~= "table" or not debug.getupvalue then return end
    for i = 1, 100 do
        local name, value = debug.getupvalue(resolve, i)
        if not name then return end
        if name == "SOURCE_LABEL" and type(value) == "table" then
            if value[SOURCE_KIND] == nil then
                value[SOURCE_KIND] = function() return "Komga" end
            end
            return
        end
    end
end

local function pickList(plugin, current, on_pick, on_cancel)
    local _ = plugin and plugin.i18n and plugin.i18n._ or function(s) return s end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local rows = {}
    for _i, mode in ipairs(KomgaBookshelf.LIST_MODES) do
        local prefix = (mode == current) and "\xE2\x9C\x93 " or "  "
        rows[#rows + 1] = { {
            text = prefix .. KomgaBookshelf.listLabel(plugin, mode),
            callback = function()
                UIManager:close(dialog)
                on_pick(mode)
            end,
        } }
    end
    rows[#rows + 1] = { {
        text = _("Cancel"),
        callback = function()
            UIManager:close(dialog)
            if on_cancel then on_cancel() end
        end,
    } }
    dialog = ButtonDialog:new{ title = "Komga", buttons = rows }
    UIManager:show(dialog)
end

-- A "Komga…" row for the "Shelf source" dialog, in the style of Bookshelf's
-- "Specific X…" buttons. Picking a list does what Bookshelf's own buttons do:
-- set the draft's source, apply the editor's source defaults, close, and hand
-- back to the editor.
local function sourcePickerRow(plugin, draft, on_close, apply_defaults, source_dialog)
    local is_komga = draft.source and draft.source.kind == SOURCE_KIND
    return { {
        text = (is_komga and "\xE2\x9C\x93 " or "  ") .. "Komga\xE2\x80\xA6",
        callback = function()
            local d = source_dialog()
            if d then UIManager:close(d) end
            pickList(plugin, is_komga and draft.source.list or nil, function(mode)
                draft.source = { kind = SOURCE_KIND, list = mode }
                if apply_defaults then pcall(apply_defaults, draft) end
                pinToCovers(draft)
                on_close()
            end, on_close)
        end,
    } }
end

-- The names a function closes over, mapped to their values.
local function upvaluesOf(fn)
    local out = {}
    if type(fn) ~= "function" or type(debug) ~= "table" or not debug.getupvalue then return out end
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        out[name] = value
    end
    return out
end

-- A Komga shelf has no sort or filter -- it keeps Komga's order and shows the
-- whole list -- and is always a cover grid. Bookshelf's editor hides its sort
-- and filter rows for OPDS shelves, but the check is hardcoded to that source,
-- so reshape the editor's rows as its dialog is built: drop Filters and Shelf
-- style, and turn the first sort button into the choice of Komga list.
--
-- The buttons are told apart by what their label functions close over, which
-- holds in every language: the sort buttons call _sortButtonText, Filters
-- reads Filter, Shelf style reads ViewMode, and all of them close over the
-- draft being edited -- which is how a Komga shelf is recognised at all. If
-- nothing matches, the rows are left exactly as they were.
local function reshapeEditorRows(rows)
    local draft
    local role = {}
    for _, row in ipairs(rows) do
        if type(row) == "table" then
            for _, button in ipairs(row) do
                if type(button) == "table" and type(button.text_func) == "function" then
                    local up = upvaluesOf(button.text_func)
                    if type(up.draft) == "table" then draft = draft or up.draft end
                    if up._sortButtonText ~= nil then
                        role[button] = "sort"
                    elseif up.Filter ~= nil then
                        role[button] = "filters"
                    elseif up.ViewMode ~= nil then
                        role[button] = "style"
                    end
                end
            end
        end
    end
    if not (draft and type(draft.source) == "table" and draft.source.kind == SOURCE_KIND) then
        return
    end

    local plugin = liveModule("kokomga")
    local list_button_kept = false
    for _, row in ipairs(rows) do
        if type(row) == "table" then
            local kept = {}
            for _, button in ipairs(row) do
                local r = role[button]
                if r == "sort" then
                    -- Its callback stays Bookshelf's own, which calls
                    -- _pickSortLevel and then marks the edit for saving;
                    -- _pickSortLevel is where the list picker takes over.
                    if not list_button_kept then
                        list_button_kept = true
                        button.text_func = function()
                            return "Komga: " .. KomgaBookshelf.listLabel(plugin, listMode(draft.source))
                        end
                        kept[#kept + 1] = button
                    end
                elseif r ~= "filters" and r ~= "style" then
                    kept[#kept + 1] = button
                end
            end
            for i = #row, 1, -1 do row[i] = nil end
            for i, button in ipairs(kept) do row[i] = button end
        end
    end
    -- The editor drops empty rows before building its table; do the same for
    -- the ones emptied here.
    for i = #rows, 1, -1 do
        if type(rows[i]) == "table" and #rows[i] == 0 then table.remove(rows, i) end
    end
end

-- Bookshelf builds the "Shelf source" dialog's rows as a local table inside
-- Editor:_pickSource and hands them straight to ButtonDialog:new, so there is no
-- list to append to. Instead, for the duration of that one synchronous call,
-- intercept the first ButtonDialog it creates -- the source dialog; every other
-- dialog it can open is created later, from a tap -- and add our row above
-- Cancel, where Bookshelf adds its own Kindle row.
local function installSourcePicker()
    local ok_editor, Editor = pcall(require, "lib/bookshelf_chip_editor")
    if not (ok_editor and type(Editor) == "table" and type(Editor._pickSource) == "function") then
        logger.info("KomgaBookshelf: Bookshelf's source picker not found; add Komga shelves from kokomga's menu")
        return
    end

    local exports = type(Editor._test) == "table" and Editor._test or {}
    local apply_defaults = type(exports.applySourceDefaults) == "function"
        and exports.applySourceDefaults or nil
    -- Komga shelves keep server order; don't let the editor seed a sort.
    if type(exports.SOURCE_SORT_DEFAULTS) == "table" and exports.SOURCE_SORT_DEFAULTS[SOURCE_KIND] == nil then
        exports.SOURCE_SORT_DEFAULTS[SOURCE_KIND] = {}
    end
    registerSourceLabel(exports.resolveSourceLabel)

    local ButtonDialog = require("ui/widget/buttondialog")
    local orig_pickSource = Editor._pickSource
    Editor._pickSource = function(editor, draft, on_close, ...)
        local plugin = livePlugin()
        if not (plugin and type(draft) == "table" and type(on_close) == "function") then
            return orig_pickSource(editor, draft, on_close, ...)
        end

        local own_new = rawget(ButtonDialog, "new")
        local inherited_new = ButtonDialog.new
        local source_dialog = nil
        local hooked = false
        ButtonDialog.new = function(cls, args, ...)
            if not hooked and cls == ButtonDialog and type(args) == "table"
                    and type(args.buttons) == "table" and #args.buttons > 0 then
                hooked = true
                local ok_row, row = pcall(sourcePickerRow, plugin, draft, on_close,
                    apply_defaults, function() return source_dialog end)
                if ok_row and row then
                    table.insert(args.buttons, #args.buttons, row)
                end
                source_dialog = inherited_new(cls, args, ...)
                return source_dialog
            end
            return inherited_new(cls, args, ...)
        end

        local ok, err = pcall(orig_pickSource, editor, draft, on_close, ...)
        rawset(ButtonDialog, "new", own_new)
        if not ok then error(err, 0) end
    end

    logger.info("KomgaBookshelf: Komga added to Bookshelf's source picker")

    -- The editor rebuilds its button table on every change, so reshaping it
    -- needs a standing hook rather than one scoped to a call. ButtonTable is
    -- KOReader's, used by every dialog: only a table built by the chip editor
    -- itself is touched, and only when it is editing a Komga shelf.
    if type(debug) == "table" and debug.getinfo and debug.getupvalue then
        local ButtonTable = require("ui/widget/buttontable")
        local inherited_new = ButtonTable.new
        rawset(ButtonTable, "new", function(cls, args, ...)
            if cls == ButtonTable and type(args) == "table" and type(args.buttons) == "table" then
                local caller = debug.getinfo(2, "S")
                local source = caller and caller.source
                if type(source) == "string" and source:find("bookshelf_chip_editor", 1, true) then
                    local ok, err = pcall(reshapeEditorRows, args.buttons)
                    if not ok then
                        logger.warn("KomgaBookshelf: editor reshape failed:", tostring(err))
                    end
                end
            end
            return inherited_new(cls, args, ...)
        end)
    end

    local function isKomgaDraft(draft)
        return type(draft) == "table" and type(draft.source) == "table"
            and draft.source.kind == SOURCE_KIND
    end

    -- The button that was the first sort level now picks the Komga list.
    -- on_close is Bookshelf's: it marks the edit for saving and redraws.
    if type(Editor._pickSortLevel) == "function" then
        local orig_pickSortLevel = Editor._pickSortLevel
        Editor._pickSortLevel = function(editor, draft, level, on_close, ...)
            if isKomgaDraft(draft) then
                pickList(liveModule("kokomga"), listMode(draft.source), function(mode)
                    draft.source.list = mode
                    if type(on_close) == "function" then on_close() end
                end)
                return
            end
            return orig_pickSortLevel(editor, draft, level, on_close, ...)
        end
    end

    -- Unreachable once the rows are reshaped; kept inert in case a Bookshelf
    -- change leaves them on screen.
    for _, name in ipairs({ "_openFilters", "_pickGroupDisplay" }) do
        if type(Editor[name]) == "function" then
            local orig = Editor[name]
            Editor[name] = function(editor, draft, ...)
                if isKomgaDraft(draft) then return end
                return orig(editor, draft, ...)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------

-- Wraps Bookshelf's functions. Called on the tick after kokomga initialises, so
-- Bookshelf has initialised too and loading its modules here is what it would do
-- itself on its first paint. Only ever succeeds once per session: the modules we
-- wrap live in package.loaded for the whole session.
function KomgaBookshelf.install(ui)
    if installed then return end
    -- No Bookshelf plugin in this context: nothing to integrate with yet.
    if not (ui and ui.bookshelf) then return end

    local ok_tab, TabModel = pcall(require, "lib/bookshelf_tab_model")
    local ok_widget, Widget = pcall(require, "lib/bookshelf_widget")
    local ok_repo, Repo = pcall(require, "lib/bookshelf_book_repository")
    if not (ok_tab and ok_widget and ok_repo
            and type(TabModel) == "table" and type(Widget) == "table" and type(Repo) == "table") then
        logger.info("KomgaBookshelf: Bookshelf modules not found, integration not installed")
        return
    end

    -- All-or-nothing: a partial install could show a shelf with nothing behind it.
    local required = {
        ["TabModel.getById"] = TabModel.getById,
        ["TabModel.load"] = TabModel.load,
        ["TabModel.save"] = TabModel.save,
        ["BookshelfWidget._fetchChipItems"] = Widget._fetchChipItems,
        ["BookshelfWidget._expandFolder"] = Widget._expandFolder,
        ["BookshelfWidget._openBook"] = Widget._openBook,
        ["BookshelfWidget._drillInto"] = Widget._drillInto,
        ["BookshelfWidget._viewSize"] = Widget._viewSize,
        ["BookshelfWidget._rebuild"] = Widget._rebuild,
        ["BookshelfWidget._isRemoteRecord"] = Widget._isRemoteRecord,
        ["BookshelfWidget._showRemoteBookInfo"] = Widget._showRemoteBookInfo,
        ["BookshelfWidget._buildRemoteBookHeader"] = Widget._buildRemoteBookHeader,
        ["BookshelfWidget._remoteDescriptionArgs"] = Widget._remoteDescriptionArgs,
        ["Repo.getBySource"] = Repo.getBySource,
        ["Repo.getFolderBookPaths"] = Repo.getFolderBookPaths,
        ["Repo.buildBookMeta"] = Repo.buildBookMeta,
    }
    for name, fn in pairs(required) do
        if type(fn) ~= "function" then
            logger.info("KomgaBookshelf: Bookshelf has no " .. name .. ", integration not installed")
            return
        end
    end
    installed = true

    -- A Komga shelf's list, for every caller: Bookshelf preloads each chip in the
    -- background and asks for counts through here too. Cache-only -- the shelf on
    -- screen refreshes through _fetchChipItems below.
    local orig_getBySource = Repo.getBySource
    Repo.getBySource = function(source, filter, sort_priority, offset, limit, opts, ...)
        if type(source) == "table" and source.kind == SOURCE_KIND then
            local plugin = livePlugin()
            if not plugin then return {}, 0 end
            local ok, items, total = xpcall(function()
                return buildView(plugin, listSpec(listMode(source)),
                    offset or 0, limit or WANT_ALL_LIMIT, false, false)
            end, debug.traceback)
            if ok then return items, total end
            logger.warn("KomgaBookshelf: building a Komga shelf failed:", tostring(items))
            return {}, 0
        end
        return orig_getBySource(source, filter, sort_priority, offset, limit, opts, ...)
    end

    -- The shelf on screen: the chip's list, or a drilled-into series. This is the
    -- path allowed to refresh from the server.
    local orig_fetchChipItems = Widget._fetchChipItems
    Widget._fetchChipItems = function(widget, n, want_all)
        local plugin = livePlugin()
        if plugin then
            local path = widget._drilldown_path
            local tip = path and path[#path]
            local spec
            if tip then
                if tip.kind == SERIES_DRILL and tip.payload and tip.payload.series_id then
                    spec = seriesSpec(tip.payload.series_id)
                end
            else
                local tab = TabModel.getById(widget.chip)
                local source = tab and tab.source
                if type(source) == "table" and source.kind == SOURCE_KIND then
                    spec = listSpec(listMode(source))
                end
            end
            if spec then
                shelf_widget = widget
                local offset = want_all and 0 or math.max(0, (widget._cursor or 1) - 1)
                local limit = want_all and WANT_ALL_LIMIT or widget:_viewSize()
                local ok, items, total = xpcall(function()
                    return buildView(plugin, spec, offset, limit, true, want_all)
                end, debug.traceback)
                if ok then return items, total end
                logger.warn("KomgaBookshelf: building the Komga shelf failed:", tostring(items))
                return {}, 0
            end
        end
        return orig_fetchChipItems(widget, n, want_all)
    end

    -- Tapping a series card drills in, like a folder, but into our own level.
    local orig_expandFolder = Widget._expandFolder
    Widget._expandFolder = function(widget, folder, ...)
        if type(folder) == "table" and folder.komga_series_id then
            -- Never hand a synthetic path to the original: it would drill into
            -- a filesystem folder that does not exist.
            local ok, err = pcall(widget._drillInto, widget, {
                kind = SERIES_DRILL,
                label = folder.komga_series_title or folder.label,
                payload = {
                    series_id = folder.komga_series_id,
                    series_title = folder.komga_series_title,
                },
            })
            if not ok then
                logger.warn("KomgaBookshelf: opening series failed:", tostring(err))
            end
            return
        end
        return orig_expandFolder(widget, folder, ...)
    end

    -- Long-pressing a folder card opens Bookshelf's folder menu -- pin, move,
    -- rename, set image -- all of which act on a directory, and a series card has
    -- none (pinning one would create a chip pointing at a synthetic path). Treat
    -- the long-press on a series card as a tap instead.
    if type(Widget._openGroupMenu) == "function" then
        local orig_openGroupMenu = Widget._openGroupMenu
        Widget._openGroupMenu = function(widget, group, kind, ...)
            if type(group) == "table" and group.komga_series_id then
                return widget:_expandFolder(group)
            end
            return orig_openGroupMenu(widget, group, kind, ...)
        end
    end

    -- Opens a Komga book once it is on disk, through Bookshelf's normal open.
    local orig_openBook = Widget._openBook
    local function opener(widget, book, after_open_callback)
        return function(path)
            local record = {}
            for k, v in pairs(book) do record[k] = v end
            record.filepath = path
            record.downloaded = true
            return orig_openBook(widget, record, after_open_callback)
        end
    end

    -- Opening a Komga book: straight in when it is on disk, otherwise the info
    -- dialog with the download -- as Bookshelf does for an OPDS catalog book.
    Widget._openBook = function(widget, book, after_open_callback, ...)
        if type(book) == "table" and book.is_komga and book.komga_book_id then
            local plugin = livePlugin()
            if plugin then
                local open = opener(widget, book, after_open_callback)
                -- Recheck on every tap: the file may have been downloaded or
                -- deleted since this record was built.
                local ok_path, local_path = pcall(localPathIfDownloaded, plugin, book.komga_dto or {})
                if ok_path and local_path then
                    return open(local_path)
                end
                local ok, err = pcall(showBookInfo, widget, plugin, book, open)
                if ok then return end
                logger.warn("KomgaBookshelf: book info failed:", tostring(err))
            end
            -- A synthetic path is not a file; never let the original try to
            -- open one.
            if isKomgaPath(book.filepath) then return end
        end
        return orig_openBook(widget, book, after_open_callback, ...)
    end

    -- A synthetic path has no file behind it. Bookshelf keeps its own OPDS
    -- pseudo-paths away from everything that needs one -- background cover
    -- extraction (which otherwise crashes coverbrowser's subprocess and retries
    -- forever), stats, ratings, selection, hero hydration -- by asking
    -- _isRemoteRecord, so answer yes for ours too. Downloaded books carry their
    -- real path and stay ordinary local books.
    local orig_isRemoteRecord = Widget._isRemoteRecord
    Widget._isRemoteRecord = function(widget, book, ...)
        local path = type(book) == "string" and book or (type(book) == "table" and book.filepath)
        if isKomgaPath(path) then return true end
        return orig_isRemoteRecord(widget, book, ...)
    end

    -- A remote book's second tap and long-press both land here, in Bookshelf's
    -- OPDS catalog dialog. Show ours instead: it is built from the same pieces,
    -- with kokomga's download in place of the feed's formats.
    local orig_showRemoteBookInfo = Widget._showRemoteBookInfo
    Widget._showRemoteBookInfo = function(widget, book, ...)
        if type(book) == "table" and book.is_komga then
            local plugin = livePlugin()
            if plugin and book.komga_book_id then
                local ok, err = pcall(showBookInfo, widget, plugin, book, opener(widget, book))
                if not ok then
                    logger.warn("KomgaBookshelf: book info failed:", tostring(err))
                end
            end
            return
        end
        return orig_showRemoteBookInfo(widget, book, ...)
    end

    -- Fetches an OPDS thumbnail for the previewed record; there is no feed
    -- behind ours. Optional: older Bookshelf builds may not have it.
    if type(Widget._opdsEnsurePreviewCover) == "function" then
        local orig_ensurePreviewCover = Widget._opdsEnsurePreviewCover
        Widget._opdsEnsurePreviewCover = function(widget, book, ...)
            if type(book) == "table" and book.is_komga then return end
            return orig_ensurePreviewCover(widget, book, ...)
        end
    end

    -- Bookshelf rebuilds records from their path in several places -- the hero
    -- after a tap, the status-strip probe, a collapse from expanded view -- and
    -- for a path with no file behind it would build a bare stand-in: no cover,
    -- the raw id as the title. Bookshelf bows out for its own OPDS pseudo-paths
    -- here for exactly that reason, and every caller then keeps the record it
    -- already holds (Repo.buildBook goes through this too). Do the same.
    local orig_buildBookMeta = Repo.buildBookMeta
    Repo.buildBookMeta = function(filepath, ...)
        if isKomgaPath(filepath) then return nil end
        return orig_buildBookMeta(filepath, ...)
    end

    -- Folder cards look up their books on disk when the count badge, selection
    -- or collage mode is on. A series card's path is synthetic, so skip the walk.
    local orig_getFolderBookPaths = Repo.getFolderBookPaths
    Repo.getFolderBookPaths = function(path, ...)
        if isKomgaPath(path) then return {} end
        return orig_getFolderBookPaths(path, ...)
    end

    logger.info("KomgaBookshelf: Bookshelf integration installed")

    -- Separate from the data side: without it, shelves can still be added from
    -- kokomga's menu.
    local ok_picker, err_picker = pcall(installSourcePicker)
    if not ok_picker then
        logger.warn("KomgaBookshelf: source picker hook failed:", tostring(err_picker))
    end

    -- The shelf may already have painted before the wrappers were in place.
    rebuildShelf()
end

function KomgaBookshelf.isAvailable()
    return installed
end

-- Adds a Komga shelf to Bookshelf, the way Bookshelf itself pins a collection
-- as a chip, and switches the shelf on screen to it.
function KomgaBookshelf.addShelf(mode)
    if not installed then return false end
    local TabModel = package.loaded["lib/bookshelf_tab_model"]
    if not TabModel then return false end

    local tabs = TabModel.load()
    local n = 1
    while true do
        local candidate = "custom_" .. n
        local taken = false
        for _, t in ipairs(tabs) do
            if t.id == candidate then taken = true; break end
        end
        if not taken then break end
        n = n + 1
    end
    local id = "custom_" .. n

    local tab = {
        id = id,
        label = "Komga",
        source = { kind = SOURCE_KIND, list = listMode({ list = mode }) },
        filter = {},
        sort_priority = {},
        enabled = true,
    }
    pinToCovers(tab)
    tabs[#tabs + 1] = tab
    TabModel.save(tabs)

    local widget = shownShelf()
    if widget and type(widget._selectChip) == "function" then
        pcall(widget._selectChip, widget, id)
    end
    return true
end

return KomgaBookshelf
