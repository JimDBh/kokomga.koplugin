local Menu = require("ui/widget/menu")
local KomgaListMenu = require("ui/menus/list_menu")
local KomgaGridMenu = require("ui/menus/grid_menu")
local UIManager = require("ui/uimanager")

local function hideWidget(w)
    if not w then return end
    w.ignore = true
    if not w._orig_paintTo then
        w._orig_paintTo = w.paintTo
        w.paintTo = function() end
        w._orig_handleEvent = w.handleEvent
        w.handleEvent = function() return false end
    end
end

local function showWidget(w)
    if not w then return end
    w.ignore = false
    if w._orig_paintTo then
        w.paintTo = w._orig_paintTo
        w._orig_paintTo = nil
        w.handleEvent = w._orig_handleEvent
        w._orig_handleEvent = nil
    end
end

local function toggleTitleButtons(browser, opts)
    local title_bar = browser.title_bar
    if not title_bar then return end

    local is_home = (#browser.paths == 0)
    
    if is_home then
        if title_bar.menu_btn then hideWidget(title_bar.menu_btn) end
    else
        if not title_bar.menu_btn then
            local Button = require("ui/widget/button")
            local Screen = require("device").screen
            title_bar.menu_btn = Button:new{
                icon = "appbar.menu",
                bordersize = 0,
                show_parent = title_bar,
                callback = function() end
            }
            title_bar.menu_btn.overlap_align = "left"
            title_bar.menu_btn.overlap_offset = { Screen:scaleBySize(10), 0 }
            title_bar.menu_btn:getSize()
            table.insert(title_bar, title_bar.menu_btn)
        end
        
        showWidget(title_bar.menu_btn)
        title_bar.menu_btn.callback = function()
            local ButtonDialog = require("ui/widget/buttondialog")
            local buttons = {}
            local current_mode = browser.view_mode
            
            table.insert(buttons, { {
                text = current_mode == "grid" and "Switch to List View" or "Switch to Grid View",
                callback = function()
                    if browser.menu_dialog then UIManager:close(browser.menu_dialog) end
                    local new_mode = current_mode == "grid" and "list" or "grid"
                    browser:setViewMode(new_mode)
                end,
                align = "left",
            } })
            
            table.insert(buttons, {})
            
            local InputDialog = require("ui/widget/inputdialog")
            
            local function createSettingDialog(title, key, default_val)
                local dialog
                dialog = InputDialog:new{
                    title = title,
                    input = tostring(browser.plugin.settings[key] or default_val),
                    buttons = {
                        {
                            { text = "Cancel", callback = function() UIManager:close(dialog) end },
                            { text = "Save", callback = function()
                                local val = tonumber(dialog:getInputText())
                                if val then
                                    browser.plugin.settings[key] = val
                                    browser.plugin:saveSettings()
                                    browser:setViewMode(browser.view_mode, false)
                                end
                                UIManager:close(dialog)
                            end }
                        }
                    }
                }
                return dialog
            end

            if current_mode == "list" then
                table.insert(buttons, { {
                    text = "List Row Height",
                    callback = function()
                        if browser.menu_dialog then UIManager:close(browser.menu_dialog) end
                        UIManager:show(createSettingDialog("List Row Height", "list_row_height", 110))
                    end,
                    align = "left",
                } })
            else
                table.insert(buttons, { {
                    text = "Grid Columns",
                    callback = function()
                        if browser.menu_dialog then UIManager:close(browser.menu_dialog) end
                        UIManager:show(createSettingDialog("Grid Columns", "grid_columns", 3))
                    end,
                    align = "left",
                } })
                
                table.insert(buttons, { {
                    text = "Grid Rows",
                    callback = function()
                        if browser.menu_dialog then UIManager:close(browser.menu_dialog) end
                        UIManager:show(createSettingDialog("Grid Rows", "grid_rows", 3))
                    end,
                    align = "left",
                } })
            end
            
            if opts and opts.is_series then
                table.insert(buttons, {})
                table.insert(buttons, { {
                    text = "Filter Series",
                    callback = function()
                        if browser.menu_dialog then UIManager:close(browser.menu_dialog) end
                        browser:showFilterDialog(opts.series_id, opts.original_title, opts.read_status)
                    end,
                    align = "left",
                } })
            end
            
            browser.menu_dialog = ButtonDialog:new{
                buttons = buttons,
                shrink_unneeded_width = true,
                anchor = function() return title_bar.menu_btn.dimen end,
            }
            UIManager:show(browser.menu_dialog)
        end
    end
    
    -- Clean up legacy buttons if they exist
    if title_bar.view_btn then hideWidget(title_bar.view_btn) end
    if title_bar.filter_btn then hideWidget(title_bar.filter_btn) end

    -- Always hide the default left button (search)
    hideWidget(title_bar.left_button)
    browser.onLeftButtonTap = function() end
    
    UIManager:setDirty(title_bar, "ui")
end

local KomgaBrowser = KomgaListMenu:extend{
    is_interactive = true,
    is_fullscreen = true,
    covers_fullscreen = true,
    is_borderless = true,
    is_popout = false,
    title_bar_fm_style = true,
    plugin = nil,
    paths = nil,
}

function KomgaBrowser:init()
    self.paths = {}
    self.catalog_title = "Komga"
    self.title = "Komga"
    self.item_table = self:getHomeItemTable()
    
    self.title_bar_left_icon = "search"
    self.onLeftButtonTap = function() end
    self.close_callback = function()
        self:onCloseWidget()
    end
    
    Menu.init(self)
    
    if self.title_bar and self.title_bar.left_button then
        hideWidget(self.title_bar.left_button)
    end
    self:autoSetViewMode(self.item_table)
end

function KomgaBrowser:autoSetViewMode(item_table)
    local has_covers = false
    if item_table and #item_table > 0 then
        -- Fast check first item
        local first = item_table[1]
        if first.cover_id or first.cover_type then
            has_covers = true
        else
            -- Check at least a few items in case the first is a text-only header
            for i = 1, math.min(#item_table, 5) do
                if item_table[i].cover_id or item_table[i].cover_type then
                    has_covers = true
                    break
                end
            end
        end
    end
    
    local is_home = (#self.paths == 0)
    if is_home or not has_covers then
        self:setViewMode("list", false)
    else
        self:setViewMode(self.plugin.settings.view_mode or "list", false)
    end
end

function KomgaBrowser:setViewMode(mode, save_preference)
    self.view_mode = mode
    if save_preference ~= false then
        self.plugin.settings.view_mode = mode
        self.plugin:saveSettings()
    end
    
    if mode == "grid" then
        self._recalculateDimen = KomgaGridMenu._recalculateDimen
        self.updateItems = KomgaGridMenu.updateItems
        self.columns = self.plugin.settings.grid_columns or KomgaGridMenu.columns
        self.grid_rows = self.plugin.settings.grid_rows or 3
    else
        self._recalculateDimen = KomgaListMenu._recalculateDimen
        self.updateItems = KomgaListMenu.updateItems
        self.columns = nil
        self.grid_rows = nil
        self.item_height = self.plugin.settings.list_row_height or KomgaListMenu.item_height
    end
    
    if self.item_table then
        self:updateItems()
    end
end

function KomgaBrowser:onReturn()
    table.remove(self.paths)
    local path = self.paths[#self.paths]
    if path then
        self.catalog_title = path.title
        self:autoSetViewMode(path.item_table)
        self:switchItemTable(path.title, path.item_table)
        toggleTitleButtons(self, path.opts)
    else
        self:init() -- Reset internal state
        self:switchItemTable(self.catalog_title, self.item_table)
        toggleTitleButtons(self, nil)
    end
    return true
end

function KomgaBrowser:onHoldReturn()
    self:init()
    self:switchItemTable(self.catalog_title, self.item_table)
    toggleTitleButtons(self, nil)
    return true
end

function KomgaBrowser:pushCatalog(title, item_table, opts)
    opts = opts or {}
    table.insert(self.paths, {
        title = title,
        item_table = item_table,
        opts = opts
    })
    self.catalog_title = title
    
    self:autoSetViewMode(item_table)
    
    self:switchItemTable(title, item_table)
    
    toggleTitleButtons(self, opts)
end

function KomgaBrowser:getHomeItemTable()
    return {
        { text = "Keep Reading", callback = function() self:showKeepReading() end },
        { text = "On Deck", callback = function() self:showOnDeck() end },
        { text = "Recently Added Series", callback = function() self:showRecentSeries() end },
        { text = "Recently Added Books", callback = function() self:showRecentBooks() end },
        { text = "All Series", callback = function() self:showAllSeries() end },
        { text = "Libraries", callback = function() self:showLibraries() end },
    }
end

-- ---------------------------------------------------------------------------
-- API Integration
-- ---------------------------------------------------------------------------

function KomgaBrowser:showRecentSeries()
    if not self.plugin.api then return end
    local series_list = self.plugin.api:get_new_series()
    local item_table = {}
    if series_list and series_list.content then
        self.plugin.cache:prefetchCovers(series_list.content, "series")
        for _, series in ipairs(series_list.content) do
            table.insert(item_table, {
                text = series.metadata.title,
                callback = function() self:showBooksInSeries(series.id, series.metadata.title) end,
                cover_id = series.id,
                cover_type = "series"
            })
        end
    end
    if #item_table == 0 then table.insert(item_table, { text = "No recent series found" }) end
    self:pushCatalog("Recent Series", item_table)
end

function KomgaBrowser:showKeepReading()
    if not self.plugin.api then return end
    local book_list = self.plugin.api:get_books({read_status = "IN_PROGRESS", sort = "readProgress.readDate,desc"})
    local item_table = {}
    if book_list and book_list.content then
        self.plugin.cache:prefetchCovers(book_list.content, "book")
        for _, book in ipairs(book_list.content) do
            table.insert(item_table, {
                text = (book.seriesTitle and book.seriesTitle .. " - " or "") .. book.metadata.title,
                callback = function() self:onBookSelect(book) end,
                cover_id = book.id,
                cover_type = "book"
            })
        end
    end
    if #item_table == 0 then table.insert(item_table, { text = "Nothing in keep reading" }) end
    self:pushCatalog("Keep Reading", item_table)
end

function KomgaBrowser:showOnDeck()
    if not self.plugin.api then return end
    local book_list = self.plugin.api:get_books_ondeck()
    local item_table = {}
    if book_list and book_list.content then
        self.plugin.cache:prefetchCovers(book_list.content, "book")
        for _, book in ipairs(book_list.content) do
            table.insert(item_table, {
                text = (book.seriesTitle and book.seriesTitle .. " - " or "") .. book.metadata.title,
                callback = function() self:onBookSelect(book) end,
                cover_id = book.id,
                cover_type = "book"
            })
        end
    end
    if #item_table == 0 then table.insert(item_table, { text = "Nothing on deck" }) end
    self:pushCatalog("On Deck", item_table)
end

function KomgaBrowser:showRecentBooks()
    if not self.plugin.api then return end
    local book_list = self.plugin.api:get_books({sort = "createdDate,desc"})
    local item_table = {}
    if book_list and book_list.content then
        self.plugin.cache:prefetchCovers(book_list.content, "book")
        for _, book in ipairs(book_list.content) do
            table.insert(item_table, {
                text = (book.seriesTitle and book.seriesTitle .. " - " or "") .. book.metadata.title,
                callback = function() self:onBookSelect(book) end,
                cover_id = book.id,
                cover_type = "book"
            })
        end
    end
    if #item_table == 0 then table.insert(item_table, { text = "No recent books found" }) end
    self:pushCatalog("Recent Books", item_table)
end

function KomgaBrowser:showAllSeries()
    if not self.plugin.api then return end
    local series_list = self.plugin.api:request("/api/v1/series?size=100")
    local item_table = {}
    if series_list and series_list.content then
        self.plugin.cache:prefetchCovers(series_list.content, "series")
        for _, series in ipairs(series_list.content) do
            table.insert(item_table, {
                text = series.metadata.title,
                callback = function() self:showBooksInSeries(series.id, series.metadata.title) end,
                cover_id = series.id,
                cover_type = "series"
            })
        end
    end
    if #item_table == 0 then table.insert(item_table, { text = "No series found" }) end
    self:pushCatalog("All Series", item_table)
end

function KomgaBrowser:showLibraries()
    if not self.plugin.api then return end
    local libs = self.plugin.api:get_libraries()
    local item_table = {}
    if libs then
        for _, lib in ipairs(libs) do
            table.insert(item_table, {
                text = lib.name,
                callback = function() self:showSeriesInLibrary(lib.id, lib.name) end
            })
        end
    end
    if #item_table == 0 then table.insert(item_table, { text = "No libraries found" }) end
    self:pushCatalog("Libraries", item_table)
end

function KomgaBrowser:showSeriesInLibrary(library_id, library_name)
    if not self.plugin.api then return end
    local series_list = self.plugin.api:get_series(library_id)
    local item_table = {}
    if series_list and series_list.content then
        -- get_series already calls prefetchCovers internally if cache is configured, but we force it here for explicit scoping
        self.plugin.cache:prefetchCovers(series_list.content, "series")
        for _, series in ipairs(series_list.content) do
            table.insert(item_table, {
                text = series.metadata.title,
                callback = function() self:showBooksInSeries(series.id, series.metadata.title) end,
                cover_id = series.id,
                cover_type = "series"
            })
        end
    end
    if #item_table == 0 then table.insert(item_table, { text = "No series in library" }) end
    self:pushCatalog(library_name, item_table)
end

function KomgaBrowser:showBooksInSeries(series_id, series_title, read_status)
    if not self.plugin.api then return end
    local book_list = self.plugin.api:get_books_for_series(series_id, {read_status = read_status})
    local item_table = {}
    if book_list and book_list.content then
        self.plugin.cache:prefetchCovers(book_list.content, "book")
        for _, book in ipairs(book_list.content) do
            table.insert(item_table, {
                text = (book.seriesTitle and book.seriesTitle .. " - " or "") .. book.metadata.title,
                callback = function() self:onBookSelect(book) end,
                cover_id = book.id,
                cover_type = "book"
            })
        end
    end
    if #item_table == 0 then table.insert(item_table, { text = "No books found" }) end
    
    local display_title = series_title
    if read_status then
        local status_map = {
            ["UNREAD"] = "Unread",
            ["IN_PROGRESS"] = "In Progress",
            ["READ"] = "Completed"
        }
        display_title = series_title .. " (" .. (status_map[read_status] or read_status) .. ")"
    end
    
    self:pushCatalog(display_title, item_table, { is_series = true, series_id = series_id, read_status = read_status, original_title = series_title })
end

function KomgaBrowser:showFilterDialog(series_id, series_title, current_status)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function filter_action(status)
        return function()
            UIManager:close(dialog)
            self:onReturn() -- Pop the current series view
            self:showBooksInSeries(series_id, series_title, status)
        end
    end
    
    local status_map = {
        ["UNREAD"] = "Unread",
        ["IN_PROGRESS"] = "In Progress",
        ["READ"] = "Completed"
    }
    local current = current_status and status_map[current_status] or "All"
    
    dialog = ButtonDialog:new{
        title = "Filter: " .. series_title .. "\n(Currently Selected: " .. current .. ")",
        buttons = {
            {
                { text = (current == "All" and ">>> All <<<" or "All"), callback = filter_action(nil) },
                { text = (current == "Unread" and ">>> Unread <<<" or "Unread"), callback = filter_action("UNREAD") }
            },
            {
                { text = (current == "In Progress" and ">>> In Progress <<<" or "In Progress"), callback = filter_action("IN_PROGRESS") },
                { text = (current == "Completed" and ">>> Completed <<<" or "Completed"), callback = filter_action("READ") }
            }
        }
    }
    UIManager:show(dialog)
end

function KomgaBrowser:onBookSelect(book)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = "Download '" .. book.metadata.title .. "'?",
        ok_callback = function()
            if self.plugin and self.plugin.sync then
                self.plugin.sync:downloadBook(book, book.seriesTitle)
            else
                self.plugin:notify("Sync module not initialized", "error")
            end
        end,
    })
end

return KomgaBrowser
