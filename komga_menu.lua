--[[
    Komga UI Menu Generator
    Builds KOReader standard menu trees for libraries and settings.
--]]

local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local logger = require("logger")

local KomgaMenu = {}

function KomgaMenu:new(plugin)
    local o = { plugin = plugin }
    return setmetatable(o, { __index = self })
end

-- Plugin settings sub-menu
function KomgaMenu:createSettingsMenu()
    local submenu = {}
    
    table.insert(submenu, {
        text = "Server Setup",
        keep_menu_open = true,
        sub_item_table_func = function()
            return {
                {
                    text = "Server URL",
                    keep_menu_open = true,
                    callback = function() self:promptInput("Server URL", "server_url") end
                },
                {
                    text = "API Key",
                    keep_menu_open = true,
                    callback = function() self:promptInput("API Key", "api_key") end
                }
            }
        end
    })

    table.insert(submenu, {
        text = "Options",
        keep_menu_open = true,
        sub_item_table_func = function()
            return {
                {
                    text = "Custom Download Dir",
                    keep_menu_open = true,
                    callback = function() self:promptInput("Download Dir (e.g. /sdcard/Books/Komga)", "download_dir") end
                },
                {
                    text = "Sync behavior",
                    keep_menu_open = true,
                    sub_item_table_func = function()
                        return {
                            {
                                text = "Auto-Sync Read Progress",
                                checked_func = function() return self.plugin.settings.auto_sync_on_open end,
                                keep_menu_open = true,
                                callback = function()
                                    self.plugin.settings.auto_sync_on_open = not self.plugin.settings.auto_sync_on_open
                                    self.plugin.settings.auto_sync_on_close = self.plugin.settings.auto_sync_on_open
                                    self.plugin:saveSettings()
                                end
                            },
                            {
                                text_func = function()
                                    local strategy = self.plugin.settings.sync_forward or 1
                                    local strategy_name = strategy == 1 and "Prompt" or (strategy == 2 and "Silently" or "Never")
                                    return "Sync to a newer state (" .. strategy_name .. ")"
                                end,
                                keep_menu_open = true,
                                sub_item_table_func = function()
                                    return {
                                        {
                                            text = "Prompt",
                                            checked_func = function() return self.plugin.settings.sync_forward == 1 end,
                                            callback = function() self.plugin.settings.sync_forward = 1; self.plugin:saveSettings() end
                                        },
                                        {
                                            text = "Silently update",
                                            checked_func = function() return self.plugin.settings.sync_forward == 2 end,
                                            callback = function() self.plugin.settings.sync_forward = 2; self.plugin:saveSettings() end
                                        },
                                        {
                                            text = "Never",
                                            checked_func = function() return self.plugin.settings.sync_forward == 3 end,
                                            callback = function() self.plugin.settings.sync_forward = 3; self.plugin:saveSettings() end
                                        }
                                    }
                                end
                            },
                            {
                                text_func = function()
                                    local strategy = self.plugin.settings.sync_backward or 1
                                    local strategy_name = strategy == 1 and "Prompt" or (strategy == 2 and "Silently" or "Never")
                                    return "Sync to an older state (" .. strategy_name .. ")"
                                end,
                                keep_menu_open = true,
                                sub_item_table_func = function()
                                    return {
                                        {
                                            text = "Prompt",
                                            checked_func = function() return self.plugin.settings.sync_backward == 1 end,
                                            callback = function() self.plugin.settings.sync_backward = 1; self.plugin:saveSettings() end
                                        },
                                        {
                                            text = "Silently update",
                                            checked_func = function() return self.plugin.settings.sync_backward == 2 end,
                                            callback = function() self.plugin.settings.sync_backward = 2; self.plugin:saveSettings() end
                                        },
                                        {
                                            text = "Never",
                                            checked_func = function() return self.plugin.settings.sync_backward == 3 end,
                                            callback = function() self.plugin.settings.sync_backward = 3; self.plugin:saveSettings() end
                                        }
                                    }
                                end
                            },
                            {
                                text = function()
                                    local pages = self.plugin.settings.sync_interval_pages or 5
                                    return "Auto-push progress every " .. pages .. " pages"
                                end,
                                keep_menu_open = true,
                                callback = function() self:promptInput("Update frequency (X pages, 0 to disable)", "sync_interval_pages", true) end
                            }
                        }
                    end
                },
                {
                    text = "Download into Series Subfolders",
                    checked_func = function() return self.plugin.settings.download_to_subfolder end,
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.settings.download_to_subfolder = not self.plugin.settings.download_to_subfolder
                        self.plugin:saveSettings()
                    end
                },
                {
                    text = "Clean Cache",
                    keep_menu_open = true,
                    callback = function()
                        self.plugin.cache:clear()
                        self.plugin:notify("Cache cleared", "info")
                    end
                }
            }
        end
    })

    table.insert(submenu, {
        text = "Komga Browser (New)",
        callback = function()
            local KomgaBrowser = require("komga_browser")
            local browser = KomgaBrowser:new{ plugin = self.plugin }
            UIManager:show(browser)
        end
    })

    table.insert(submenu, {
        text = "Explore Libs",
        keep_menu_open = true,
        sub_item_table_func = function() return self:createLibrariesMenu() end
    })

    return submenu
