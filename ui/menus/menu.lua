--[[
    Komga UI Menu Generator
    Builds KOReader standard menu trees for libraries and settings.
--]]

local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local logger = require("logger")

local KomgaMenu = {}

function KomgaMenu:new(plugin)
    local o = { plugin = plugin }
    return setmetatable(o, { __index = self })
end

function KomgaMenu:showBrowser()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        if not self.plugin.settings.server_url or self.plugin.settings.server_url == "" or
           not self.plugin.settings.api_key or self.plugin.settings.api_key == "" then
            self:promptSetup(function()
                local KomgaBrowser = require("ui/browser")
                local browser = KomgaBrowser:new{ plugin = self.plugin }
                UIManager:show(browser)
            end)
        else
            local KomgaBrowser = require("ui/browser")
            local browser = KomgaBrowser:new{ plugin = self.plugin }
            UIManager:show(browser)
        end
    end)
end


-- Plugin settings sub-menu
function KomgaMenu:createSettingsMenu()
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local submenu = {}
    
    table.insert(submenu, {
        text = _("Server Setup"),
        keep_menu_open = true,
        sub_item_table_func = function()
            return {
                {
                    text = _("Server URL"),
                    keep_menu_open = true,
                    callback = function() self:promptInput(_("Server URL"), "server_url") end
                },
                {
                    text = _("API Key"),
                    keep_menu_open = true,
                    callback = function() self:promptInput(_("API Key"), "api_key") end
                },
                {
                    text = _("Auto-Generate API Key"),
                    keep_menu_open = true,
                    callback = function() self:promptAutoGenerate() end
                }
            }
        end
    })

    table.insert(submenu, {
        text = _("Options"),
        keep_menu_open = true,
        sub_item_table_func = function()
            return {
                {
                    text = _("Custom Download Dir"),
                    keep_menu_open = true,
                    callback = function() self:promptInput(_("Custom Download Dir"), "download_dir") end
                },
                {
                    text = _("Use Komga server progress when available"),
                    checked_func = function() return self.plugin.settings.use_komga_sync end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.use_komga_sync = not self.plugin.settings.use_komga_sync
                        self.plugin:saveSettings()
                    end
                },
                {
                    text = _("Auto RTL for Komga books"),
                    checked_func = function() return self.plugin.settings.auto_rtl_direction end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.auto_rtl_direction = not self.plugin.settings.auto_rtl_direction
                        self.plugin:saveSettings()
                    end
                },
                {
                    text = _("Download into Series Subfolders"),
                    checked_func = function() return self.plugin.settings.download_to_subfolder end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.download_to_subfolder = not self.plugin.settings.download_to_subfolder
                        self.plugin:saveSettings()
                    end
                },
                {
                    text = _("Pre-download next chapter"),
                    checked_func = function() return self.plugin.settings.auto_download_next end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.auto_download_next = not self.plugin.settings.auto_download_next
                        self.plugin:saveSettings()
                    end
                },
                {
                    text = _("Layout Options"),
                    keep_menu_open = true,
                    sub_item_table_func = function()
                        return {
                            {
                                text_func = function()
                                    return self.plugin.settings.view_mode == "grid" and _("Default View Mode: Grid") or _("Default View Mode: List")
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    self.plugin.settings.view_mode = self.plugin.settings.view_mode == "grid" and "list" or "grid"
                                    self.plugin:saveSettings()
                                    if touchmenu_instance and touchmenu_instance.updateItems then
                                        touchmenu_instance:updateItems()
                                    end
                                end
                            },
                            {
                                text_func = function() return T(_("List Mode Rows (%1)"), self.plugin.settings.list_rows or 5) end,
                                keep_menu_open = true,
                                callback = function() self:promptInput(_("List Rows"), "list_rows", true) end
                            },
                            {
                                text_func = function() return T(_("Grid Mode Columns (%1)"), self.plugin.settings.grid_columns or 3) end,
                                keep_menu_open = true,
                                callback = function() self:promptInput(_("Grid Columns"), "grid_columns", true) end
                            },
                            {
                                text_func = function() return T(_("Grid Mode Rows (%1)"), self.plugin.settings.grid_rows or 3) end,
                                keep_menu_open = true,
                                callback = function() self:promptInput(_("Grid Rows"), "grid_rows", true) end
                            }
                        }
                    end
                },
                {
                    text = _("Never update cached covers"),
                    checked_func = function() return self.plugin.settings.never_update_covers end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.never_update_covers = not self.plugin.settings.never_update_covers
                        self.plugin:saveSettings()
                    end
                },
                {
                    text = _("Clean Cache"),
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.cache:clear()
                        self.plugin:notify(_("Cache cleared"), "info")
                    end
                }
            }
        end
    })

    if self.plugin.ui and self.plugin.ui.document then
        local filepath = self.plugin.ui.document.file
        local is_linked = false
        if filepath then
            local book_id = self.plugin.sync:getOrMatchBook(filepath)
            if book_id then
                is_linked = true
            end
        end

        if not is_linked then
            table.insert(submenu, {
                text = _("Manual Match Current Book"),
                callback = function()
                    self.plugin.sync:matchCurrentBook()
                end
            })
        else
            table.insert(submenu, {
                text = _("Unlink Current Book"),
                callback = function()
                    self.plugin.sync:unlinkCurrentBook()
                end
            })
        end
    end

    table.insert(submenu, {
        text = _("Komga Browser"),
        callback = function(touchmenu_instance)
            if touchmenu_instance and touchmenu_instance.onCloseAllMenus then
                touchmenu_instance:onCloseAllMenus()
            end
            self:showBrowser()
        end
    })

    return submenu
