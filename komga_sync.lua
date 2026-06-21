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
    
    if not silent then self.plugin:notify("Searching Komga for: " .. filename, "info") end
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
        
        if not silent then self.plugin:notify("Matched with: " .. matched.name, "info") end
        return matched.id
    else
        if not silent then self.plugin:notify("Failed to match: " .. tostring(err), "error") end
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
    local doc = require("apps/reader/modules/readermenu").document
    if not doc or not doc.file then
        self.plugin:notify("No active book open to match.", "error")
        return
    end
    self:autoMatchBook(doc.file, false)
end

-- Sync progress from Komga
function KomgaSync:pullProgress(ui, is_manual)
    if not self.plugin.api or not ui or not ui.document then return end
    
    local filepath = ui.document.file
    if not filepath then return end
    
    local book_id, err = self:getOrMatchBook(filepath)
    
    if not book_id then
        if is_manual then self.plugin:notify("Click 'Match' first.", "error") end
        return
    end
    
    if is_manual then self.plugin:notify("Checking server progress...", "info") end
    
    local progress, p_err = self.plugin.api:get_read_progress(book_id)
    if type(progress) ~= "table" or not progress.page then return end
    
    local remote_page = progress.page
    local current_page = ui.view.state.page or 1
    
    if remote_page == current_page then
        if is_manual then self.plugin:notify("Already at server progress", "info") end
        return
    end
    
    local strategy
    local newer_msg
    if remote_page > current_page then
        strategy = self.plugin.settings.sync_forward or 1
        newer_msg = "Server is ahead"
    else
        strategy = self.plugin.settings.sync_backward or 1
        newer_msg = "Server is behind"
    end
    
    if strategy == 1 then -- Prompt
        local ConfirmBox = require("ui/widget/confirmbox")
        local UIManager = require("ui/uimanager")
        local Event = require("ui/event")
        UIManager:show(ConfirmBox:new{
            text = newer_msg .. " (Page " .. remote_page .. "). Jump?",
            ok_callback = function()
                UIManager:broadcastEvent(Event:new("GotoPage", remote_page))
            end,
        })
    elseif strategy == 2 then -- Silently update
        local UIManager = require("ui/uimanager")
        local Event = require("ui/event")
        UIManager:broadcastEvent(Event:new("GotoPage", remote_page))
        if is_manual then self.plugin:notify("Jumped to Page " .. remote_page, "info") end
    end
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

function KomgaSync:pushProgressForDocument(ui, is_quiet)
    if not self.plugin.api or not ui or not ui.document then return end
    local filepath = ui.document.file
    if not filepath then return end
    
    local book_id = self:getOrMatchBook(filepath)
    if not book_id then return end
    
    local current_page = ui.view.state.page or 1
    local total_pages = ui.view.state.page_count or (ui.document.getPageCount and ui.document:getPageCount()) or current_page
    self:pushProgress(book_id, current_page, total_pages, is_quiet)
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

-- Download book
function KomgaSync:downloadBook(book, series_title, on_success_callback)
    if not self.plugin.api then return end
    
    local local_path, filename = self:getBookLocalPath(book, series_title)
    if not local_path then
        logger.err("KomgaSync: No download directory available, bailing out of downloadBook")
        return
    end
    
    local util = require("util")
    local final_dir = local_path:match("(.*)/[^/]+")
    util.makePath(final_dir .. "/")
    
    self.plugin:notify("Downloading " .. filename .. "...", "info")
    logger.info("KomgaSync: Starting download of book", book.id, "to", local_path)
    
    local tmp_path = local_path .. ".part"
    
    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        local success, err = self.plugin.api:download_book(book.id, tmp_path)
        if success then
            logger.info("KomgaSync: Download successful for", local_path)
            self.plugin:notify("Saved: " .. filename, "info")
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
            self.plugin:notify("Failed: " .. tostring(err), "error")
        end
    end)
end

function KomgaSync:promptNextChapter(ui, show_native_func)
    if not self.plugin.api or not ui or not ui.document then return end
    local filepath = ui.document.file
    if not filepath then return end

    local book_id = self.plugin.settings.matched_books_cache[filepath]
    if not book_id then return end

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

    -- Fetch the book to get series_id
    local book_meta, err = self.plugin.api:request("/api/v1/books/" .. book_id)
    if not book_meta or not book_meta.seriesId then return end

    -- Fetch series to get books and series title
    local series_meta = self.plugin.api:request("/api/v1/series/" .. book_meta.seriesId)
    local series_title = series_meta and series_meta.metadata and series_meta.metadata.title or book_meta.seriesTitle
    
    -- Fetch all books in series sorted
    local books_res = self.plugin.api:get_books_for_series(book_meta.seriesId, { sort = "metadata.numberSort,asc", size = 500 })
    if not books_res or not books_res.content then return end

    local next_book = nil
    for i, b in ipairs(books_res.content) do
        if b.id == book_id and i < #books_res.content then
            next_book = books_res.content[i+1]
            break
        end
    end

    if not next_book then
        logger.info("KomgaSync: No next chapter found.")
        self.plugin:notify("No next chapter found.", "info")
        return false
    end

    local local_path, filename = self:getBookLocalPath(next_book, series_title)
    if not local_path then return false end

    local lfs = require("libs/libkoreader-lfs")
    local is_downloaded = (lfs.attributes(local_path, "mode") == "file")

    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    
    local title = next_book.metadata and next_book.metadata.title or next_book.name
    local prompt_msg = is_downloaded and 
        ("Next chapter is ready: " .. title) or 
        ("Next chapter is not downloaded: " .. title)

    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = prompt_msg,
        buttons = {
            {
                {
                    text = is_downloaded and "Open Next Chapter" or "Download & Open",
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
                    text = "Default Action",
                    callback = function()
                        UIManager:close(dialog)
                        if show_native_func then
                            show_native_func()
                        end
                    end
                },
                {
                    text = "Cancel",
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

return KomgaSync
