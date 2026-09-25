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
local KomgaBookshelf = require(plugin_dir .. "core/bookshelf")
local KomgaBookIndex = require(plugin_dir .. "core/book_index")
local i18n = require(plugin_dir .. "core/i18n")

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
    auto_rtl_direction = false,
    auto_download_next = 0,
    skip_end_of_book_prompt = false,
    disable_readest_sync_for_komga = false,
    keep_recent_chapters = 0
}

-- Readest's per-book sync entry points. Everything here acts on the currently
-- open document, so it is in scope for "Disable Readest sync for Komga books".
-- syncBooksLibrary is deliberately absent: it is a library-wide push/pull the
-- user invokes explicitly, not background per-book sync.
local READEST_PER_BOOK_METHODS = {
    "pushBookConfig", "pullBookConfig",
    "pushBookStats",  "pullBookStats",
    "pushBookNotes",  "pullBookNotes",
    "touchOpenBook",  "pushOpenBook",
}

-- The Komga book KOSync is syncing right now, as { ui, interactive }: set only
-- while our KOSync:updateProgress / getProgress wrappers run, since KOSync makes
-- its server call within them.
local komga_sync_active = nil

-- The page on screen, as pushProgressForDocument sends it to Komga.
local function currentPage(ui)
    return ui and ui.view and ui.view.state and ui.view.state.page
end

-- Stands in for a KOSync account while KOSync syncs a Komga book. It never
-- reaches a KOSync server: that sync goes to Komga.
local KOMGA_KOSYNC_ACCOUNT = "kokomga"

-- Runs a native KOSync sync method for a Komga book, as if logged in to KOSync:
-- a Komga book needs no KOSync account. The stand-in lasts for this call only.
-- KOSync writes nothing to its settings while syncing, and they are restored
-- before anything can save them.
local function runForKomgaBook(ui, native, kosync_instance, interactive, ...)
    local settings = kosync_instance.settings
    local saved_username, saved_userkey = settings.username, settings.userkey
    if not (saved_username and saved_userkey) then
        settings.username, settings.userkey = KOMGA_KOSYNC_ACCOUNT, KOMGA_KOSYNC_ACCOUNT
    end
    local previous = komga_sync_active
    komga_sync_active = { ui = ui, interactive = interactive }

    local ok, result = pcall(native, kosync_instance, ...)

    komga_sync_active = previous
    settings.username, settings.userkey = saved_username, saved_userkey
    if not ok then error(result, 0) end
    return result
end

-- Readest stores progress as the string "[current,total]".
local function readestProgressTotal(progress)
    if type(progress) ~= "string" then return nil end
    local _current, total = progress:match("^%[(%d+),(%d+)%]$")
    return tonumber(total)
end

function KomgaPlugin:init()
    logger.info("KomgaPlugin: Initializing...")
    self.plugin_dir = plugin_dir
    self.i18n = i18n
    self:loadSettings()
    self:initAPI()
    
    -- Initialize sub-modules
    self.cache = KomgaCache:new(self)
    self.sync = KomgaSync:new(self)
    self.menu = KomgaMenu:new(self)
    self.bookshelf = KomgaBookshelf
    self.book_index = KomgaBookIndex

    self.ui.menu:registerToMainMenu(self)
    self:registerEvents()

    -- Wait a tick so the Bookshelf plugin, if installed, has initialised too.
    local ui = self.ui
    UIManager:nextTick(function() KomgaBookshelf.install(ui) end)
    logger.info("KomgaPlugin: Initialized successfully")
end

function KomgaPlugin:loadSettings()
    local settings_path = DataStorage:getSettingsDir() .. "/kokomga.lua"
    logger.dbg("KomgaPlugin: Loading settings from", settings_path)
    
    -- Safety check for LuaSettings
    if not LuaSettings then
        self:notify(self.i18n._("Incompatible system: LuaSettings not found."), "error")
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
        category = "none",
        title = self.i18n._("Manual Komga Sync"),
        event = "KomgaSyncNow",
        general = true,
    })
    Dispatcher:registerAction("komga_browse", {
        category = "none",
        title = self.i18n._("Browse Komga library"),
        event = "KomgaBrowse",
        general = true,
    })
