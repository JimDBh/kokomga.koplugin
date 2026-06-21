--[[
    KOReader Plugin: Komga Sync & Download Bridge
    Modularized Entry Point
--]]

-- Lua 5.3 compatibility fallback for unpack
if not unpack then
    unpack = table.unpack
end

-- Robust requirement of KOReader modules
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")

-- Determine plugin path for relative requires
local plugin_name = (...)
local plugin_dir = ""
if type(plugin_name) == "string" then
    plugin_dir = plugin_name:match("(.-)[^/%.]+$") or ""
end

local KomgaAPI = require(plugin_dir .. "core/api")
local KomgaCache = require(plugin_dir .. "core/cache")
local KomgaSync = require(plugin_dir .. "core/sync")
local KomgaMenu = require(plugin_dir .. "ui/menus/menu")

local KomgaPlugin = WidgetContainer:extend{
    name = "kokomga",
    is_active = false,
    settings = nil,
    api = nil,
    cache = nil,
    sync = nil,
    menu = nil,
    last_synced_page = 0
}

-- Default local settings template
local DEFAULT_SETTINGS = {
    server_url = "http://192.168.1.100:8080",
    api_key = "",
    use_komga_sync = true,
    cache_expiry_policy = "smart", 
    cache_expiry_mins = 60,
    cache_covers = false,
    never_update_covers = false,
    view_mode = "list",
    list_rows = 5,
    grid_columns = 3,
    grid_rows = 3,
    library_metadata_cache = {},
    matched_books_cache = {},
    download_dir = "",
    download_to_subfolder = true,
    sync_interval_pages = 5
}

function KomgaPlugin:init()
    logger.info("KomgaPlugin: Initializing...")
    self:loadSettings()
    self:initAPI()
    
    -- Initialize sub-modules
    self.cache = KomgaCache:new(self)
    self.sync = KomgaSync:new(self)
    self.menu = KomgaMenu:new(self)
    
    self.ui.menu:registerToMainMenu(self)
    self:registerEvents()
    logger.info("KomgaPlugin: Initialized successfully")
end

function KomgaPlugin:loadSettings()
    local settings_path = DataStorage:getSettingsDir() .. "/kokomga.lua"
    logger.dbg("KomgaPlugin: Loading settings from", settings_path)
    
    -- Safety check for LuaSettings
    if not LuaSettings then
        self:notify("Incompatible system: LuaSettings not found.", "error")
        self.settings = DEFAULT_SETTINGS
        return
    end

    self.settings_file = LuaSettings:open(settings_path)
    self.settings = {}
    for k, v in pairs(DEFAULT_SETTINGS) do
        local saved = self.settings_file:readSetting(k)
        if saved ~= nil then
            self.settings[k] = saved
        else
            self.settings[k] = v
        end
    end
    logger.info("KomgaPlugin: Settings loaded")
end

function KomgaPlugin:saveSettings()
    if not self.settings_file then return end
    for k, v in pairs(self.settings) do
        self.settings_file:saveSetting(k, v)
    end
    self.settings_file:flush()
end

function KomgaPlugin:initAPI()
    if self.settings.server_url and self.settings.server_url ~= "" and self.settings.api_key and self.settings.api_key ~= "" then
        logger.info("KomgaPlugin: Initializing API with URL:", self.settings.server_url)
        self.api = KomgaAPI:new(
            self.settings.server_url,
            self.settings.api_key
        )
    else
        logger.warn("KomgaPlugin: API not initialized (missing server URL or API key)")
        self.api = nil
    end
end

function KomgaPlugin:registerEvents()
    Dispatcher:registerAction("komga_sync_now", {
        category = "sync",
        title = "Manual Komga Sync",
        event = "KomgaSyncNow",
        handler = function() self.sync:matchCurrentBook() end
    })
end

function KomgaPlugin:notify(message, type)
    type = type or "info"
    logger.info("[Komga Plugin] " .. message)
    UIManager:show(InfoMessage:new{ text = "[Komga] " .. message, timeout = 3 })
end

function KomgaPlugin:getDownloadDir()
    local logger = require("logger")
    logger.info("KomgaPlugin: getDownloadDir called")
    if self.settings.download_dir and self.settings.download_dir ~= "" then
        logger.info("KomgaPlugin: using custom download_dir:", self.settings.download_dir)
        return self.settings.download_dir
    end
    local path = G_reader_settings and G_reader_settings:readSetting("home_dir")
    
    if path and path ~= "" then
        logger.info("KomgaPlugin: using home_dir as download_dir:", path)
        return path
    end
    
    logger.warn("KomgaPlugin: UI prompt, no directory set for download")
    self:notify("No directory set for download! Please set a Home Directory or custom path.", "error")
    return nil
end

