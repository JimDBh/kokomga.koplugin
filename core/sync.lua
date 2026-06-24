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

function KomgaSync:autoMatchBook(filepath, silent)
    if not self.plugin.api or not filepath then return nil end
    local filename = filepath:match("([^/\\]+)$") or filepath
    local parent_dir = filepath:match("([^/\\]+)[/\\][^/\\]+$") or ""
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    
    if not silent then self.plugin:notify(T(_("Searching Komga for: %1"), filename), "info") end
    local matched, err = self.plugin.api:match_book(filename, parent_dir)
    
    if matched then
        self.plugin.settings.matched_books_cache[filepath] = matched.id
        self.plugin:saveSettings()
        
        pcall(function()
            local DocSettings = require("docsettings")
            local custom_doc_settings = DocSettings.openSettingsFile and DocSettings.openSettingsFile(filepath)
            
            if custom_doc_settings then
                custom_doc_settings:saveSetting("komga_book_id", matched.id)
                local custom_props = custom_doc_settings:readSetting("custom_props") or {}
                local doc_props = custom_doc_settings:readSetting("doc_props") or {}
                
                if type(matched.metadata) == "table" then
                    if type(matched.metadata.title) == "string" and matched.metadata.title ~= "" then
                        custom_props.title = matched.metadata.title
                        doc_props.title = matched.metadata.title
                    end
                    if type(matched.metadata.summary) == "string" and matched.metadata.summary ~= "" then
                        custom_props.description = matched.metadata.summary
                        doc_props.description = matched.metadata.summary
                    end
                    if matched.metadata.number ~= nil then
                        custom_props.series_index = tostring(matched.metadata.number)
                        doc_props.series_index = tostring(matched.metadata.number)
                    elseif matched.metadata.numberSort ~= nil then
                        custom_props.series_index = tostring(matched.metadata.numberSort)
                        doc_props.series_index = tostring(matched.metadata.numberSort)
                    end
                    if type(matched.metadata.authors) == "table" and #matched.metadata.authors > 0 then
                        local author_names = {}
                        for _, a in ipairs(matched.metadata.authors) do
                            table.insert(author_names, a.name)
                        end
                        custom_props.authors = table.concat(author_names, ", ")
                        doc_props.authors = table.concat(author_names, ", ")
                    end
                end
                
                if matched.seriesTitle and matched.seriesTitle ~= "" then
                    custom_props.series = matched.seriesTitle
                    doc_props.series = matched.seriesTitle
                end
                
                if custom_doc_settings.flushCustomMetadata then
                    -- doc_props in custom settings uses internal schema maybe? but others plugins use doc_props. Let's merge directly.
                    -- KORComic uses doc_props
                    custom_doc_settings:saveSetting("custom_props", custom_props)
                    custom_doc_settings:saveSetting("doc_props", doc_props)
                    custom_doc_settings:flushCustomMetadata(filepath)
                else
                    custom_doc_settings:saveSetting("custom_props", custom_props)
                    custom_doc_settings:saveSetting("doc_props", doc_props)
                    if custom_doc_settings.flush then custom_doc_settings:flush() end
                end
            end
        end)
        
        if not silent then self.plugin:notify(T(_("Matched with: %1"), matched.name), "info") end
        return matched.id
    else
        if not silent then self.plugin:notify(T(_("Failed to match: %1"), tostring(err)), "error") end
    end
    return nil
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
    local custom_doc_settings = DocSettings.openSettingsFile and pcall(DocSettings.openSettingsFile, DocSettings, filepath) and DocSettings.openSettingsFile(filepath) or nil
    if custom_doc_settings then
        local meta_id = custom_doc_settings:readSetting("komga_book_id") 
            or custom_doc_settings:readSetting("komga_id")
        if meta_id and meta_id ~= "" then
            self.plugin.settings.matched_books_cache[filepath] = meta_id
            self.plugin:saveSettings()
            return meta_id
        end
    end

    -- Skip sidecar creation if it doesn't already exist
    local has_sidecar = DocSettings.hasSidecarFile and DocSettings:hasSidecarFile(filepath)
    local doc_settings = nil
    if has_sidecar or not DocSettings.hasSidecarFile then
        doc_settings = pcall(DocSettings.open, DocSettings, filepath) and DocSettings:open(filepath) or nil
    end
    if doc_settings then
        local meta_id = doc_settings:readSetting("komga_book_id") 
            or doc_settings:readSetting("komga_id") 
        if meta_id and meta_id ~= "" then
            self.plugin.settings.matched_books_cache[filepath] = meta_id
            self.plugin:saveSettings()
            return meta_id
        end
    end
    
    return nil, "Not linked"
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
    self.plugin:notify(T(_("Searching Komga for: %1"), filename), "info")

    -- Clean the name
    local clean_name = filename:match("([^/\\]+)$") or filename
    clean_name = clean_name:gsub("%.epub$", ""):gsub("%.pdf$", ""):gsub("%.cbz$", ""):gsub("%.cbr$", ""):gsub("%.fb2$", "")

    local results, err = self.plugin.api:search_books(clean_name)
    if not results or not results.content or #results.content == 0 then
        local fallback_name = clean_name:gsub("[%-_]", " ")
        results, err = self.plugin.api:search_books(fallback_name)
    end

    if not results or not results.content or #results.content == 0 then
        self.plugin:notify(_("No matching book found on Komga server"), "error")
        return
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")

    local buttons = {}
    local dialog
    -- Take up to 10 matching books
    local limit = math.min(#results.content, 10)
    for i = 1, limit do
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
                    
                    pcall(function()
                        local DocSettings = require("docsettings")
                        local custom_doc_settings = DocSettings.openSettingsFile and DocSettings.openSettingsFile(filepath)
                        
                        if custom_doc_settings then
                            custom_doc_settings:saveSetting("komga_book_id", book.id)
                            local custom_props = custom_doc_settings:readSetting("custom_props") or {}
                            local doc_props = custom_doc_settings:readSetting("doc_props") or {}
                            
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
                            
                            if book.seriesTitle and book.seriesTitle ~= "" then
                                custom_props.series = book.seriesTitle
                                doc_props.series = book.seriesTitle
                            end
                            
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
                    end)
                    
                    self.plugin:notify(T(_("Matched with: %1"), label), "info")
                end
            }
        })
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

    dialog = ButtonDialog:new{
        title = _("Select Matching Komga Book"),
        buttons = buttons
    }
    UIManager:show(dialog)
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
        local custom_doc_settings = DocSettings.openSettingsFile and DocSettings.openSettingsFile(filepath)
        if custom_doc_settings then
            custom_doc_settings:saveSetting("komga_book_id", nil)
            if custom_doc_settings.flush then custom_doc_settings:flush() end
        end
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
            
            pcall(function()
                local DocSettings = require("docsettings")
                local custom_doc_settings = DocSettings.openSettingsFile and DocSettings.openSettingsFile(local_path)
                
                if custom_doc_settings then
                    custom_doc_settings:saveSetting("komga_book_id", book.id)
                    local custom_props = custom_doc_settings:readSetting("custom_props") or {}
                    local doc_props = custom_doc_settings:readSetting("doc_props") or {}
 
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
                    
                    if series_title and series_title ~= "" then
                        custom_props.series = series_title
                        doc_props.series = series_title
                    end
                    
                    if custom_doc_settings.flushCustomMetadata then
                        custom_doc_settings:saveSetting("custom_props", custom_props)
                        custom_doc_settings:saveSetting("doc_props", doc_props)
                        custom_doc_settings:flushCustomMetadata(local_path)
                    else
                        custom_doc_settings:saveSetting("custom_props", custom_props)
                        custom_doc_settings:saveSetting("doc_props", doc_props)
                        if custom_doc_settings.flush then custom_doc_settings:flush() end
                    end
                end
                
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
