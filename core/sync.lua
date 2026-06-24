--[[
    Komga Sync & Matching Engine
    Coordinates progress updates and book file acquisition.
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")

local KomgaSync = {}

function KomgaSync:new(plugin)
    local o = { plugin = plugin }
    return setmetatable(o, { __index = self })
end

-- Helper to get custom_metadata.lua file paths
local function get_custom_metadata_paths(filepath)
    -- Try replacing extension (e.g. .cbz -> .sdr)
    local sdr_dir1 = filepath:gsub("%.%w+$", "") .. ".sdr"
    local path1 = sdr_dir1 .. "/custom_metadata.lua"
    
    -- Try appending .sdr (e.g. .cbz -> .cbz.sdr)
    local sdr_dir2 = filepath .. ".sdr"
    local path2 = sdr_dir2 .. "/custom_metadata.lua"
    
    return path1, path2
end

-- Helper to recursively serialize Lua values to a string
local function serialize_value(v, indent_level)
    indent_level = indent_level or 1
    local indent = string.rep("    ", indent_level)
    if type(v) == "string" then
        return string.format("%q", v)
    elseif type(v) == "number" or type(v) == "boolean" then
        return tostring(v)
    elseif type(v) == "table" then
        local parts = {}
        table.insert(parts, "{\n")
        for k2, v2 in pairs(v) do
            local key_str
            if type(k2) == "string" then
                key_str = string.format("[%q]", k2)
            else
                key_str = string.format("[%s]", tostring(k2))
            end
            local val_str = serialize_value(v2, indent_level + 1)
            if val_str then
                table.insert(parts, string.format("%s    %s = %s,\n", indent, key_str, val_str))
            end
        end
        table.insert(parts, indent .. "}")
        return table.concat(parts)
    else
        return nil
    end
end

-- Helper to load custom_metadata.lua table directly using standard Lua
local function load_custom_metadata(filepath)
    local path1, path2 = get_custom_metadata_paths(filepath)
    for _, path in ipairs({path1, path2}) do
        local f = io.open(path, "r")
        if f then
            f:close()
            logger.info("[Komga Sync] Found custom_metadata.lua file at:", path)
            local func, err = loadfile(path)
            if func then
                local ok, data = pcall(func)
                if ok and type(data) == "table" then
                    logger.info("[Komga Sync] Successfully loaded custom metadata table from:", path)
                    for k, v in pairs(data) do
                        logger.info("[Komga Sync] custom_metadata key:", tostring(k), "value_type:", type(v), "value:", tostring(v))
                    end
                    return data, path
                else
                    logger.warn("[Komga Sync] Failed to run custom metadata file:", tostring(err or data))
                end
            else
                logger.warn("[Komga Sync] Failed to load custom metadata file:", tostring(err))
            end
        end
    end
    return nil
end

-- Helper to save a key-value pair to custom_metadata.lua
local function save_custom_metadata(filepath, key_or_table, value)
    local path1, _ = get_custom_metadata_paths(filepath)
    local data = {}
    local loaded_data, found_path = load_custom_metadata(filepath)
    if loaded_data then
        data = loaded_data
        path1 = found_path or path1
    end
    
    if type(key_or_table) == "table" then
        for k, v in pairs(key_or_table) do
            data[k] = v
        end
    else
        data[key_or_table] = value
    end
    
    local util = pcall(require, "util") and require("util")
    if util and util.makePath then
        local dir = path1:match("(.*)/[^/]+")
        if dir then pcall(util.makePath, dir .. "/") end
    end
    
    local f_write, err = io.open(path1, "w")
    if f_write then
        f_write:write("return {\n")
        for k, v in pairs(data) do
            local val_str = serialize_value(v, 1)
            if val_str then
                f_write:write(string.format("    [%q] = %s,\n", k, val_str))
            end
        end
        f_write:write("}\n")
        f_write:close()
        logger.info("[Komga Sync] Successfully wrote custom_metadata to:", path1)
        return true
    else
        logger.warn("[Komga Sync] Failed to open custom_metadata.lua for writing:", tostring(err))
        return false
    end
end

-- Helper to save book metadata both to KOReader's docsettings and to custom_metadata.lua
local function save_book_metadata(filepath, book, series_title)
    if not filepath or not book then return end
    
    local DocSettings = require("docsettings")
    local custom_doc_settings = DocSettings.openSettingsFile and DocSettings:openSettingsFile(filepath)
    
    local custom_props = {}
    local doc_props = {}
    if custom_doc_settings then
        custom_props = custom_doc_settings:readSetting("custom_props") or {}
        doc_props = custom_doc_settings:readSetting("doc_props") or {}
    end
    
    if type(book.metadata) == "table" then
        if type(book.metadata.title) == "string" and book.metadata.title ~= "" then
            custom_props.title = book.metadata.title
            doc_props.title = book.metadata.title
        end
        if type(book.metadata.summary) == "string" and book.metadata.summary ~= "" then
            custom_props.description = book.metadata.summary
            doc_props.description = book.metadata.summary
        end
        if book.metadata.number ~= nil then
            custom_props.series_index = tostring(book.metadata.number)
            doc_props.series_index = tostring(book.metadata.number)
        elseif book.metadata.numberSort ~= nil then
            custom_props.series_index = tostring(book.metadata.numberSort)
            doc_props.series_index = tostring(book.metadata.numberSort)
        end
        if type(book.metadata.authors) == "table" and #book.metadata.authors > 0 then
            local author_names = {}
            for _, a in ipairs(book.metadata.authors) do
                table.insert(author_names, a.name)
            end
            custom_props.authors = table.concat(author_names, ", ")
            doc_props.authors = table.concat(author_names, ", ")
        end
    end
    
    local s_title = series_title or book.seriesTitle
    if s_title and s_title ~= "" then
        custom_props.series = s_title
        doc_props.series = s_title
    end
    
    if custom_doc_settings then
        custom_doc_settings:saveSetting("komga_book_id", book.id)
        if custom_doc_settings.flushCustomMetadata then
            custom_doc_settings:saveSetting("custom_props", custom_props)
            custom_doc_settings:saveSetting("doc_props", doc_props)
            custom_doc_settings:flushCustomMetadata(filepath)
        else
            custom_doc_settings:saveSetting("custom_props", custom_props)
            custom_doc_settings:saveSetting("doc_props", doc_props)
            if custom_doc_settings.flush then custom_doc_settings:flush() end
        end
    end
    
    -- Save directly to custom_metadata.lua for maximum reliability and direct fallback loading
    save_custom_metadata(filepath, {
        komga_book_id = book.id,
        custom_props = custom_props,
        doc_props = doc_props
    })
end

-- Helper to find or cache book matching
function KomgaSync:getOrMatchBook(filepath)
    if not self.plugin.api or not filepath then
        return nil, "Plugin not configured."
    end
    
    local cached_id = self.plugin.settings.matched_books_cache[filepath]
    if cached_id then
        return cached_id
    end

    -- Try reading from KOReader's document metadata (.sdr)
    local DocSettings = require("docsettings")
    logger.info("[Komga Sync] getOrMatchBook for filepath:", filepath)
    logger.info("[Komga Sync] DocSettings module loaded. Type:", type(DocSettings))
    logger.info("[Komga Sync] DocSettings.openSettingsFile exists:", type(DocSettings.openSettingsFile) == "function")

    local custom_doc_settings = nil
    if DocSettings.openSettingsFile then
        local ok, res = pcall(DocSettings.openSettingsFile, DocSettings, filepath)
        logger.info("[Komga Sync] pcall openSettingsFile ok:", ok, "result:", tostring(res))
        if ok and res then
            custom_doc_settings = res
        end
    end
    if custom_doc_settings then
        local meta_id = custom_doc_settings:readSetting("komga_book_id") 
            or custom_doc_settings:readSetting("komga_id")
        logger.info("[Komga Sync] custom_doc_settings komga_book_id / komga_id:", tostring(meta_id))
        if meta_id and meta_id ~= "" then
            logger.info("[Komga Sync] Matched via custom_doc_settings:", meta_id)
            self.plugin.settings.matched_books_cache[filepath] = meta_id
            self.plugin:saveSettings()
            return meta_id
        end
    else
        logger.info("[Komga Sync] No custom_doc_settings loaded.")
    end

    -- Fallback: Directly read custom_metadata.lua using standard Lua
    local custom_metadata = load_custom_metadata(filepath)
    if custom_metadata then
        local meta_id = custom_metadata.komga_book_id or custom_metadata.komga_id
        if meta_id and meta_id ~= "" then
            logger.info("[Komga Sync] Matched via custom_metadata.lua table fallback:", meta_id)
            self.plugin.settings.matched_books_cache[filepath] = meta_id
            self.plugin:saveSettings()
            return meta_id
        end
    end

    -- Skip sidecar creation if it doesn't already exist
    local has_sidecar = false
    if DocSettings.hasSidecarFile then
        local ok, res = pcall(DocSettings.hasSidecarFile, DocSettings, filepath)
        logger.info("[Komga Sync] hasSidecarFile ok:", ok, "result:", tostring(res))
        if ok then
            has_sidecar = res
        end
    else
        logger.info("[Komga Sync] DocSettings.hasSidecarFile does not exist.")
    end
    
    local doc_settings = nil
    if has_sidecar or not DocSettings.hasSidecarFile then
        local ok, res = pcall(DocSettings.open, DocSettings, filepath)
        logger.info("[Komga Sync] pcall open ok:", ok, "result:", tostring(res))
        if ok and res then
            doc_settings = res
        end
    end
    if doc_settings then
        local meta_id = doc_settings:readSetting("komga_book_id") 
            or doc_settings:readSetting("komga_id") 
        logger.info("[Komga Sync] doc_settings komga_book_id / komga_id:", tostring(meta_id))
        if meta_id and meta_id ~= "" then
            logger.info("[Komga Sync] Matched via doc_settings:", meta_id)
            self.plugin.settings.matched_books_cache[filepath] = meta_id
            self.plugin:saveSettings()
            return meta_id
        end
    else
        logger.info("[Komga Sync] No doc_settings loaded.")
    end
    
    logger.info("[Komga Sync] getOrMatchBook returning nil (Not linked)")
    return nil, "Not linked"
end

local function get_series_from_metadata(filepath, doc)
    local DocSettings = require("docsettings")
    logger.info("[Komga Sync] get_series_from_metadata for filepath:", filepath)
    logger.info("[Komga Sync] DocSettings.openSettingsFile exists:", type(DocSettings.openSettingsFile) == "function")

    local custom_doc_settings = nil
    if DocSettings.openSettingsFile then
        local ok, res = pcall(DocSettings.openSettingsFile, DocSettings, filepath)
        logger.info("[Komga Sync] get_series_from_metadata pcall openSettingsFile ok:", ok, "result:", tostring(res))
        if ok and res then
            custom_doc_settings = res
        end
    end
    if custom_doc_settings then
        local doc_props = custom_doc_settings:readSetting("doc_props") or {}
        logger.info("[Komga Sync] doc_props series:", tostring(doc_props.series))
        if doc_props.series and doc_props.series ~= "" then
            return doc_props.series
        end
        local custom_props = custom_doc_settings:readSetting("custom_props") or {}
        logger.info("[Komga Sync] custom_props series:", tostring(custom_props.series))
        if custom_props.series and custom_props.series ~= "" then
            return custom_props.series
        end
    else
        logger.info("[Komga Sync] No custom_doc_settings loaded for series retrieval.")
    end

    -- Direct load custom_metadata.lua fallback for series metadata
    local custom_metadata = load_custom_metadata(filepath)
    if custom_metadata then
        if custom_metadata.series and custom_metadata.series ~= "" then
            logger.info("[Komga Sync] Found series in custom_metadata table:", tostring(custom_metadata.series))
            return custom_metadata.series
        end
        local doc_props = custom_metadata.doc_props or {}
        if doc_props.series and doc_props.series ~= "" then
            logger.info("[Komga Sync] Found series in custom_metadata.doc_props table:", tostring(doc_props.series))
            return doc_props.series
        end
        local custom_props = custom_metadata.custom_props or {}
        if custom_props.series and custom_props.series ~= "" then
            logger.info("[Komga Sync] Found series in custom_metadata.custom_props table:", tostring(custom_props.series))
            return custom_props.series
        end
    end

    if doc and doc.getProps then
        local success, props = pcall(doc.getProps, doc)
        logger.info("[Komga Sync] getProps ok:", success)
        if success and props then
            logger.info("[Komga Sync] props.series:", tostring(props.series))
            if props.series and props.series ~= "" then
                return props.series
            end
        end
    end
    logger.info("[Komga Sync] get_series_from_metadata returning nil")
    return nil
end

-- Matches the current open book manual
function KomgaSync:matchCurrentBook()
    local doc = self.plugin.ui and self.plugin.ui.document
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    if not doc or not doc.file then
        self.plugin:notify(_("No active book open to match."), "error")
        return
    end

    local filepath = doc.file
    local filename = filepath:match("([^/\\]+)$") or filepath
    local parent_dir = filepath:match("([^/\\]+)[/\\][^/\\]+$") or ""

    local InfoMessage = require("ui/widget/infomessage")
    local search_msg = InfoMessage:new{ text = "[Komga] " .. T(_("Searching Komga for: %1"), filename) }
    UIManager:show(search_msg)

    local results, err
    local matched_series_id = nil

    -- a. First search the parent folder as the series
    if parent_dir ~= "" then
        local s_results, s_err = self.plugin.api:search_series(parent_dir)
        if s_results and s_results.content and #s_results.content > 0 then
            local p_lower = parent_dir:lower()
            for _, s in ipairs(s_results.content) do
                local s_name = s.name or ""
                local s_title = (s.metadata and s.metadata.title) or ""
                if s_name:lower() == p_lower or s_title:lower() == p_lower then
                    matched_series_id = s.id
                    break
                end
            end
            if not matched_series_id then
                matched_series_id = s_results.content[1].id
            end
        end
    end

    -- If not look at book metadata for series and search for series
    if not matched_series_id then
        local meta_series = get_series_from_metadata(filepath, doc)
        if meta_series and meta_series ~= "" then
            local s_results, s_err = self.plugin.api:search_series(meta_series)
            if s_results and s_results.content and #s_results.content > 0 then
                local ms_lower = meta_series:lower()
                for _, s in ipairs(s_results.content) do
                    local s_name = s.name or ""
                    local s_title = (s.metadata and s.metadata.title) or ""
                    if s_name:lower() == ms_lower or s_title:lower() == ms_lower then
                        matched_series_id = s.id
                        break
                    end
                end
                if not matched_series_id then
                    matched_series_id = s_results.content[1].id
                end
            end
        end
    end

    -- b. If there is a matched series, search filename in that series using the search API.
    if matched_series_id then
        local s_books, s_err = self.plugin.api:search_books(filename, matched_series_id)
        if s_books and s_books.content and #s_books.content > 0 then
            results = s_books
        end
    end

    -- c. If a / b failed, then we search the filename itself.
    if not results or not results.content or #results.content == 0 then
        results, err = self.plugin.api:search_books(filename)
    end

    if search_msg then
        UIManager:close(search_msg)
    end

    if not results or not results.content or #results.content == 0 then
        self.plugin:notify(_("No matching book found on Komga server"), "error")
        return
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")

    local total_books = #results.content
    local page_size = 10
    local total_pages = math.ceil(total_books / page_size)

    local dialog
    local function showPage(page_num)
        local start_idx = (page_num - 1) * page_size + 1
        local end_idx = math.min(start_idx + page_size - 1, total_books)

        local buttons = {}
        for i = start_idx, end_idx do
            local book = results.content[i]
            local series = book.seriesTitle or book.seriesName or ""
            local title = (book.metadata and book.metadata.title) or book.name or "Untitled"
            local label = ""
            if series ~= "" then
                label = "[" .. series .. "] " .. title
            else
                label = title
            end

            table.insert(buttons, {
                {
                    text = label,
                    callback = function()
                        UIManager:close(dialog)
                        self.plugin.settings.matched_books_cache[filepath] = book.id
                        self.plugin:saveSettings()
                        
                        pcall(save_book_metadata, filepath, book)
                        
                        self.plugin:notify(T(_("Matched with: %1"), label), "info")
                    end
                }
            })
        end

        -- Add navigation row if we have multiple pages
        local nav_buttons = {}
        if page_num > 1 then
            table.insert(nav_buttons, {
                text = "<< " .. _("Prev"),
                callback = function()
                    UIManager:close(dialog)
                    showPage(page_num - 1)
                end
            })
        end
        if page_num < total_pages then
            table.insert(nav_buttons, {
                text = _("Next") .. " >>",
                callback = function()
                    UIManager:close(dialog)
                    showPage(page_num + 1)
                end
            })
        end

        if #nav_buttons > 0 then
            table.insert(buttons, nav_buttons)
        end

        -- Add a Cancel button
        table.insert(buttons, {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end
            }
        })

        local title_text = _("Select Matching Komga Book")
        if total_pages > 1 then
            title_text = title_text .. " (" .. page_num .. "/" .. total_pages .. ")"
        end

        dialog = ButtonDialog:new{
            title = title_text,
            buttons = buttons
        }
        UIManager:show(dialog)
    end

    showPage(1)
end

-- Unlinks the current open book from Komga
function KomgaSync:unlinkCurrentBook()
    local doc = self.plugin.ui and self.plugin.ui.document
    local _ = self.plugin.i18n._
    if not doc or not doc.file then
        self.plugin:notify(_("No active book open to unlink."), "error")
        return
    end

    local filepath = doc.file
    self.plugin.settings.matched_books_cache[filepath] = nil
    self.plugin:saveSettings()

    pcall(function()
        local DocSettings = require("docsettings")
        local custom_doc_settings = DocSettings.openSettingsFile and DocSettings:openSettingsFile(filepath)
        if custom_doc_settings then
            custom_doc_settings:saveSetting("komga_book_id", nil)
            if custom_doc_settings.flush then custom_doc_settings:flush() end
        end
        save_custom_metadata(filepath, "komga_book_id", nil)
    end)

    self.plugin:notify(_("Unlinked from Komga successfully."), "info")
end

-- Sync progress from Komga
function KomgaSync:pullProgress(ui, is_manual, ensure_networking)
    if not self.plugin.settings.use_komga_sync then return false end
    if not self.plugin.api or not ui or not ui.document then return false end
    
    local filepath = ui.document.file
    if not filepath then return false end
    
    local book_id, err = self:getOrMatchBook(filepath)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    
    if not book_id then
        if is_manual then self.plugin:notify(_("Click 'Match' first."), "error") end
        return false
    end
    
    local function do_pull()
        if is_manual then self.plugin:notify(_("Checking server progress..."), "info") end
        
        logger.info("KomgaSync: Executing pullProgress for book", book_id)
        
        local progress, p_err = self.plugin.api:get_read_progress(book_id)
        if p_err then 
            logger.err("KomgaSync: Failed to pull progress -", tostring(p_err))
            if is_manual then
                self.plugin:notify(T(_("Failed to pull progress - %1"), tostring(p_err)), "error")
            end
            return false -- FAILED to get komga progress
        end
        if type(progress) ~= "table" then
            logger.info("KomgaSync: Book found but no progress recorded on server (progress type is", type(progress), ")")
            return true
        end
        
        logger.info("KomgaSync: Pulled progress from server:", progress.page or "None")
        
        if not progress.page then 
            logger.info("KomgaSync: Book found but progress.page is missing")
            return true -- Server responded successfully but 0% progress
        end
        
        local remote_page = progress.page
        local current_page = ui.view and ui.view.state and ui.view.state.page or 1
        
        if remote_page == current_page then
            if is_manual then self.plugin:notify(_("Already at server progress"), "info") end
            return true
        end
        
        local PluginLoader = require("pluginloader")
        local kosync = PluginLoader:getPluginInstance("kosync")
        
        local strategy
        local text
        if remote_page > current_page then
            strategy = (kosync and kosync.settings.sync_forward) or 1
            text = T(_("Server is ahead (Page %1). Jump?"), remote_page)
        else
            strategy = (kosync and kosync.settings.sync_backward) or 1
            text = T(_("Server is behind (Page %1). Jump?"), remote_page)
        end
        
        if strategy == 1 then -- Prompt
            local ConfirmBox = require("ui/widget/confirmbox")
            local UIManager = require("ui/uimanager")
            local Event = require("ui/event")
            UIManager:show(ConfirmBox:new{
                text = text,
                ok_callback = function()
                    UIManager:broadcastEvent(Event:new("GotoPage", remote_page))
                end,
            })
        elseif strategy == 2 then -- Silently update
            local UIManager = require("ui/uimanager")
            local Event = require("ui/event")
            UIManager:broadcastEvent(Event:new("GotoPage", remote_page))
            if is_manual then self.plugin:notify(T(_("Jumped to Page %1"), remote_page), "info") end
        end
        
        return true
    end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        if is_manual then
            if NetworkMgr:willRerunWhenOnline(do_pull) then
                logger.info("KomgaSync: Network offline, manual pullProgress queued for when online.")
                return false
            end
        else
            logger.info("KomgaSync: Network offline, silently skipping background pullProgress.")
            return false
        end
    end

    return do_pull()
end

-- Push progress to Komga
function KomgaSync:pushProgress(book_id, current_page, total_pages, is_quiet)
    if not self.plugin.api then return end
    local completed = current_page >= total_pages
    local success, err = self.plugin.api:patch_read_progress(book_id, current_page, completed)
    if success then
        logger.info("[Komga Sync] Saved page " .. current_page)
    else
        logger.err("[Komga Sync] Save failed: " .. tostring(err))
    end
end

function KomgaSync:pushProgressForDocument(ui, is_quiet, ensure_networking)
    if not self.plugin.api or not ui or not ui.document then return end
    local filepath = ui.document.file
    if not filepath then return end
    
    local book_id = self:getOrMatchBook(filepath)
    if not book_id then return end
    
    local current_page = ui.view and ui.view.state and ui.view.state.page or 1
    local total_pages = ui.view and ui.view.state and ui.view.state.page_count or (ui.document and ui.document.getPageCount and ui.document:getPageCount()) or current_page
    
    local function do_push()
        logger.info("KomgaSync: Executing pushProgress for book", book_id, "page", current_page)
        self:pushProgress(book_id, current_page, total_pages, is_quiet)
    end
    
    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isOnline() then
        logger.info("KomgaSync: Network offline, silently skipping pushProgressForDocument.")
        return
    end
    
    do_push()
end

-- Get expected local path for a book
function KomgaSync:getBookLocalPath(book, series_title)
    local filename = book.name or book.id
    local ext = ""
    if book.media and book.media.mediaType then
        local mt = book.media.mediaType
        if mt == "application/zip" or mt == "application/x-zip-compressed" then ext = ".cbz"
        elseif mt == "application/pdf" then ext = ".pdf"
        elseif mt == "application/epub+zip" then ext = ".epub"
        elseif mt == "application/x-rar-compressed" or mt == "application/x-rar" then ext = ".cbr"
        end
    end
    if ext ~= "" and not filename:match("%.[a-zA-Z0-9]+$") then
        filename = filename .. ext
    end
    if not filename:match("%.[a-zA-Z0-9]+$") then
        filename = filename .. ".cbz"
    end
    filename = filename:gsub('[/%\\%:%*%?%"%<%>%|]', '_')
    local download_dir = self.plugin:getDownloadDir()
    if not download_dir then return nil, nil end
    if self.plugin.settings.download_to_subfolder and series_title then
        local clean_series = series_title:gsub('[/%\\%:%*%?%"%<%>%|]', '_')
        download_dir = download_dir .. "/" .. clean_series
    end
    return download_dir .. "/" .. filename, filename
end

function KomgaSync:isBookDownloaded(book)
    local local_path = self:getBookLocalPath(book, book.seriesTitle)
    if not local_path then return false end
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(local_path, "mode") == "file"
end

-- Download book
function KomgaSync:downloadBook(book, series_title, on_success_callback, on_failure_callback)
    if not self.plugin.api then return end
    
    local local_path, filename = self:getBookLocalPath(book, series_title)
    if not local_path then
        logger.err("KomgaSync: No download directory available, bailing out of downloadBook")
        if on_failure_callback then
            on_failure_callback("No download directory")
        end
        return
    end
    
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    
    local util = require("util")
    local final_dir = local_path:match("(.*)/[^/]+")
    util.makePath(final_dir .. "/")
    
    self.plugin:notify(T(_("Downloading %1..."), filename), "info")
    logger.info("KomgaSync: Starting download of book", book.id, "to", local_path)
    
    local tmp_path = local_path .. ".part"
    
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        local success, err = self.plugin.api:download_book(book.id, tmp_path)
        if success then
            logger.info("KomgaSync: Download successful for", local_path)
            self.plugin:notify(T(_("Saved: %1"), filename), "info")
            self.plugin.settings.matched_books_cache[local_path] = book.id
            self.plugin:saveSettings()
            
            pcall(save_book_metadata, local_path, book, series_title)
            
            -- Move file into place after sidecar metadata is fully written
            local os = require("os")
            os.rename(tmp_path, local_path)
            
            -- Download series cover if missing and downloading to a subdir
            self:downloadSeriesCoverIfMissing(book, final_dir, series_title)
            
            if on_success_callback then
                UIManager:nextTick(function()
                    on_success_callback(local_path)
                end)
            end
            
            -- Tell FileBrowser to refresh directory and reload file items
            UIManager:nextTick(function()
                pcall(function()
                    local BookInfoManager = require("plugins/coverbrowser.koplugin/bookinfomanager")
                    if BookInfoManager and BookInfoManager.deleteBookInfo then
                        BookInfoManager:deleteBookInfo(local_path)
                    end
                end)
                local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
                if ok and FileManager.instance then
                    if FileManager.instance.file_chooser and FileManager.instance.file_chooser.resetBookInfoCache then
                        pcall(function() FileManager.instance.file_chooser.resetBookInfoCache(local_path) end)
                    end
                    FileManager.instance:onRefresh()
                end
            end)
        else
            logger.err("KomgaSync: Download failed", tostring(err))
            self.plugin:notify(T(_("Failed: %1"), tostring(err)), "error")
            if on_failure_callback then
                UIManager:nextTick(function()
                    on_failure_callback(tostring(err))
                end)
            end
        end
    end)