-- Lifecycle hooks
function KomgaPlugin:onReaderReady()
    local ui = self.ui
    
    if self.ui.status and not self.ui.status.orig_onEndOfBook then
        self.ui.status.orig_onEndOfBook = self.ui.status.onEndOfBook
        self.ui.status.onEndOfBook = function(this_module, ...)
            if self.is_active and self.ui then
                local args = {...}
                local show_native = function()
                    if this_module.orig_onEndOfBook then
                        this_module.orig_onEndOfBook(this_module, unpack(args))
                    end
                end
                
                if self.sync:promptNextChapter(self.ui, show_native) then
                    return true
                end
            end
            if this_module.orig_onEndOfBook then
                return this_module.orig_onEndOfBook(this_module, ...)
            end
        end
    end
    local document = ui and ui.document
    local filepath = document and document.file
    logger.info("KomgaPlugin: onReaderReady triggered for", tostring(filepath))
    self.is_active = true
    self.last_synced_page = ui and ui.view and ui.view.state and ui.view.state.page or 1
    
    if self.ui.kosync and not self.orig_kosync_getProgress then
        self.orig_kosync_getProgress = self.ui.kosync.getProgress
        
        self.ui.kosync.getProgress = function(kosync_instance, ensure_networking, interactive)
            logger.info("KomgaPlugin: Intercepted KOSync:getProgress (ensure_networking=" .. tostring(ensure_networking) .. ")")
            local function do_sync()
                logger.info("KomgaPlugin: Executing do_sync inside getProgress interceptor")
                local current_filepath = self.ui.document and self.ui.document.file
                if current_filepath then
                    local book_id = self.sync:getOrMatchBook(current_filepath)
                    if book_id then
                        local success = self.sync:pullProgress(self.ui, interactive, false)
                        if success then
                            logger.info("KomgaPlugin: Intercepted KOSync and used Komga sync")
                            return -- Komga handled it (or found 0 progress), inhibit KOSync
                        end
                    end
                end
                
                -- Fallback to KOSync natively
                logger.info("KomgaPlugin: Falling back to native KOSync")
                return self.orig_kosync_getProgress(kosync_instance, false, interactive)
            end

            if ensure_networking then
                local NetworkMgr = require("ui/network/manager")
                if NetworkMgr:willRerunWhenOnline(do_sync) then
                    logger.info("KomgaPlugin: Network offline, getProgress queued for when online.")
                    return
                end
            end
            
            return do_sync()
        end
    end

    if self.ui.kosync and not self.orig_kosync_updateProgress then
        self.orig_kosync_updateProgress = self.ui.kosync.updateProgress
        
        self.ui.kosync.updateProgress = function(kosync_instance, ensure_networking, interactive, on_suspend)
            logger.info("KomgaPlugin: Intercepted KOSync:updateProgress (ensure_networking=" .. tostring(ensure_networking) .. ")")
            local current_filepath = self.ui.document and self.ui.document.file
            if current_filepath then
                local book_id = self.sync:getOrMatchBook(current_filepath)
                if book_id then
                    -- This is a Komga book, so we push progress to Komga instead of KOReader's sync server
                    self.sync:pushProgressForDocument(self.ui, not interactive, ensure_networking)
                    return
                end
            end
            
            -- Fallback to native KOSync
            logger.info("KomgaPlugin: Falling back to native KOSync:updateProgress")
            return self.orig_kosync_updateProgress(kosync_instance, ensure_networking, interactive, on_suspend)
        end
    end

    
    -- If KOSync is present but its auto_sync is off, it won't schedule an automatic pull.
    -- We force schedule one here so our interceptor catches it and Komga still auto-pulls!
    if self.ui.kosync and not self.ui.kosync.settings.auto_sync then
        UIManager:nextTick(function()
            self.ui.kosync:getProgress(true, false)
        end)
    end
end

function KomgaPlugin:onPageUpdate(page)
    if not self.is_active or not page then return end
    
    local interval = tonumber(self.settings.sync_interval_pages) or 0
    if interval > 0 then
        if not self.last_synced_page then
            self.last_synced_page = page
        elseif math.abs(page - self.last_synced_page) >= interval then
            self.last_synced_page = page
            local ui = self.ui
            if ui then
                local NetworkMgr = require("ui/network/manager")
                if NetworkMgr:isOnline() then
                    self.sync:pushProgressForDocument(ui, true, false)
                    self.is_dirty = false
                else
                    self.is_dirty = true
                    logger.info("KomgaPlugin: Device offline, progress sync marked dirty for later.")
                end
            end
        end
    end
end

function KomgaPlugin:onEndOfBook()
    -- This is now handled by our monkey-patch in onReaderReady, 
    -- so we don't need to do anything here anymore.
end

function KomgaPlugin:onCloseDocument()
    if not self.is_active then return end
    self.is_active = false
    local ui = self.ui
    local filepath = ui and ui.document and ui.document.file
    if filepath then
        local NetworkMgr = require("ui/network/manager")
        NetworkMgr:goOnlineToRun(function()
            self.sync:pushProgressForDocument(ui, true, false)
        end)
    end
end

function KomgaPlugin:onResume()
    if not self.is_active then return end
    if not self.ui.kosync then
        UIManager:scheduleIn(1, function()
            if self.is_active and self.ui then
                self.sync:pullProgress(self.ui, false, true)
            end
        end)
    end
end

function KomgaPlugin:onSuspend()
    if not self.is_active then return end
    if not self.ui.kosync then
        local ui = self.ui
        if ui and ui.document and ui.document.file then
            self.sync:pushProgressForDocument(ui, true, true)
        end
    end
end

function KomgaPlugin:onNetworkConnected()
    if not self.is_active then return end
    if self.is_dirty then
        local ui = self.ui
        if ui and ui.document and ui.document.file then
            self.sync:pushProgressForDocument(ui, true, false)
            self.is_dirty = false
        end
    end
    if not self.ui.kosync then
        UIManager:scheduleIn(0.5, function()
            if self.is_active and self.ui then
                self.sync:pullProgress(self.ui, false, false)
            end
        end)
    end
end

function KomgaPlugin:onNetworkDisconnecting()
    if not self.is_active then return end
    if not self.ui.kosync then
        local ui = self.ui
        if ui and ui.document and ui.document.file then
            self.sync:pushProgressForDocument(ui, true, false)
        end
    end
end

function KomgaPlugin:addToMainMenu(menu_items)
    menu_items.komga_plugin = {
        text = "kokomga",
        sorting_hint = "search",
        search = true,
        keep_menu_open = true,
        sub_item_table_func = function() return self.menu:createSettingsMenu() end
    }
end

return KomgaPlugin