end

-- Library explorer menu
function KomgaMenu:createLibrariesMenu()
    local submenu = {}
    
    -- Show loading or placeholder if network is needed during menu eval... 
    -- Actually this executes synchronously when menu is opened.
    local libraries, err = self.plugin.cache:getLibraries()
    
    if not libraries then
        logger.err("KomgaMenu: Error fetching libraries:", tostring(err))
        table.insert(submenu, { text = "Error: " .. tostring(err), callback = function() end })
        return submenu
    end
    
    logger.dbg("KomgaMenu: Found", #libraries, "libraries")
    for _, lib in ipairs(libraries) do
        table.insert(submenu, {
            text = lib.name or "Library",
            keep_menu_open = true,
            sub_item_table_func = function() return self:createSeriesMenu(lib.id, lib.name) end
        })
    end
    
    return submenu
end

-- Series list menu
function KomgaMenu:createSeriesMenu(library_id, library_name)
    local submenu = {}
    local series_page, err = self.plugin.cache:getSeries(library_id)
    
    if not series_page or not series_page.content then
        logger.err("KomgaMenu: Error fetching series:", tostring(err))
        table.insert(submenu, { text = "No series or Error", callback = function() end })
        return submenu
    end
    
    logger.dbg("KomgaMenu: Found", #series_page.content, "series for library_id", library_id)
    for _, series in ipairs(series_page.content) do
        table.insert(submenu, {
            text = series.name or "Series",
            keep_menu_open = true,
            sub_item_table_func = function() return self:createBooksMenu(series.id, series.name) end
        })
    end
    
    return submenu
end

-- Books list menu
function KomgaMenu:createBooksMenu(series_id, series_title)
    local submenu = {}
    local books_page, err = self.plugin.cache:getBooks(series_id)
    
    if not books_page or not books_page.content then
        logger.err("KomgaMenu: Error fetching books:", tostring(err))
        table.insert(submenu, { text = "No books or Error", callback = function() end })
        return submenu
    end
    
    logger.dbg("KomgaMenu: Found", #books_page.content, "books for series_id", series_id)
    for _, book in ipairs(books_page.content) do
        table.insert(submenu, {
            text = book.name or "Book",
            callback = function()
                self.plugin.sync:downloadBook(book, series_title)
            end
        })
    end
    
    return submenu
end

-- UI prompt helper
function KomgaMenu:promptInput(title, setting_key, is_number)
    local input
    input = InputDialog:new{
        title = title,
        input = tostring(self.plugin.settings[setting_key] or ""),
        buttons = {
            {
                {
                    text = "Cancel",
                    id = "close",
                    callback = function()
                        UIManager:close(input)
                    end,
                },
                {
                    text = "Save",
                    callback = function()
                        local value = input:getInputValue()
                        if is_number then
                            value = tonumber(value)
                            if not value then
                                self.plugin:notify("Invalid number", "error")
                                return
                            end
                        end
                        self.plugin.settings[setting_key] = value
                        self.plugin:saveSettings()
                        if setting_key == "server_url" or setting_key == "api_key" then
                            self.plugin:initAPI()
                        end
                        self.plugin:notify("Updated " .. title, "info")
                        UIManager:close(input)
                    end,
                },
            },
        },
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

return KomgaMenu