end

function KomgaSync:downloadBooksSeq(books, index, on_done_callback)
    index = index or 1
    if index > #books then
        if on_done_callback then
            on_done_callback()
        end
        return
    end
    
    local book = books[index]
    local next_step = function()
        self:downloadBooksSeq(books, index + 1, on_done_callback)
    end
    
    self:downloadBook(book, book.seriesTitle, next_step, next_step)
end

function KomgaSync:promptNextChapter(ui, show_native_func)
    if not self.plugin.api or not ui or not ui.document then return end
    local filepath = ui.document.file
    if not filepath then return end

    local book_id = self.plugin.settings.matched_books_cache[filepath]
    if not book_id then return end

    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T

    -- Respect KOReader's "Always mark as finished" setting
    logger.info("KomgaSync: Checking auto mark. G_reader_settings exists:", G_reader_settings ~= nil)
    if G_reader_settings then
        local is_auto = G_reader_settings:isTrue("end_document_auto_mark")
        logger.info("KomgaSync: end_document_auto_mark value:", is_auto)
        if is_auto then
            if ui.doc_settings then
                local summary = ui.doc_settings:readSetting("summary")
                if type(summary) == "table" then
                    summary.status = "complete"
                    summary.modified = os.date("%Y-%m-%d", os.time())
                    ui.doc_settings:saveSetting("summary", summary)
                    logger.info("KomgaSync: Marked summary.status as complete.")
                end
            end
            pcall(function()
                local BookList = require("ui/widget/booklist")
                BookList.setBookInfoCacheProperty(filepath, "status", "complete")
                logger.info("KomgaSync: Updated BookList cache.")
            end)
            -- Also push the 100% progress up to the Komga server
            self:pushProgressForDocument(ui, true)
        end
    end

    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")

    if not NetworkMgr:isOnline() then
        local dialog
        dialog = ButtonDialog:new{
            title = _("No Wi-Fi connection. Cannot check for the next chapter."),
            buttons = {
                {
                    {
                        text = _("Open Next Chapter"),
                        enabled = false,
                        callback = function() end
                    }
                },
                {
                    {
                        text = _("Default Action"),
                        callback = function()
                            UIManager:close(dialog)
                            if show_native_func then
                                show_native_func()
                            end
                        end
                    },
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(dialog)
                        end
                    }
                }
            }
        }
        UIManager:show(dialog)
        return true
    end

    -- Get the next book directly using Komga's native endpoint (404 → nil = no next book)
    local next_book = self.plugin.api:get_next_book(book_id)

    if not next_book then
        logger.info("KomgaSync: No next chapter found.")
        self.plugin:notify(_("No next chapter found."), "info")
        return false
    end

    local series_title = next_book.seriesTitle
    local local_path, filename = self:getBookLocalPath(next_book, series_title)
    if not local_path then return false end

    local lfs = require("libs/libkoreader-lfs")
    local is_downloaded = (lfs.attributes(local_path, "mode") == "file")

    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    
    local title = next_book.metadata and next_book.metadata.title or next_book.name or "Untitled"
    local prompt_msg = is_downloaded and 
        T(_("Next chapter is ready: %1"), title) or 
        T(_("Next chapter is not downloaded: %1"), title)

    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = prompt_msg,
        buttons = {
            {
                {
                    text = is_downloaded and _("Open Next Chapter") or _("Download & Open"),
                    is_enter_default = true,
                    callback = function()
                        UIManager:close(dialog)
                        local function open_doc(path)
                            logger.info("KomgaSync: Opening next chapter:", path)
                            UIManager:nextTick(function()
                                local filemanagerutil = require("apps/filemanager/filemanagerutil")
                                filemanagerutil.openFile(ui, path)
                            end)
                        end

                        if is_downloaded then
                            open_doc(local_path)
                        else
                            self:downloadBook(next_book, series_title, open_doc)
                        end
                    end
                }
            },
            {
                {
                    text = _("Default Action"),
                    callback = function()
                        UIManager:close(dialog)
                        if show_native_func then
                            show_native_func()
                        end
                    end
                },
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end
                }
            }
        }
    }
    UIManager:show(dialog)
    
    return true
