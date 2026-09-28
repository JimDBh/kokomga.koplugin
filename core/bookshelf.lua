--[[
    Bookshelf Integration
    Makes Komga a shelf source in the Bookshelf home screen plugin
    (AndyHazz/bookshelf.koplugin).

    A Komga shelf is an ordinary Bookshelf shelf whose source is
    { kind = "komga", list = <list>, ... }. It is created from Bookshelf's own
    "Shelf source" picker, and renamed, moved or deleted in Bookshelf like any
    other shelf.

    Registered through Bookshelf's shelf source API (SOURCE_API 1, see its
    SOURCE_API.md) as a fetch-mode source: Komga pages and orders the shelf,
    series and collections are folders to drill into, and books not on the
    device yet live under komga://. Nothing of Bookshelf's is replaced. A
    Bookshelf without the API simply has no Komga shelves.

    Books that are not downloaded yet behave like Bookshelf's OPDS catalog books:
    the first tap previews one in the hero, the second offers the download, and a
    long-press shows its details. Downloaded books carry their real path and are
    ordinary local books.
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")

local KomgaBookshelf = {}

local SOURCE_KIND = "komga"
local SERIES_DRILL = "komga_series"
local COLLECTION_DRILL = "komga_collection"
local PATH_PREFIX = "komga://"

local LIST_LIMIT = 50            -- items on a "recent" shelf's own list
local ONE_SHOTS_LIMIT = 1000     -- one-shots are listed by title, so keep far more
local COLLECTIONS_LIMIT = 200    -- collections on the Collections shelf
local SERIES_BOOKS_LIMIT = 1000  -- books fetched when drilling into a series
local COLLECTION_SERIES_LIMIT = 500 -- series fetched when drilling into a collection
local WANT_ALL_LIMIT = 100000    -- Bookshelf's select-all fetch wants everything
local WANT_ALL_FROM = 1000       -- a fetch this large is a select-all, not a screen
local MAX_CACHED_DRILLS = 20     -- series / collection drill-downs kept per section
local MAX_CACHED_PAGES = 60      -- All Series pages kept (60 x 50 series)
local PAGE_SIZE = 50             -- All Series is fetched from Komga in pages of this size
local RETRY_SECONDS = 60         -- minimum gap before retrying a failed refresh

-- All Series first, then the order of kokomga's browser home page, plus
-- Recently Read Series.
KomgaBookshelf.LIST_MODES = {
    "all_series", "keep_reading", "on_deck", "recent_series", "new_series",
    "new_books", "one_shots", "collections",
}
local DEFAULT_MODE = "all_series"

local registered = false
local last_offset = {}        -- spec key -> offset last shown, for pull-down refresh
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

-- Tells Bookshelf that Komga has more to show; it redraws the shelf if a Komga
-- shelf is on screen.
local function notifyChanged()
    local bookshelf = liveModule("bookshelf")
    if bookshelf and type(bookshelf.sourceChanged) == "function" then
        local ok, err = pcall(bookshelf.sourceChanged, bookshelf, SOURCE_KIND)
        if not ok then logger.warn("KomgaBookshelf: sourceChanged failed:", tostring(err)) end
    end
end

local function listMode(source)
    local mode = type(source) == "table" and source.list
    for _, known in ipairs(KomgaBookshelf.LIST_MODES) do
        if known == mode then return mode end
    end
    return DEFAULT_MODE
end

-- Labels reuse the browser home page's own strings, already translated.
local LIST_LABELS = {
    all_series = "All Series",
    keep_reading = "Keep Reading",
    on_deck = "On Deck",
    recent_series = "Recently Read Series",
    new_series = "Recently Added Series",
    new_books = "Recently Added Books",
    one_shots = "One-Shots",
    collections = "Collections",
}

local function gettext(plugin)
    return plugin and plugin.i18n and plugin.i18n._ or function(s) return s end
end

local function template(plugin)
    return plugin and plugin.i18n and plugin.i18n.T or function(s, a) return (s:gsub("%%1", tostring(a))) end
end

function KomgaBookshelf.listLabel(plugin, mode)
    local _ = gettext(plugin)
    return _(LIST_LABELS[mode] or LIST_LABELS[DEFAULT_MODE])
end

-- A filter's chosen values that are among `allowed`, in its order, or nil to
-- show everything -- which is what choosing none, or all of them, means. A
-- shelf saved before several could be chosen holds one value as a string.
local function chosenValues(value, allowed)
    if type(value) == "string" then value = { value } end
    if type(value) ~= "table" then return nil end
    local chosen = {}
    for _i, v in ipairs(value) do chosen[v] = true end
    local out = {}
    for _i, v in ipairs(allowed) do
        if chosen[v] then out[#out + 1] = v end
    end
    if #out == 0 or #out == #allowed then return nil end
    return out
end

-- The read states a shelf can be filtered to, in Komga's terms.
local READ_FILTERS = { "UNREAD", "IN_PROGRESS", "READ" }

local function readFilter(source)
    return chosenValues(type(source) == "table" and source.read_status, READ_FILTERS)
end

-- The browser's own labels for the three states.
local function readStateLabel(plugin, state)
    local _ = gettext(plugin)
    if state == "UNREAD" then return _("Unread") end
    if state == "IN_PROGRESS" then return _("In Progress") end
    return _("Completed")
end

local function readFilterLabel(plugin, filter)
    if not filter then return gettext(plugin)("All") end
    local labels = {}
    for _i, state in ipairs(filter) do labels[#labels + 1] = readStateLabel(plugin, state) end
    return table.concat(labels, ", ")
end

-- All Series is sorted and filtered by Komga. These are the sort keys Komga's
-- series query accepts.
local SERIES_SORTS = {
    { value = "metadata.titleSort,asc", label = "Title" },
    { value = "metadata.titleSort,desc", label = "Title (Z-A)" },
    { value = "createdDate,desc", label = "Recently Added" },
    { value = "lastModifiedDate,desc", label = "Recently Updated" },
    { value = "readDate,desc", label = "Recently Read" },
    { value = "booksMetadata.releaseDate,desc", label = "Release Date" },
    { value = "booksCount,desc", label = "Book Count" },
}

local PUBLICATION_STATUSES = {
    { value = "ONGOING", label = "Ongoing" },
    { value = "ENDED", label = "Ended" },
    { value = "HIATUS", label = "Hiatus" },
    { value = "ABANDONED", label = "Abandoned" },
}

local function known(options, value)
    for _i, option in ipairs(options) do
        if option.value == value then return option end
    end
end

local function seriesSort(source)
    local option = known(SERIES_SORTS, type(source) == "table" and source.sort)
    return (option or SERIES_SORTS[1]).value
end

local PUBLICATION_VALUES = {}
for _i, option in ipairs(PUBLICATION_STATUSES) do
    PUBLICATION_VALUES[#PUBLICATION_VALUES + 1] = option.value
end

local function publicationFilter(source)
    return chosenValues(type(source) == "table" and source.status, PUBLICATION_VALUES)
end

-- Library ids are only known once Komga has been asked, so "all of them" is
-- settled when they are chosen (see pickLibrary) rather than here.
local function libraryFilter(source)
    local value = type(source) == "table" and source.library_id
    if type(value) == "string" then value = { value } end
    if type(value) ~= "table" then return nil end
    local out = {}
    for _i, id in ipairs(value) do
        if type(id) == "string" and id ~= "" then out[#out + 1] = id end
    end
    return #out > 0 and out or nil
end

local function optionLabel(plugin, options, value, fallback)
    local option = known(options, value)
    return gettext(plugin)(option and option.label or fallback)
end

local function publicationLabel(plugin, filter)
    if not filter then return gettext(plugin)("Any") end
    local labels = {}
    for _i, value in ipairs(filter) do
        labels[#labels + 1] = optionLabel(plugin, PUBLICATION_STATUSES, value, value)
    end
    return table.concat(labels, ", ")
end

-- Library names are stored with their ids, so the editor can show them
-- offline. A shelf saved before several could be chosen holds one name.
local function libraryLabel(plugin, source)
    local ids = libraryFilter(source)
    if not ids then return gettext(plugin)("All Libraries") end
    local names = type(source.library_names) == "table" and source.library_names or {}
    local labels = {}
    for _i, id in ipairs(ids) do
        labels[#labels + 1] = names[id] or (#ids == 1 and source.library_name) or id
    end
    return table.concat(labels, ", ")
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

    -- Drill-downs and All Series pages are keyed by id or query and would
    -- otherwise accumulate forever; keep the most recently fetched. The shelf
    -- lists are a fixed handful.
    if section ~= "lists" then
        local cap = section == "pages" and MAX_CACHED_PAGES or MAX_CACHED_DRILLS
        local keys = {}
        for k, v in pairs(entries) do
            keys[#keys + 1] = { key = k, at = v.fetched_at or 0 }
        end
        if #keys > cap then
            table.sort(keys, function(a, b) return a.at > b.at end)
            for i = cap + 1, #keys do
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
        summary = asString(md.summary),
        lastModified = asString(series.lastModified),
        -- Komga's own tallies, for the unread badge, the read state and the
        -- read-status filter.
        booksCount = asNumber(series.booksCount),
        booksReadCount = asNumber(series.booksReadCount),
        booksUnreadCount = asNumber(series.booksUnreadCount),
        booksInProgressCount = asNumber(series.booksInProgressCount),
    }
end

local function trimCollection(collection)
    return {
        id = asString(collection.id),
        title = asString(collection.name),
        lastModified = asString(collection.lastModifiedDate),
    }
end

-- Komga answers with a page ({ content = [...] }); an unpaged request may hand
-- back the array itself, which the browser's One-Shots list allows for too.
local function contentOf(response)
    if type(response) ~= "table" then return nil end
    if type(response.content) == "table" then return response.content end
    if response[1] ~= nil then return response end
end

local LIST_ITEM_TYPES = {
    all_series = "series",
    recent_series = "series",
    new_series = "series",
    collections = "collection",
}

local function listItemType(mode)
    return LIST_ITEM_TYPES[mode] or "book"
end

local function trimBooks(content, limit)
    local items = {}
    for _, book in ipairs(content) do
        local item = asTable(book) and trimBook(book)
        if item and item.id then items[#items + 1] = item end
        if limit and #items >= limit then break end
    end
    return items
end

-- Title order for one-shots, shared with the browser's One-Shots list so the
-- two agree. Falls back to a plain case-insensitive sort.
local function sortByTitle(items)
    local ok, Browser = pcall(require, "ui/browser")
    if ok and type(Browser) == "table" and type(Browser.sortBooksByVisibleTitle) == "function"
            and pcall(Browser.sortBooksByVisibleTitle, items) then
        return
    end
    local function key(item)
        local md = item.metadata or {}
        return tostring(md.title or item.name or ""):lower()
    end
    table.sort(items, function(a, b) return key(a) < key(b) end)
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
        items = trimBooks(content)
    elseif mode == "keep_reading" then
        -- The browser's Keep Reading query.
        local content = contentOf(api:get_books({
            read_status = "IN_PROGRESS",
            sort = "readProgress.readDate,desc",
        }, 0, LIST_LIMIT))
        if not content then return nil end
        items = trimBooks(content)
    elseif mode == "on_deck" then
        local content = contentOf(api:get_books_ondeck(0, LIST_LIMIT))
        if not content then return nil end
        items = trimBooks(content)
    elseif mode == "one_shots" then
        -- Komga returns every one-shot unpaged; order them as the browser does,
        -- then cap.
        local content = contentOf(api:get_one_shots())
        if not content then return nil end
        items = trimBooks(content)
        sortByTitle(items)
        for i = #items, ONE_SHOTS_LIMIT + 1, -1 do items[i] = nil end
    elseif mode == "collections" then
        local content = contentOf(api:get_collections(0, COLLECTIONS_LIMIT))
        if not content then return nil end
        for _, collection in ipairs(content) do
            local item = asTable(collection) and trimCollection(collection)
            if item and item.id then items[#items + 1] = item end
        end
    else
        -- Series you have started, most recently read first: Komga sorts
        -- series by their last read date, and the answer carries each series'
        -- read counts.
        local content = contentOf(api:query_series{
            read_status = { "IN_PROGRESS", "READ" },
            sort = "readDate,desc",
            page = 0, size = LIST_LIMIT,
        })
        if not content then return nil end
        for _, series in ipairs(content) do
            local item = asTable(series) and trimSeries(series)
            if item and item.id then items[#items + 1] = item end
        end
    end

    return items
end

local function fetchSeriesBooks(plugin, series_id)
    local content = contentOf(plugin.api:get_books_for_series(series_id,
        { sort = "metadata.numberSort,asc" }, 0, SERIES_BOOKS_LIMIT))
    if not content then return nil end
    return trimBooks(content)
end

-- A collection's series, in the collection's own order.
local function fetchCollectionSeries(plugin, collection_id)
    local content = contentOf(plugin.api:get_series_for_collection(collection_id,
        0, COLLECTION_SERIES_LIMIT))
    if not content then return nil end
    local items = {}
    for _, series in ipairs(content) do
        local item = asTable(series) and trimSeries(series)
        if item and item.id then items[#items + 1] = item end
    end
    return items
end

-- Refresh one cache entry on the next tick, then repaint the shelf. Runs after
-- Bookshelf has painted, so a slow server never holds up the home screen.
-- A fetch returns a list, or for an All Series page { items = …, total = … }
-- with Komga's total. Either becomes a cache entry.
local function entryFromResult(result)
    if type(result) ~= "table" then return nil end
    if type(result.items) == "table" then
        return { fetched_at = os.time(), items = result.items, total = result.total }
    end
    return { fetched_at = os.time(), items = result }
end

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

        local ok, result = pcall(fetch, plugin)
        local entry = ok and entryFromResult(result)
        if entry then
            last_failure[id] = nil
            logger.info("KomgaBookshelf: fetched", #entry.items, "items for", id)
            writeEntry(section, key, entry)
            notifyChanged()
        else
            last_failure[id] = os.time()
            logger.warn("KomgaBookshelf: refresh failed for", id, ok and "" or tostring(result))
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Series summaries
-- ---------------------------------------------------------------------------

-- Chapters rarely have a summary of their own, so a book shows its series'
-- summary instead. Summaries are remembered from every series list fetched,
-- and looked up for the books on screen whose series has not been seen.
local SUMMARY_CAP = 300          -- series summaries remembered
local summary_attempted = {}     -- series id -> true; looked up once per session
local summaries_pending = false

local function seriesSummaries()
    local entry = readEntry("meta", "series_summaries")
    return entry and entry.items or {}
end

-- Komga sends an empty summary as "", which Lua counts as true: treat it as
-- none, or it hides the series' summary.
local function nonEmpty(s)
    return type(s) == "string" and s:match("%S") and s or nil
end

-- Remembers { id, summary } records; "" marks a series known to have none. A
-- series cached before summaries were kept has no summary field at all, and is
-- left unknown so it is still looked up.
local function rememberSummaries(list)
    local map = seriesSummaries()
    local changed = false
    for _i, series in ipairs(list) do
        if type(series.id) == "string" and type(series.summary) == "string" then
            local value = nonEmpty(series.summary) or ""
            if not map[series.id] or map[series.id].s ~= value then
                map[series.id] = { s = value, t = os.time() }
                changed = true
            end
        end
    end
    if not changed then return end
    local ids = {}
    for id, v in pairs(map) do ids[#ids + 1] = { id = id, t = v.t or 0 } end
    if #ids > SUMMARY_CAP then
        table.sort(ids, function(a, b) return a.t > b.t end)
        for i = SUMMARY_CAP + 1, #ids do map[ids[i].id] = nil end
    end
    writeEntry("meta", "series_summaries", { fetched_at = os.time(), items = map })
end

-- The series' summary, and whether the series has been seen at all.
local function seriesSummary(series_id)
    local v = type(series_id) == "string" and seriesSummaries()[series_id] or nil
    return v and v.s ~= "" and v.s or nil, v ~= nil
end

-- Looks up the series of books on screen that have not been seen yet, then
-- repaints. Each series is tried once per session.
local function scheduleSummaries(series_ids)
    if summaries_pending or #series_ids == 0 or not isOnline() then return end
    for _i, id in ipairs(series_ids) do summary_attempted[id] = true end
    summaries_pending = true
    UIManager:nextTick(function()
        summaries_pending = false
        local plugin = livePlugin()
        if not plugin then return end
        local found = {}
        for _i, id in ipairs(series_ids) do
            local ok, series = pcall(plugin.api.get_series_detail, plugin.api, id)
            if ok and type(series) == "table" then
                local item = trimSeries(series)
                if item.id then found[#found + 1] = item end
            end
        end
        if #found > 0 then
            rememberSummaries(found)
            notifyChanged()
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
        if fetched > 0 then notifyChanged() end
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

-- A book's read state from its Komga progress, and how far through it is.
local function bookStatus(dto)
    local progress = dto.readProgress
    if not progress then return "unread", 0 end
    if progress.completed then return "finished", 1 end
    local pages = dto.media and dto.media.pagesCount
    if pages and pages > 0 and progress.page then
        return "reading", math.min(progress.page / pages, 0.99)
    end
    return "reading", 0
end

-- A book, shaped like the records Bookshelf's own Kobo source produces.
-- fallback_summary is the series' summary, shown when the book has none of its
-- own -- chapters rarely do.
local function bookRecord(plugin, dto, fallback_summary)
    local md = dto.metadata or {}
    local title = md.title or dto.name or "?"
    local local_path = localPathIfDownloaded(plugin, dto)
    local status, pct = bookStatus(dto)

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
        -- The hero card's description: the book's own summary, else its
        -- series'. (No page_count: Bookshelf draws its page-count pill in the
        -- corner the downloaded tick uses, and the pill wins.)
        description = nonEmpty(md.summary) or seriesSummary(dto.seriesId) or nonEmpty(fallback_summary),
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

-- A series' read state from Komga's tallies: "finished" once every book is
-- read, "reading" once any book is read or started, "unread" otherwise.
local function seriesStatus(dto)
    local total = dto.booksCount
    local read = dto.booksReadCount or 0
    if total and total > 0 and read >= total then return "finished" end
    if read > 0 or (dto.booksInProgressCount or 0) > 0 then return "reading" end
    return "unread"
end

-- A series, as a folder: with its cover it draws in the shelf's folder style,
-- and a tap drills in through the spec's open_folder. Its badge follows the
-- reader's folder badge settings and reads like a local folder's: with the
-- "finished of total" format, books read / books in the series.
local function seriesItem(dto)
    local title = dto.title or "?"
    local status = seriesStatus(dto)
    local total = dto.booksCount
    local has_total = type(total) == "number" and total > 0
    local finished = dto.booksReadCount
    if type(finished) ~= "number" and has_total and type(dto.booksUnreadCount) == "number" then
        finished = total - dto.booksUnreadCount
    end
    return {
        is_folder = true,
        filepath = PATH_PREFIX .. "series/" .. dto.id,
        title = title,
        label = title,
        cover_image_path = existingCover("series", dto.id),
        book_count = has_total and total or nil,
        finished_count = has_total and finished or nil,
        finished_total = has_total and total or nil,
        status = status,
        read_status = status,
        komga_series_id = dto.id,
        komga_series_title = title,
        komga_series_summary = dto.summary,
    }
end

-- A collection, as a folder; opening it lists its series as series folders.
local function collectionItem(dto)
    local title = dto.title or "?"
    return {
        is_folder = true,
        filepath = PATH_PREFIX .. "collection/" .. dto.id,
        title = title,
        label = title,
        cover_image_path = existingCover("collection", dto.id),
        komga_collection_id = dto.id,
        komga_collection_title = title,
    }
end

-- Whether an item passes a read-status filter. A series is judged by Komga's
-- tallies; one cached before those were kept has none, and is shown rather
-- than wrongly hidden. Collections are never filtered.
local FILTER_STATUS = { UNREAD = "unread", IN_PROGRESS = "reading", READ = "finished" }

local function passesReadFilter(item_type, dto, filter)
    if not filter then return true end
    local status
    if item_type == "book" then
        status = (bookStatus(dto))
    elseif item_type == "series" then
        if dto.booksCount == nil then return true end
        status = seriesStatus(dto)
    else
        return true
    end
    for _i, state in ipairs(filter) do
        if FILTER_STATUS[state] == status then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Shelf contents
-- ---------------------------------------------------------------------------

local function listSpec(mode, filter)
    return {
        section = "lists", key = mode, item_type = listItemType(mode), filter = filter,
        fetch = function(plugin) return fetchList(plugin, mode) end,
    }
end

local function seriesSpec(series_id, filter, series_summary)
    return {
        section = "series", key = series_id, item_type = "book", filter = filter,
        series_summary = series_summary,
        fetch = function(plugin) return fetchSeriesBooks(plugin, series_id) end,
    }
end

local function collectionSpec(collection_id, filter)
    return {
        section = "collections", key = collection_id, item_type = "series", filter = filter,
        fetch = function(plugin) return fetchCollectionSeries(plugin, collection_id) end,
    }
end

-- All Series is too big to fetch whole: it is paged from Komga as it is
-- browsed, and Komga applies the sort and filters. Pages are cached under the
-- query, so each combination of settings pages independently.
local function allSeriesSpec(source)
    local query = {
        sort = seriesSort(source),
        read_status = readFilter(source),
        library_id = libraryFilter(source),
        status = publicationFilter(source),
    }
    return {
        paged = true, section = "pages", item_type = "series",
        key = table.concat({
            query.sort,
            query.read_status and table.concat(query.read_status, ",") or "",
            query.library_id and table.concat(query.library_id, ",") or "",
            query.status and table.concat(query.status, ",") or "",
        }, "|"),
        fetch_page = function(plugin, page)
            local response = plugin.api:query_series{
                sort = query.sort, read_status = query.read_status,
                library_id = query.library_id, status = query.status,
                page = page, size = PAGE_SIZE,
            }
            local content = contentOf(response)
            if not content then return nil end
            local items = {}
            for _i, series in ipairs(content) do
                local item = asTable(series) and trimSeries(series)
                if item and item.id then items[#items + 1] = item end
            end
            return { items = items, total = asNumber(response.totalElements) or #items }
        end,
    }
end

-- What a Komga shelf shows at its top level.
local function rootSpec(source)
    local mode = listMode(source)
    if mode == "all_series" then return allSeriesSpec(source) end
    return listSpec(mode, readFilter(source))
end

local function pageKey(spec, page)
    return spec.key .. "|" .. page
end

-- Komga's total for a paged query, from whichever of its pages was fetched
-- last. Knowing it before every page is cached lets Bookshelf's pager show the
-- real length, and keeps paging forward from resetting to page 1.
local function queryTotal(spec)
    local prefix = spec.key .. "|"
    local best
    for k, entry in pairs(store():readSetting("pages") or {}) do
        if type(k) == "string" and k:sub(1, #prefix) == prefix and type(entry) == "table"
                and type(entry.total) == "number"
                and (not best or (entry.fetched_at or 0) > (best.fetched_at or 0)) then
            best = entry
        end
    end
    return best and best.total
end

-- Forgets every cached page of a query.
local function dropPages(spec)
    local s = store()
    local entries = s:readSetting("pages") or {}
    local prefix = spec.key .. "|"
    for k in pairs(entries) do
        if type(k) == "string" and k:sub(1, #prefix) == prefix then entries[k] = nil end
    end
    s:saveSetting("pages", entries)
    s:flush()
end

-- One page of a paged query, fetching from Komga only the pages it spans.
local function buildPagedView(plugin, spec, offset, limit, allow_network, want_all)
    local total = queryTotal(spec)
    local stop = offset + limit
    if total then stop = math.min(stop, total) end
    local first_page = math.floor(offset / PAGE_SIZE)
    local last_page = math.max(first_page, math.floor((math.max(stop, offset + 1) - 1) / PAGE_SIZE))

    local pages = {}
    for page = first_page, last_page do
        local key = pageKey(spec, page)
        local entry = readEntry("pages", key)
        pages[page] = entry
        -- Select-all asks for everything; serve only what is cached then.
        if allow_network and not want_all and isStale(plugin, entry) then
            scheduleRefresh("pages", key, function(p) return spec.fetch_page(p, page) end)
        end
    end

    local items, missing, shown_series = {}, {}, {}
    for i = offset + 1, stop do
        local entry = pages[math.floor((i - 1) / PAGE_SIZE)]
        local dto = entry and entry.items and entry.items[(i - 1) % PAGE_SIZE + 1]
        if dto then
            local item = seriesItem(dto)
            if not item.cover_image_path then noteMissingCover(missing, "series", dto) end
            shown_series[#shown_series + 1] = dto
            items[#items + 1] = item
        end
    end

    if #shown_series > 0 then rememberSummaries(shown_series) end
    if allow_network and not want_all then scheduleCovers(missing) end
    logger.dbg("KomgaBookshelf: paged view", spec.key, "->", #items, "of", tostring(total),
        "items, offset", offset)
    -- nil when Komga has not said yet: Bookshelf then offers a next page for
    -- as long as pages come back full.
    return items, total
end

-- One page of a shelf, as (items, total) -- what the spec's fetch returns.
-- Answers from the cache; with allow_network, whatever is stale or missing is
-- fetched in the background. SOURCE_API 1 does not say whether a fetch is for
-- the shelf on screen or Bookshelf preloading its shelves, so a select-all is
-- the only fetch kept cache-only.
local function buildView(plugin, spec, offset, limit, allow_network, want_all)
    if spec.paged then
        return buildPagedView(plugin, spec, offset, limit, allow_network, want_all)
    end
    local entry = readEntry(spec.section, spec.key)
    if allow_network and isStale(plugin, entry) then
        scheduleRefresh(spec.section, spec.key, spec.fetch)
    end

    local all = entry and entry.items or {}
    -- Filter the whole list before paging, so pages and the total agree.
    if spec.filter then
        local kept = {}
        for _, dto in ipairs(all) do
            if passesReadFilter(spec.item_type, dto, spec.filter) then kept[#kept + 1] = dto end
        end
        all = kept
    end
    local page, missing = {}, {}
    local shown_series, unknown_series, asked = {}, {}, {}
    for i = offset + 1, math.min(offset + limit, #all) do
        local dto = all[i]
        if spec.item_type == "series" then
            local item = seriesItem(dto)
            if not item.cover_image_path then noteMissingCover(missing, "series", dto) end
            shown_series[#shown_series + 1] = dto
            page[#page + 1] = item
        elseif spec.item_type == "collection" then
            local item = collectionItem(dto)
            if not item.cover_image_path then noteMissingCover(missing, "collection", dto) end
            page[#page + 1] = item
        else
            local record = bookRecord(plugin, dto, spec.series_summary)
            if not record.cover_image_path then noteMissingCover(missing, "book", dto) end
            -- A book without a summary of its own whose series has not been
            -- seen: look the series up, once per series.
            local series_id = dto.seriesId
            if not nonEmpty(dto.metadata and dto.metadata.summary) and series_id
                    and not asked[series_id] and not summary_attempted[series_id]
                    and not select(2, seriesSummary(series_id)) then
                asked[series_id] = true
                unknown_series[#unknown_series + 1] = series_id
            end
            page[#page + 1] = record
        end
    end

    if #shown_series > 0 then rememberSummaries(shown_series) end
    if allow_network and not want_all then
        scheduleCovers(missing)
        scheduleSummaries(unknown_series)
    end
    logger.dbg("KomgaBookshelf: view", spec.section, tostring(spec.key), "->", #page,
        "of", #all, "items, offset", offset, entry and "" or "(not fetched yet)")
    return page, #all
end

-- What a Komga shelf shows at a level: its list at the top (drill nil), or a
-- series or collection drilled into from it (the entry open_folder returned).
-- A drill-down inherits its shelf's filter, as Bookshelf's folders do.
local function specFor(source, drill)
    local filter = readFilter(source)
    if type(drill) == "table" then
        if drill.kind == SERIES_DRILL and drill.series_id then
            return seriesSpec(drill.series_id, filter, drill.series_summary)
        end
        if drill.kind == COLLECTION_DRILL and drill.collection_id then
            return collectionSpec(drill.collection_id, filter)
        end
        return nil
    end
    return rootSpec(source)
end

-- Pull-down on a Komga shelf fetches what is on screen from Komga straight
-- away, whatever the cache's age, and keeps the notice up until it is done --
-- the same gesture refreshes an OPDS catalogue. done() redraws the shelf.
local function refreshNow(spec, done)
    local plugin = livePlugin()
    if not plugin then return end
    local _ = plugin.i18n._

    -- A paged query refreshes the page last shown; its other pages are dropped
    -- once that succeeds, and refetched as they are shown.
    local section, key, fetch = spec.section, spec.key, spec.fetch
    if spec.paged then
        local page = math.floor((last_offset[spec.key] or 0) / PAGE_SIZE)
        section, key = "pages", pageKey(spec, page)
        fetch = function(p) return spec.fetch_page(p, page) end
    end

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local InfoMessage = require("ui/widget/infomessage")
        local notice = InfoMessage:new{ text = _("Refreshing Komga…") }
        UIManager:show(notice)
        UIManager:forceRePaint()
        UIManager:nextTick(function()
            local live = livePlugin() or plugin
            local id = section .. "|" .. tostring(key)
            local ok, result = pcall(fetch, live)
            local entry = ok and entryFromResult(result)
            UIManager:close(notice)
            if entry then
                last_failure[id] = nil
                logger.info("KomgaBookshelf: refreshed", #entry.items, "items for", id)
                if spec.paged then dropPages(spec) end
                writeEntry(section, key, entry)
                -- An explicit refresh is the moment to retry covers the server
                -- could not supply earlier in the session.
                cover_attempted = {}
            else
                last_failure[id] = os.time()
                logger.warn("KomgaBookshelf: refresh failed for", id, ok and "" or tostring(result))
                live:notify(_("Couldn't refresh from Komga."), "error")
            end
            if type(done) == "function" then done() else notifyChanged() end
        end)
    end)
end

-- ---------------------------------------------------------------------------
-- Book info, download and open
-- ---------------------------------------------------------------------------

-- The Komga id of a book record. A record Bookshelf rebuilt from its path keeps
-- only the path, so read the id back from there too.
local function bookIdOf(record)
    if type(record) ~= "table" then return nil end
    if asString(record.komga_book_id) then return record.komga_book_id end
    local fp = asString(record.filepath)
    return fp and fp:match("^" .. PATH_PREFIX .. "book/(.+)$")
end

-- Downloads a book through kokomga, so it is linked to Komga for progress sync
-- and the next-chapter flow, then hands its path to `open` (Bookshelf's
-- ctx.open). Without one -- a Bookshelf from before `info` got ctx.open -- the
-- shelf is redrawn instead, and the book shows as downloaded.
local function downloadAndOpen(plugin, record, open)
    local _ = plugin.i18n._
    local book_id = bookIdOf(record)
    if not book_id then return end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local live = livePlugin() or plugin
        -- The cached record is trimmed; the download and the metadata written
        -- alongside it want the full book.
        local book = live.api:get_book(book_id)
        if type(book) ~= "table" or not asString(book.id) then
            live:notify(_("Couldn't load this book from Komga."), "error")
            return
        end
        local function landed(path)
            notifyChanged()
            if open then open(path) end
        end
        local series_title = asString(book.seriesTitle)
        -- Downloaded since the record was built (from kokomga's browser, say).
        local ok_path, existing = pcall(live.sync.getBookLocalPath, live.sync, book, series_title)
        if ok_path and fileExists(existing) then return landed(existing) end
        live.sync:downloadBook(book, series_title, landed)
    end)
end

-- The book dialog's header: title, author and summary, the summary capped so
-- the buttons stay on screen.
local function infoHeader(record, width)
    local Font = require("ui/font")
    local Screen = require("device").screen
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = TextBoxWidget:new{
        text = record.display_title or record.title or "",
        face = Font:getFace("cfont", 20),
        bold = true,
        width = width,
    }
    if asString(record.author) then
        group[#group + 1] = TextBoxWidget:new{
            text = record.author,
            face = Font:getFace("cfont", 16),
            width = width,
        }
    end
    local summary = nonEmpty(record.description)
    if summary then
        group[#group + 1] = VerticalSpan:new{ width = Screen:scaleBySize(10) }
        group[#group + 1] = TextBoxWidget:new{
            text = summary,
            face = Font:getFace("cfont", 16),
            width = width,
            height = Screen:scaleBySize(22) * 8,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
        }
    end
    -- Nothing here is interactive: keep it out of the dialog's focus layout.
    group.not_focusable = true
    return group
end

-- A Komga book's details, with Open for a downloaded book or the download for
-- one that is not. `open` opens a file through Bookshelf, or is nil.
local function showBookInfo(plugin, record, open)
    local _ = plugin.i18n._
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}

    local local_path = localPathIfDownloaded(plugin, record.komga_dto or {})
    if local_path then
        if open then
            buttons[#buttons + 1] = { {
                text = _("Open"),
                callback = function()
                    UIManager:close(dialog)
                    open(local_path)
                end,
            } }
        end
    elseif bookIdOf(record) then
        buttons[#buttons + 1] = { {
            text = open and _("Download & Open") or _("Download"),
            callback = function()
                UIManager:close(dialog)
                downloadAndOpen(plugin, record, open)
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    } }

    dialog = ButtonDialog:new{ buttons = buttons }
    local ok, header = pcall(infoHeader, record, dialog:getAddedWidgetAvailableWidth())
    if ok and header then dialog:addWidget(header) end
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Shelf options
-- ---------------------------------------------------------------------------

-- A single-choice picker. options are { value = …, label = … }; the current
-- value is ticked.
local function pickOption(plugin, title, options, current, on_pick, on_cancel)
    local _ = gettext(plugin)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local rows = {}
    for _i, option in ipairs(options) do
        local prefix = (option.value == current) and "\xE2\x9C\x93 " or "  "
        rows[#rows + 1] = { {
            text = prefix .. option.label,
            callback = function()
                UIManager:close(dialog)
                on_pick(option.value)
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
    dialog = ButtonDialog:new{ title = title, buttons = rows }
    UIManager:show(dialog)
end

local function pickList(plugin, current, on_pick, on_cancel)
    local options = {}
    for _i, mode in ipairs(KomgaBookshelf.LIST_MODES) do
        options[#options + 1] = { value = mode, label = KomgaBookshelf.listLabel(plugin, mode) }
    end
    pickOption(plugin, "Komga", options, current, on_pick, on_cancel)
end

-- Several choices at once: tap to tick or untick, then Apply. The dialog is
-- shown afresh after each tap so its ticks are current. on_apply receives the
-- ticked values in the options' order; what none or all of them mean is the
-- caller's to decide.
local function pickMany(plugin, options, current, on_apply, on_cancel)
    local _ = gettext(plugin)
    local ButtonDialog = require("ui/widget/buttondialog")
    local chosen = {}
    for _i, value in ipairs(current or {}) do chosen[value] = true end

    local dialog
    local function show()
        local rows = {}
        for _i, option in ipairs(options) do
            rows[#rows + 1] = { {
                text = (chosen[option.value] and "\xE2\x9C\x93 " or "  ") .. option.label,
                callback = function()
                    chosen[option.value] = not chosen[option.value] or nil
                    UIManager:close(dialog)
                    show()
                end,
            } }
        end
        rows[#rows + 1] = {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                    if on_cancel then on_cancel() end
                end,
            },
            {
                text = _("Apply"),
                is_enter_default = true,
                callback = function()
                    UIManager:close(dialog)
                    local list = {}
                    for _i, option in ipairs(options) do
                        if chosen[option.value] then list[#list + 1] = option.value end
                    end
                    on_apply(list)
                end,
            },
        }
        dialog = ButtonDialog:new{ buttons = rows }
        UIManager:show(dialog)
    end
    show()
end

local function pickReadFilter(plugin, current, on_pick, on_cancel)
    local options = {}
    for _i, state in ipairs(READ_FILTERS) do
        options[#options + 1] = { value = state, label = readStateLabel(plugin, state) }
    end
    pickMany(plugin, options, current, function(list)
        on_pick(chosenValues(list, READ_FILTERS))
    end, on_cancel)
end

local function translated(plugin, options)
    local _ = gettext(plugin)
    local out = {}
    for _i, option in ipairs(options) do
        out[#out + 1] = { value = option.value, label = _(option.label) }
    end
    return out
end

local function pickSort(plugin, current, on_pick, on_cancel)
    pickOption(plugin, nil, translated(plugin, SERIES_SORTS), current, on_pick, on_cancel)
end

local function pickPublication(plugin, current, on_pick, on_cancel)
    pickMany(plugin, translated(plugin, PUBLICATION_STATUSES), current, function(list)
        on_pick(chosenValues(list, PUBLICATION_VALUES))
    end, on_cancel)
end

-- Komga's libraries, fetched when online and remembered for offline use.
local function loadLibraries(plugin)
    if isOnline() and plugin and plugin.api then
        local response = plugin.api:get_libraries()
        if type(response) == "table" then
            local libraries = {}
            for _i, library in ipairs(response) do
                if asTable(library) and asString(library.id) then
                    libraries[#libraries + 1] = { id = library.id, name = asString(library.name) or library.id }
                end
            end
            writeEntry("meta", "libraries", { fetched_at = os.time(), items = libraries })
            return libraries
        end
    end
    local cached = readEntry("meta", "libraries")
    return cached and cached.items
end

-- Library names are stored alongside their ids, so the options can show them
-- without the server. Ticking none, or every library, means no filter.
local function pickLibrary(plugin, source, on_done, on_cancel)
    local _ = gettext(plugin)
    local libraries = loadLibraries(plugin)
    if not libraries then
        if plugin then plugin:notify(_("Couldn't load libraries from Komga."), "error") end
        if on_cancel then on_cancel() end
        return
    end
    local options = {}
    for _i, library in ipairs(libraries) do
        options[#options + 1] = { value = library.id, label = library.name }
    end
    pickMany(plugin, options, libraryFilter(source), function(list)
        source.library_name = nil  -- the single name older shelves kept
        if #list == 0 or #list == #libraries then
            source.library_id, source.library_names = nil, nil
        else
            local names = {}
            for _i, library in ipairs(libraries) do names[library.id] = library.name end
            local chosen_names = {}
            for _i, id in ipairs(list) do chosen_names[id] = names[id] end
            source.library_id, source.library_names = list, chosen_names
        end
        on_done()
    end, on_cancel)
end

local function seriesFilterSummary(plugin, source)
    local _ = gettext(plugin)
    local parts = {}
    local read = readFilter(source)
    if read then parts[#parts + 1] = readFilterLabel(plugin, read) end
    if libraryFilter(source) then parts[#parts + 1] = libraryLabel(plugin, source) end
    local status = publicationFilter(source)
    if status then parts[#parts + 1] = publicationLabel(plugin, status) end
    return #parts > 0 and table.concat(parts, " · ") or _("None")
end

-- All Series' filters: read status, library and publication status, all
-- applied by Komga. Each change is reported to on_change at once -- so the
-- shelf editor counts it even if this dialog is dismissed rather than closed --
-- and comes back here.
local function openSeriesFilters(plugin, source, on_change)
    local _ = gettext(plugin)
    local T = template(plugin)
    local function reopen() openSeriesFilters(plugin, source, on_change) end
    local function changed()
        on_change()
        reopen()
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function row(text, open)
        return { {
            text = text,
            callback = function()
                UIManager:close(dialog)
                open()
            end,
        } }
    end
    dialog = ButtonDialog:new{
        buttons = {
            row(T(_("Read status: %1"), readFilterLabel(plugin, readFilter(source))), function()
                pickReadFilter(plugin, readFilter(source), function(value)
                    source.read_status = value
                    changed()
                end, reopen)
            end),
            row(T(_("Library: %1"), libraryLabel(plugin, source)), function()
                pickLibrary(plugin, source, changed, reopen)
            end),
            row(T(_("Publication: %1"), publicationLabel(plugin, publicationFilter(source))), function()
                pickPublication(plugin, publicationFilter(source), function(value)
                    source.status = value
                    changed()
                end, reopen)
            end),
            row(_("Close"), function() end),
        },
    }
    UIManager:show(dialog)
end

-- A Komga shelf's own rows in Bookshelf's shelf editor, where "Server order"
-- would be: which list it shows, then Komga's sort and filters for All Series,
-- or the read-status filter for any other list. A button edits draft.source
-- and calls done(); Bookshelf saves it with the shelf, and asks for these rows
-- again on every redraw, so a changed list brings up its own options.
local function editorRows(draft)
    local plugin = livePlugin()
    local _ = gettext(plugin)
    local T = template(plugin)
    local rows = { { {
        text = function(d)
            return "Komga: " .. KomgaBookshelf.listLabel(plugin, listMode(d.source))
        end,
        callback = function(d, done)
            pickList(plugin, listMode(d.source), function(mode)
                d.source.list = mode
                done()
            end)
        end,
    } } }
    if listMode(draft.source) == "all_series" then
        rows[2] = {
            {
                text = function(d)
                    return T(_("Sort: %1"), optionLabel(plugin, SERIES_SORTS, seriesSort(d.source), "Title"))
                end,
                callback = function(d, done)
                    pickSort(plugin, seriesSort(d.source), function(sort)
                        d.source.sort = sort
                        done()
                    end)
                end,
            },
            {
                text = function(d)
                    return T(_("Filter: %1"), seriesFilterSummary(plugin, d.source))
                end,
                callback = function(d, done)
                    openSeriesFilters(plugin, d.source, done)
                end,
            },
        }
    else
        rows[2] = { {
            text = function(d)
                return T(_("Show: %1"), readFilterLabel(plugin, readFilter(d.source)))
            end,
            callback = function(d, done)
                pickReadFilter(plugin, readFilter(d.source), function(value)
                    d.source.read_status = value
                    done()
                end)
            end,
        } }
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- The source
-- ---------------------------------------------------------------------------

-- Every hook is called by Bookshelf, which pcalls it: a failure costs the Komga
-- shelf, never the home screen.
local SPEC = {
    api = 1,
    label = function() return "Komga" end,
    -- Only while kokomga can talk to a Komga server.
    available = function() return livePlugin() ~= nil end,
    remote_prefix = PATH_PREFIX,

    -- Picking Komga as a shelf's source asks which list it shows; its sort and
    -- filters are then in the shelf editor (editor_rows).
    pick = function(draft, done)
        local plugin = livePlugin()
        if not plugin then return done(false) end
        pickList(plugin, nil, function(mode)
            draft.source.list = mode
            done()
        end, function() done(false) end)
    end,

    editor_rows = editorRows,

    -- Answers from the cache; anything stale or missing is fetched in the
    -- background, and notifyChanged has Bookshelf ask again once it lands.
    fetch = function(source, drill, offset, limit)
        local plugin = livePlugin()
        local spec = plugin and specFor(source, drill)
        if not spec then return {}, 0 end
        offset = offset or 0
        -- Select-all asks for everything: serve what is cached, fetch nothing.
        local want_all = not limit or limit >= WANT_ALL_FROM
        if not want_all then last_offset[spec.key] = offset end
        return buildView(plugin, spec, offset, limit or WANT_ALL_LIMIT, not want_all, want_all)
    end,

    open_folder = function(folder)
        if folder.komga_series_id then
            return {
                kind = SERIES_DRILL,
                label = folder.komga_series_title or folder.title,
                series_id = folder.komga_series_id,
                series_summary = folder.komga_series_summary,
            }
        end
        if folder.komga_collection_id then
            return {
                kind = COLLECTION_DRILL,
                label = folder.komga_collection_title or folder.title,
                collection_id = folder.komga_collection_id,
            }
        end
    end,

    -- A book on the device opens straight away; one that is not offers its
    -- download. Rechecked on every tap: the file may have been downloaded or
    -- deleted since the record was built.
    open = function(book, ctx)
        local plugin = livePlugin()
        if not (plugin and bookIdOf(book)) then return false end
        local local_path = localPathIfDownloaded(plugin, book.komga_dto or {})
        if local_path then return local_path end
        showBookInfo(plugin, book, ctx and ctx.open)
        return true
    end,

    info = function(book, ctx)
        local plugin = livePlugin()
        if plugin then showBookInfo(plugin, book, ctx and ctx.open) end
    end,

    refresh = function(source, drill, done)
        local spec = specFor(source, drill)
        if spec then refreshNow(spec, done) end
    end,

    -- A record Bookshelf rebuilt from its path has lost its source stamp.
    owns = function(book)
        return type(book) == "table" and isKomgaPath(book.filepath)
    end,
}

-- Registers Komga with Bookshelf, when Bookshelf has the shelf source API. Safe
-- to call from every kokomga init: registering again replaces the spec. Returns
-- whether Bookshelf took it.
function KomgaBookshelf.register(ui)
    local bookshelf = ui and ui.bookshelf
    if not (bookshelf and type(bookshelf.registerSource) == "function"
            and (tonumber(bookshelf.SOURCE_API) or 0) >= 1) then
        return false
    end
    local ok, accepted, why = pcall(bookshelf.registerSource, bookshelf, SOURCE_KIND, SPEC)
    if not (ok and accepted) then
        logger.warn("KomgaBookshelf: Bookshelf refused the Komga source:", tostring(ok and why or accepted))
        return false
    end
    if not registered then logger.info("KomgaBookshelf: Komga registered as a Bookshelf shelf source") end
    registered = true
    return true
end

function KomgaBookshelf.isAvailable()
    return registered
end

return KomgaBookshelf