end

function KomgaPlugin:onKomgaSyncNow()
    self.sync:matchCurrentBook()
end

function KomgaPlugin:onKomgaBrowse()
    self.menu:showBrowser()
end


function KomgaPlugin:notify(message, type)
    type = type or "info"
    logger.info("[Komga Plugin] " .. message)
    UIManager:show(InfoMessage:new{ text = "[Komga] " .. message, timeout = 3 })
end

function KomgaPlugin:getDownloadDir()
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
    self:notify(self.i18n._("No directory set for download! Please set a Home Directory or custom path."), "error")
    return nil
end

-- Readest identifies a book by the partial MD5 stored in its sidecar. When we
-- auto-open the next chapter, Readest has been observed issuing a pull under the
-- *previous* chapter's identity and applying the answer to the chapter now on
-- screen, which drags every new chapter to its last page. Validate the config
-- against the open document before Readest gets to act on it.
--
-- Installed once per session: applyBookConfig lives on Readest's shared
-- SyncConfig module, not on a per-document instance. The live plugin is reached
-- through ui.kokomga so the wrapper never holds a stale reference.
function KomgaPlugin:installReadestGuard()
    if KomgaPlugin._readest_guard_installed then return end

    local ok, SyncConfig = pcall(require, "readest_syncconfig")
    if not ok or type(SyncConfig) ~= "table" or type(SyncConfig.applyBookConfig) ~= "function" then
        logger.info("KomgaPlugin: Readest guard not installed (readest_syncconfig unavailable)")
        return
    end
    KomgaPlugin._readest_guard_installed = true

    local orig_applyBookConfig = SyncConfig.applyBookConfig

    SyncConfig.applyBookConfig = function(sync_config, ui, config)
        local blocked = false

        pcall(function()
            if type(config) ~= "table" then return end

            -- Validate against the reader the user is actually looking at, not
            -- against the ui we were handed: the observed failure applies a config
            -- carried by the outgoing chapter's ui while the page jump lands on the
            -- live reader, so trusting ui.document here would check the wrong book.
            local ReaderUI = require("apps/reader/readerui")
            local live = ReaderUI.instance
            if not (live and live.document) then return end

            local plugin = live.kokomga
            if not (plugin and plugin.sync) then return end

            local file = live.document.file
            if not file then return end
            -- Not a Komga book: Readest's business, not ours.
            if not plugin.sync:getOrMatchBook(file) then return end

            -- A config arriving through a ui that is no longer the live reader
            -- belongs to a document that has already been closed. Nothing it says
            -- can be true of the book now on screen.
            if ui ~= live then
                blocked = true
                logger.info("KomgaPlugin: Blocked Readest progress applied through a stale reader (document already switched)")
                return
            end

            -- Signal 1: page count. Readest drops the stored total on the floor,
            -- so a config from a different-length chapter is detectable here.
            local config_pages = readestProgressTotal(config.progress)
            local document_pages = live.document.getPageCount and live.document:getPageCount()
            local pages_differ = config_pages ~= nil and document_pages ~= nil
                and config_pages ~= document_pages

            -- Signal 2: file identity, recomputed from the file itself rather than
            -- read back from doc_settings, which is one of the things that may be
            -- carrying the outgoing chapter's data at this point.
            local util = require("util")
            local config_hash = config.book_hash or config.bookHash
            local document_hash = util.partialMD5(file)
            local hash_differs = config_hash ~= nil and document_hash ~= nil
                and config_hash ~= document_hash

            -- Both signals must agree before we refuse. A differing hash alone is
            -- not proof of a wrong book: Readest uses meta_hash to bridge two
            -- copies of the same book across devices, and a re-encoded file keeps
            -- its page count while changing its hash. That resume must still apply.
            if hash_differs and pages_differ then
                blocked = true
                logger.info(string.format(
                    "KomgaPlugin: Blocked Readest progress from another book -- config %s (%s pages), open document %s (%s pages)",
                    tostring(config_hash), tostring(config_pages),
                    tostring(document_hash), tostring(document_pages)))
            elseif hash_differs or pages_differ then
                logger.info(string.format(
                    "KomgaPlugin: Readest progress only partially matches, applying anyway (hash_differs=%s pages_differ=%s)",
                    tostring(hash_differs), tostring(pages_differ)))
            end
        end)

        if blocked then return end
        return orig_applyBookConfig(sync_config, ui, config)
    end

    logger.info("KomgaPlugin: Readest applyBookConfig guard installed")