end

function KomgaSync:downloadSeriesCoverIfMissing(book, final_dir, series_title)
    if not self.plugin.api then return end
    
    -- Check if we are downloading to a subdir of the series
    local is_subdir = self.plugin.settings.download_to_subfolder and series_title and series_title ~= ""
    if not is_subdir then
        return
    end

    local lfs = require("libs/libkoreader-lfs")
    
    -- Check if final_dir is a valid directory
    local mode = lfs.attributes(final_dir, "mode")
    if mode ~= "directory" then
        return
    end

    -- Check if .cover* already exists in final_dir
    local has_cover = false
    for file in lfs.dir(final_dir) do
        if file:match("^%.cover%.") or file:match("^%.cover$") then
            has_cover = true
            break
        end
    end

    if has_cover then
        logger.info("KomgaSync: Series cover already exists in directory", final_dir)
        return
    end

    -- Download the series cover if seriesId is available
    local series_id = book.seriesId
    if not series_id then
        logger.warn("KomgaSync: Cannot download series cover, book.seriesId is missing")
        return
    end

    logger.info("KomgaSync: Downloading series cover for series", series_id, "to", final_dir)
    local img_data, err = self.plugin.api:download_series_thumbnail(series_id)
    if not img_data or type(img_data) ~= "string" or #img_data == 0 then
        logger.err("KomgaSync: Failed to download series cover:", tostring(err))
        return
    end

    -- Detect image format
    local ext = "jpg"
    if img_data:sub(1, 4) == "\137PNG" or img_data:sub(1, 4) == "\137\080\078\071" then
        ext = "png"
    elseif img_data:sub(1, 3) == "\255\216\255" or img_data:sub(1, 2) == "\255\216" then
        ext = "jpg"
    elseif img_data:sub(1, 4) == "RIFF" and img_data:sub(9, 12) == "WEBP" then
        ext = "webp"
    elseif img_data:sub(1, 3) == "GIF" then
        ext = "gif"
    end

    local cover_filename = ".cover." .. ext
    local cover_filepath = final_dir .. "/" .. cover_filename

    -- Write the cover image file
    local f, f_err = io.open(cover_filepath, "wb")
    if f then
        f:write(img_data)
        f:close()
        logger.info("KomgaSync: Successfully saved series cover to", cover_filepath)
    else
        logger.err("KomgaSync: Failed to write series cover file:", tostring(f_err))
    end
end

return KomgaSync