end


-- UI prompt helper
function KomgaMenu:promptInput(title, setting_key, is_number)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local input
    input = InputDialog:new{
        title = title,
        input = tostring(self.plugin.settings[setting_key] or ""),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = input:getInputValue()
                        if is_number then
                            value = tonumber(value)
                            if not value then
                                self.plugin:notify(_("Invalid number"), "error")
                                return
                            end
                        end
                        self.plugin.settings[setting_key] = value
                        self.plugin:saveSettings()
                        if setting_key == "server_url" or setting_key == "api_key" then
                            self.plugin:initAPI()
                        end
                        self.plugin:notify(T(_("Updated %1"), title), "info")
                        UIManager:close(input)
                    end,
                },
            },
        },
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function KomgaMenu:promptSetup(on_success_callback)
    local _ = self.plugin.i18n._
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = _("Komga is not configured. Please set up connection."),
        buttons = {
            {
                {
                    text = _("Manual Setup"),
                    callback = function()
                        UIManager:close(dialog)
                        self:promptManualSetup(on_success_callback)
                    end
                },
                {
                    text = _("Auto-Generate API Key"),
                    callback = function()
                        UIManager:close(dialog)
                        self:promptAutoGenerate(on_success_callback)
                    end
                }
            },
            {
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
end

function KomgaMenu:promptManualSetup(on_success_callback)
    local _ = self.plugin.i18n._
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Manual Server Setup"),
        fields = {
            {
                text = self.plugin.settings.server_url or "http://",
                hint = _("Server URL"),
            },
            {
                text = self.plugin.settings.api_key or "",
                hint = _("API Key"),
            }
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local url, api_key = unpack(dialog:getFields())
                        local util = require("util")
                        url = util.trim(url)
                        api_key = util.trim(api_key)
                        
                        if url == "" then
                            self.plugin:notify(_("Server URL cannot be empty"), "error")
                            return
                        end
                        if api_key == "" then
                            self.plugin:notify(_("API Key cannot be empty"), "error")
                            return
                        end
                        
                        self.plugin.settings.server_url = url
                        self.plugin.settings.api_key = api_key
                        self.plugin:saveSettings()
                        self.plugin:initAPI()
                        
                        UIManager:close(dialog)
                        self.plugin:notify(_("Server connection saved"), "info")
                        if on_success_callback then
                            on_success_callback()
                        end
                    end
                }
            }
        }
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KomgaMenu:promptAutoGenerate(on_success_callback)
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Auto-Generate API Key"),
        fields = {
            {
                text = self.plugin.settings.server_url or "http://",
                hint = _("Server URL"),
            },
            {
                hint = _("Username/Email"),
            },
            {
                hint = _("Password"),
                text_type = "password",
            }
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end
                },
                {
                    text = _("Generate"),
                    is_enter_default = true,
                    callback = function()
                        local url, username, password = unpack(dialog:getFields())
                        local util = require("util")
                        url = util.trim(url)
                        username = util.trim(username)
                        
                        if url == "" then
                            self.plugin:notify(_("Server URL cannot be empty"), "error")
                            return
                        end
                        if username == "" or password == "" then
                            self.plugin:notify(_("Username and Password are required"), "error")
                            return
                        end
                        
                        UIManager:close(dialog)
                        
                        local NetworkMgr = require("ui/network/manager")
                        NetworkMgr:runWhenOnline(function()
                            UIManager:show(require("ui/widget/infomessage"):new{
                                text = _("Generating API Key. Please wait..."),
                                timeout = 2
                            })
                            
                            UIManager:scheduleIn(0.5, function()
                                local KomgaAPI = require(self.plugin.plugin_dir .. "core/api")
                                local api = KomgaAPI:new(url, "")
                                api:set_basic_auth(username, password)
                                
                                local Device = require("device")
                                local key_comment = "KOReader kokomga (" .. (Device.model or "Unknown Device") .. ")"
                                
                                local result, err = api:generate_api_key(key_comment)
                                if result and type(result) == "table" and result.key then
                                    self.plugin.settings.server_url = url
                                    self.plugin.settings.api_key = result.key
                                    self.plugin:saveSettings()
                                    self.plugin:initAPI()
                                    self.plugin:notify(_("API Key generated successfully!"), "info")
                                    if on_success_callback then
                                        on_success_callback()
                                    end
                                else
                                    self.plugin:notify(T(_("Generation failed: %1"), err or "Unknown error"), "error")
                                end
                            end)
                        end)
                    end
                }
            }
        }
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return KomgaMenu