end

-- KOSync hands every sync to its server client -- KOSyncClient:update_progress
-- and :get_progress, looked up on the module at call time. Replace those two
-- calls: for a Komga book synced through our wrappers, the sync goes to Komga,
-- and KOSync's server never sees the book. Installed once per session, as the
-- module is shared; both or neither.
function KomgaPlugin:installKOSyncClientHooks()
    if KomgaPlugin._kosync_client_hooked then return true end

    local ok, KOSyncClient = pcall(require, "KOSyncClient")
    if not ok or type(KOSyncClient) ~= "table"
            or type(KOSyncClient.update_progress) ~= "function"
            or type(KOSyncClient.get_progress) ~= "function" then
        logger.warn("KomgaPlugin: KOSyncClient unavailable, Komga books won't sync progress through KOSync")
        return false
    end
    KomgaPlugin._kosync_client_hooked = true

    local function activePlugin()
        local active = komga_sync_active
        local plugin = active and active.ui and active.ui.kokomga
        if plugin and plugin.sync then return plugin, active end
    end

    -- Push: KOSync gets Komga's answer through its own callback, so it reports
    -- it as it would its own.
    local orig_update_progress = KOSyncClient.update_progress
    KOSyncClient.update_progress = function(client, username, userkey, document, metadata,
                                            progress, percentage, device, device_id, callback)
        local plugin, active = activePlugin()
        if not plugin then
            return orig_update_progress(client, username, userkey, document, metadata,
                progress, percentage, device, device_id, callback)
        end
        local pushed = plugin.sync:pushProgressForDocument(active.ui, true, false)
        logger.info("KomgaPlugin: KOSync push sent to Komga instead, accepted=" .. tostring(pushed))
        if pushed then plugin.komga_pushed_page = currentPage(active.ui) end
        if type(callback) == "function" then callback(pushed, nil) end
    end

    -- Pull: Komga's progress is a page, not KOSync's position and percentage, so
    -- kokomga's own pull decides whether to jump and reports it. KOSync's
    -- callback is not called: there is nothing left for KOSync to do.
    local orig_get_progress = KOSyncClient.get_progress
    KOSyncClient.get_progress = function(client, username, userkey, document, callback)
        local plugin, active = activePlugin()
        if not plugin then
            return orig_get_progress(client, username, userkey, document, callback)
        end
        local pulled = plugin.sync:pullProgress(active.ui, active.interactive, false)
        logger.info("KomgaPlugin: KOSync pull taken from Komga instead, succeeded=" .. tostring(pulled))
    end

    logger.info("KomgaPlugin: KOSync client hooks installed")
    return true
end

-- "Disable Readest sync for Komga books": no-op Readest's per-book sync for any
-- document we manage, even when Readest auto-sync is enabled globally. Wrappers
-- go on the per-document instance, so books we do not manage are untouched.
function KomgaPlugin:installReadestSuppression()
    local readest = self.ui and self.ui.readest
    if not readest or rawget(readest, "_kokomga_wrapped") then return end

    local file = self.ui.document and self.ui.document.file
    local book_id = file and self.sync:getOrMatchBook(file)
    if not book_id then return end

    readest._kokomga_wrapped = true
    local plugin = self

    for _, name in ipairs(READEST_PER_BOOK_METHODS) do
        local orig = readest[name]
        if type(orig) == "function" then
            readest[name] = function(...)
                -- Read the setting here, not at wrap time, so toggling it takes
                -- effect without reopening the book.
                if plugin.settings.disable_readest_sync_for_komga then
                    logger.dbg("KomgaPlugin: suppressed Readest " .. name .. " for Komga book")
                    return
                end
                return orig(...)
            end
        end
    end

    logger.info("KomgaPlugin: Readest per-book sync wrappers installed for Komga book " .. tostring(book_id))
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
    
    if self.settings.auto_rtl_direction then
        local book_id = self.sync:getOrMatchBook(filepath)
        if book_id then
            if ui.view and not ui.view.inverse_reading_order then
                ui.view:onToggleReadingOrder(true)
                if ui.doc_settings then
                    ui.doc_settings:saveSetting("inverse_reading_order", true)
                end
                logger.info("KomgaPlugin: Automatically switched reading order to RTL")
            end
        end
    end

    if self.settings.auto_download_next and self.settings.auto_download_next > 0 then
        self.sync:preDownloadNextBook(filepath)
    end

    -- Learn what follows this book while it is read, so the end-of-book flow
    -- can open the next chapter without the server. Deferred past the open.
    UIManager:scheduleIn(2, function()
        if self.ui and self.ui.document and self.ui.document.file == filepath then
            pcall(self.sync.rememberNextBook, self.sync, filepath)
        end
    end)
    
    -- A Komga book goes through native KOSync:getProgress / updateProgress
    -- untouched -- KOSync keeps deciding when to sync, bringing the network up,
    -- reporting the result and turning Wi-Fi back off after a push on suspend --
    -- except that the sync goes to Komga (see installKOSyncClientHooks), and that
    -- it needs no KOSync account.
    if self.ui.kosync and not self.orig_kosync_updateProgress and self:installKOSyncClientHooks() then
        self.orig_kosync_getProgress = self.ui.kosync.getProgress
        self.orig_kosync_updateProgress = self.ui.kosync.updateProgress

        -- The Komga book to sync with Komga, if any. With "Use Komga server progress"
        -- off, there is none: every book syncs through KOSync as usual.
        local function komgaBookId()
            if not self.settings.use_komga_sync then return nil end
            local current_filepath = self.ui.document and self.ui.document.file
            return current_filepath and self.sync:getOrMatchBook(current_filepath)
        end

        self.ui.kosync.getProgress = function(kosync_instance, ensure_networking, interactive)
            local book_id = komgaBookId()
            if not book_id then
                return self.orig_kosync_getProgress(kosync_instance, ensure_networking, interactive)
            end
            logger.info("KomgaPlugin: KOSync:getProgress for Komga book " .. tostring(book_id)
                .. " (ensure_networking=" .. tostring(ensure_networking) .. ")")
            return runForKomgaBook(self.ui, self.orig_kosync_getProgress, kosync_instance, interactive,
                ensure_networking, interactive)
        end

        self.ui.kosync.updateProgress = function(kosync_instance, ensure_networking, interactive, on_suspend)
            local book_id = komgaBookId()
            if not book_id then
                return self.orig_kosync_updateProgress(kosync_instance, ensure_networking, interactive, on_suspend)
            end
            logger.info("KomgaPlugin: KOSync:updateProgress for Komga book " .. tostring(book_id)
                .. " (ensure_networking=" .. tostring(ensure_networking) .. ")")
            -- KOSync skips an automatic push within 25s of the last one, which would
            -- leave Komga pages behind when a book is closed or the device sleeps
            -- right after a periodic push. Let a push through whenever the page has
            -- moved since Komga last accepted one; the same page stays debounced.
            if not interactive and currentPage(self.ui) ~= self.komga_pushed_page then
                kosync_instance.push_timestamp = 0
            end
            return runForKomgaBook(self.ui, self.orig_kosync_updateProgress, kosync_instance, interactive,
                ensure_networking, interactive, on_suspend)
        end
    end

    self:installReadestGuard()
    self:installReadestSuppression()
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
