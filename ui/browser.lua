local Menu = require("ui/widget/menu")
local KomgaListMenu = require("ui/menus/list_menu")
local KomgaGridMenu = require("ui/menus/grid_menu")
local UIManager = require("ui/uimanager")
local logger = require("logger")

-- Capture base class methods once so setViewMode wrapping never double-wraps
local _base_list_recalc = KomgaListMenu._recalculateDimen
local _base_list_update = KomgaListMenu.updateItems
local _base_grid_recalc = KomgaGridMenu._recalculateDimen
local _base_grid_update = KomgaGridMenu.updateItems

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
    local _ = browser.plugin.i18n._
    local T = browser.plugin.i18n.T

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
                text = current_mode == "grid" and _("Switch to List View") or _("Switch to Grid View"),
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
                            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                            { text = _("Save"), callback = function()
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
                    text = _("List Rows"),
                    callback = function()
                        if browser.menu_dialog then UIManager:close(browser.menu_dialog) end
                        UIManager:show(createSettingDialog(_("List Rows"), "list_rows", 5))
                    end,
                    align = "left",
                } })
            else
                table.insert(buttons, { {
                    text = _("Grid Columns"),
                    callback = function()
                        if browser.menu_dialog then UIManager:close(browser.menu_dialog) end
                        UIManager:show(createSettingDialog(_("Grid Columns"), "grid_columns", 3))
                    end,
                    align = "left",
                } })
                
                table.insert(buttons, { {
                    text = _("Grid Rows"),
                    callback = function()
                        if browser.menu_dialog then UIManager:close(browser.menu_dialog) end
                        UIManager:show(createSettingDialog(_("Grid Rows"), "grid_rows", 3))
                    end,
                    align = "left",
                } })
            end
            
            if opts and opts.is_series then
                table.insert(buttons, {})
                table.insert(buttons, { {
                    text = _("Filter Series"),
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
    _pagination = nil,  -- { loader, server_page, total_pages, page_size }
}

function KomgaBrowser:init()
    self.paths = {}
    self._pagination = nil
    self.catalog_title = "Komga"
    self.title = "Komga"
    self.item_table = self:getHomeItemTable()
    
    self.title_bar_left_icon = "search"
    self.onLeftButtonTap = function() end
    self.close_callback = function()
        self:onCloseWidget()
        local NetworkMgr = require("ui/network/manager")
        NetworkMgr:afterWifiAction()
    end
    
    Menu.init(self)
    
    if self.title_bar and self.title_bar.left_button then
        hideWidget(self.title_bar.left_button)
    end
    self:autoSetViewMode(self.item_table)
end

-- ---------------------------------------------------------------------------
-- Page-size helper
-- ---------------------------------------------------------------------------

-- Returns the number of items to request per server page based on current settings.
-- has_covers: whether the catalog entries are expected to have cover art.
function KomgaBrowser:getPageSize(has_covers)
    local mode = self.plugin.settings.view_mode or "list"
    if not has_covers then
        return math.max(6, self.plugin.settings.list_rows or 5)
    end
    if mode == "grid" then
        local cols = self.plugin.settings.grid_columns or 3
        local rows = self.plugin.settings.grid_rows or 3
        return cols * rows
    else
        return self.plugin.settings.list_rows or 5
    end
end

-- ---------------------------------------------------------------------------
-- View mode + pagination-aware rendering
-- ---------------------------------------------------------------------------

function KomgaBrowser:autoSetViewMode(item_table)
    local has_covers = false
    if item_table and #item_table > 0 then
        local first = item_table[1]
        if first.cover_id or first.cover_type then
            has_covers = true
        else
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
        -- Wrap grid base methods so:
        --   _recalculateDimen overrides page_num with server total when paginating
        --   updateItems fetches more server data before rendering if needed
        self._recalculateDimen = function(s)
            _base_grid_recalc(s)
            if s._pagination then s.page_num = s._pagination.total_pages end
        end
        self.updateItems = function(s, select_number)
            s:_maybeLoadMore()
            _base_grid_update(s, select_number)
        end
        self.columns = self.plugin.settings.grid_columns or KomgaGridMenu.columns
        self.grid_rows = self.plugin.settings.grid_rows or 3
    else
        self._recalculateDimen = function(s)
            _base_list_recalc(s)
            if s._pagination then s.page_num = s._pagination.total_pages end
        end
        self.updateItems = function(s, select_number)
            s:_maybeLoadMore()
            _base_list_update(s, select_number)
        end
        self.columns = nil
        self.grid_rows = nil
        local Screen = require("device").screen
        local rows = self.plugin.settings.list_rows or 5
        self.item_height = math.floor(Screen:getHeight() / rows)
    end
    
    -- Recalibrate pagination when the mode switch changes page_size.
    -- Re-fetch page 0 from the server with the new size so future fetches
    -- use the correct page boundaries, and recalculate total_pages.
    -- Item_table is replaced in-place to preserve the reference in paths stack.
    if self._pagination then
        local p = self._pagination
        local new_page_size = self:getPageSize(p.has_covers)
        if new_page_size ~= p.page_size then
            logger.info("KomgaBrowser: page_size changed", p.page_size, "->", new_page_size, "; refetching page 0")
            local total_elements = p.total_elements or (p.total_pages * p.page_size)
            p.page_size = new_page_size
            p.total_pages = math.max(1, math.ceil(total_elements / new_page_size))
            p.server_page = 0
            -- Fetch page 0 with the new size and rebuild item_table in-place
            local new_items = p.loader(0, new_page_size) or {}
            for i = #self.item_table, 1, -1 do self.item_table[i] = nil end
            for _, item in ipairs(new_items) do table.insert(self.item_table, item) end
            if #self.item_table == 0 then
                table.insert(self.item_table, { text = self.plugin.i18n._("Nothing found") })
                p.total_pages = 1
            end
        end
    end

    -- Always start at page 1 when switching modes to avoid position
    -- mismatches (grid and list have different items-per-page counts)
    self.page = 1
    if self.item_table then
        self:updateItems()
    end
end

-- Fetch the next server page and append its items to item_table if the user
-- has paged into territory we haven't loaded yet.
--
-- IMPORTANT: We use p.page_size (not self.perpage) because in grid mode,
-- self.perpage = row count only (e.g. 3), while actual items per display page
-- = rows * cols (e.g. 9). p.page_size is always the true items-per-page for
-- both list and grid modes, since getPageSize() was designed to match exactly.
function KomgaBrowser:_maybeLoadMore()
    local p = self._pagination
    if not p or not p.loader then return end
    if p.server_page + 1 >= p.total_pages then return end  -- already have everything

    local needed_up_to = self.page * p.page_size

    if needed_up_to > #self.item_table then
        logger.info("KomgaBrowser: fetching server page", p.server_page + 1, "of", p.total_pages)
        p.server_page = p.server_page + 1
        local new_items = p.loader(p.server_page, p.page_size)
        if new_items and #new_items > 0 then
            for _, item in ipairs(new_items) do
                table.insert(self.item_table, item)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Navigation stack
-- ---------------------------------------------------------------------------

function KomgaBrowser:onReturn()
    table.remove(self.paths)
    local path = self.paths[#self.paths]
    if path then
        self.catalog_title = path.title
        -- Restore pagination state BEFORE switchItemTable triggers updateItems
        self._pagination = nil
        self:autoSetViewMode(path.item_table)
        self._pagination = path.opts and path.opts._pagination or nil
        self:switchItemTable(path.title, path.item_table)
        toggleTitleButtons(self, path.opts)
    else
        self:init()
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
    
    -- Clear pagination so autoSetViewMode's updateItems doesn't try to load more
    -- with the previous catalog's pagination state
    self._pagination = nil
    self:autoSetViewMode(item_table)
    -- Now set the real pagination before switchItemTable triggers the proper updateItems
    self._pagination = opts._pagination or nil
    
    self:switchItemTable(title, item_table)
    
    toggleTitleButtons(self, opts)
end

-- ---------------------------------------------------------------------------
-- Generic paginated catalog loader
-- ---------------------------------------------------------------------------

-- Fetches the first server page, builds item_table, wires up a lazy loader for
-- subsequent pages, and calls pushCatalog.
--
-- args = {
--   title        : string
--   fetch_func   : function(page, size) -> Komga paginated response (or plain array)
--   item_builder : function(entry) -> item table or nil
--   cover_type   : "series" | "book" | nil  (nil = no covers)
--   empty_text   : string  (shown when 0 items)
--   push_opts    : table   (merged with _pagination before pushCatalog)
-- }
function KomgaBrowser:_loadCatalog(args)
    local _ = self.plugin.i18n._
    local page_size = self:getPageSize(args.cover_type ~= nil)
    local response = args.fetch_func(0, page_size)

    -- Komga paginates with response.content / response.totalPages.
    -- get_libraries() returns a plain array (no pagination).
    local content, total_pages
    if type(response) == "table" then
        content = response.content or response
        total_pages = response.totalPages or 1
    end

    -- Prefetch covers for the first page
    if args.cover_type and type(content) == "table" then
        self.plugin.cache:prefetchCovers(content, args.cover_type)
    end

    -- Build initial item_table
    local item_table = {}
    if type(content) == "table" then
        for _, entry in ipairs(content) do
            local item = args.item_builder(entry)
            if item then table.insert(item_table, item) end
        end
    end
    if #item_table == 0 then
        table.insert(item_table, { text = args.empty_text and _(args.empty_text) or _("Nothing found") })
        total_pages = 1
    end

    -- Wire up lazy loader for pages 2+
    local push_opts = args.push_opts or {}
    if total_pages and total_pages > 1 then
        local cover_type = args.cover_type
        local item_builder = args.item_builder
        local fetch_func = args.fetch_func
        push_opts._pagination = {
            loader = function(server_page, size)
                local resp = fetch_func(server_page, size)
                if not resp then return {} end
                local new_content = (type(resp) == "table" and resp.content) or {}
                if cover_type then
                    self.plugin.cache:prefetchCovers(new_content, cover_type)
                end
                local items = {}
                for _, entry in ipairs(new_content) do
                    local item = item_builder(entry)
                    if item then table.insert(items, item) end
                end
                return items
            end,
            server_page = 0,
            total_pages = total_pages,
            total_elements = (type(response) == "table" and response.totalElements) or (total_pages * page_size),
            has_covers = (args.cover_type ~= nil),
            page_size = page_size,
        }
    end

    self:pushCatalog(args.title and _(args.title) or "", item_table, push_opts)
end

-- ---------------------------------------------------------------------------
-- Home screen
-- ---------------------------------------------------------------------------

function KomgaBrowser:getHomeItemTable()
    local _ = self.plugin.i18n._
    return {
        { text = _("Keep Reading"),          callback = function() self:showKeepReading() end },
        { text = _("On Deck"),               callback = function() self:showOnDeck() end },
        { text = _("Recently Added Series"), callback = function() self:showRecentSeries() end },
        { text = _("Recently Added Books"),  callback = function() self:showRecentBooks() end },
        { text = _("All Series"),            callback = function() self:showAllSeries() end },
        { text = _("Libraries"),             callback = function() self:showLibraries() end },
    }
end

-- ---------------------------------------------------------------------------
-- Catalog views — all use _loadCatalog for consistent paginated fetching
-- ---------------------------------------------------------------------------

function KomgaBrowser:showRecentSeries()
    if not self.plugin.api then return end
    self:_loadCatalog{
        title = "Recently Added Series",
        fetch_func = function(page, size) return self.plugin.api:get_new_series(page, size) end,
        item_builder = function(series)
            return {
                text = series.metadata and series.metadata.title or series.name,
                callback = function() self:showBooksInSeries(series.id, series.metadata and series.metadata.title or series.name) end,
                cover_id = series.id,
                cover_type = "series",
                series = series,
            }
        end,
        cover_type = "series",
        empty_text = "No recent series found",
    }
end

function KomgaBrowser:showKeepReading()
    if not self.plugin.api then return end
    self:_loadCatalog{
        title = "Keep Reading",
        fetch_func = function(page, size)
            return self.plugin.api:get_books({read_status = "IN_PROGRESS", sort = "readProgress.readDate,desc"}, page, size)
        end,
        item_builder = function(book)
            return {
                text = (book.seriesTitle and book.seriesTitle .. " - " or "") .. (book.metadata and book.metadata.title or book.name),
                callback = function() self:onBookSelect(book) end,
                cover_id = book.id,
                cover_type = "book",
                book = book,
            }
        end,
        cover_type = "book",
        empty_text = "Nothing in keep reading",
    }
end

function KomgaBrowser:showOnDeck()
    if not self.plugin.api then return end
    self:_loadCatalog{
        title = "On Deck",
        fetch_func = function(page, size) return self.plugin.api:get_books_ondeck(page, size) end,
        item_builder = function(book)
            return {
                text = (book.seriesTitle and book.seriesTitle .. " - " or "") .. (book.metadata and book.metadata.title or book.name),
                callback = function() self:onBookSelect(book) end,
                cover_id = book.id,
                cover_type = "book",
                book = book,
            }
        end,
        cover_type = "book",
        empty_text = "Nothing on deck",
    }
end

function KomgaBrowser:showRecentBooks()
    if not self.plugin.api then return end
    self:_loadCatalog{
        title = "Recently Added Books",
        fetch_func = function(page, size)
            return self.plugin.api:get_books({sort = "createdDate,desc"}, page, size)
        end,
        item_builder = function(book)
            return {
                text = (book.seriesTitle and book.seriesTitle .. " - " or "") .. (book.metadata and book.metadata.title or book.name),
                callback = function() self:onBookSelect(book) end,
                cover_id = book.id,
                cover_type = "book",
                book = book,
            }
        end,
        cover_type = "book",
        empty_text = "No recent books found",
    }
end

function KomgaBrowser:showAllSeries()
    if not self.plugin.api then return end
    -- get_series(nil, page, size) fetches all series without library filter
    self:_loadCatalog{
        title = "All Series",
        fetch_func = function(page, size) return self.plugin.api:get_series(nil, page, size) end,
        item_builder = function(series)
            return {
                text = series.metadata and series.metadata.title or series.name,
                callback = function() self:showBooksInSeries(series.id, series.metadata and series.metadata.title or series.name) end,
                cover_id = series.id,
                cover_type = "series",
                series = series,
            }
        end,
        cover_type = "series",
        empty_text = "No series found",
    }
end

function KomgaBrowser:showLibraries()
    if not self.plugin.api then return end
    -- Libraries are returned as a plain array (not paginated) — _loadCatalog handles this
    self:_loadCatalog{
        title = "Libraries",
        fetch_func = function(page, size) return self.plugin.api:get_libraries() end,
        item_builder = function(lib)
            return {
                text = lib.name,
                callback = function() self:showSeriesInLibrary(lib.id, lib.name) end,
            }
        end,
        empty_text = "No libraries found",
    }
end

function KomgaBrowser:showSeriesInLibrary(library_id, library_name)
    if not self.plugin.api then return end
    self:_loadCatalog{
        title = library_name,
        fetch_func = function(page, size) return self.plugin.api:get_series(library_id, page, size) end,
        item_builder = function(series)
            return {
                text = series.metadata and series.metadata.title or series.name,
                callback = function() self:showBooksInSeries(series.id, series.metadata and series.metadata.title or series.name) end,
                cover_id = series.id,
                cover_type = "series",
                series = series,
            }
        end,
        cover_type = "series",
        empty_text = "No series in library",
    }
end

function KomgaBrowser:showBooksInSeries(series_id, series_title, read_status)
    if not self.plugin.api then return end
    local _ = self.plugin.i18n._

    local display_title = series_title
    if read_status then
        local status_map = {
            ["UNREAD"] = _("Unread"),
            ["IN_PROGRESS"] = _("In Progress"),
            ["READ"] = _("Completed")
        }
        local status_str = ""
        if type(read_status) == "table" then
            if #read_status > 0 and #read_status < 3 then
                local mapped = {}
                for _, s in ipairs(read_status) do table.insert(mapped, status_map[s] or s) end
                status_str = " (" .. table.concat(mapped, ", ") .. ")"
            end
        else
            status_str = " (" .. (status_map[read_status] or read_status) .. ")"
        end
        display_title = series_title .. status_str
    end

    self:_loadCatalog{
        title = display_title,
        fetch_func = function(page, size)
            return self.plugin.api:get_books_for_series(series_id, {read_status = read_status}, page, size)
        end,
        item_builder = function(book)
            return {
                text = book.metadata and book.metadata.title or book.name,
                callback = function() self:onBookSelect(book) end,
                cover_id = book.id,
                cover_type = "book",
                book = book,
            }
        end,
        cover_type = "book",
        empty_text = "No books found",
        push_opts = {
            is_series = true,
            series_id = series_id,
            read_status = read_status,
            original_title = series_title,
        },
    }
end

-- ---------------------------------------------------------------------------
-- Filter dialog
-- ---------------------------------------------------------------------------

function KomgaBrowser:showFilterDialog(series_id, series_title, current_status)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    
    local selected = {}
    if current_status and type(current_status) == "table" then
        if current_status[1] then
            for _, v in ipairs(current_status) do selected[v] = true end
        else
            for k, v in pairs(current_status) do selected[k] = v end
        end
    elseif current_status and type(current_status) == "string" then
        selected[current_status] = true
    else
        selected = { UNREAD = true, IN_PROGRESS = true, READ = true }
    end

    local function toggle_action(id)
        return function() selected[id] = not selected[id] end
    end
    
    local function apply_action()
        return function()
            UIManager:close(dialog)
            local status_list = {}
            for k, v in pairs(selected) do
                if v then table.insert(status_list, k) end
            end
            self:onReturn()  -- Pop current series view
            self:showBooksInSeries(series_id, series_title, status_list)
        end
    end
    
    dialog = ButtonDialog:new{
        title = T(_("Filter: %1"), series_title),
        buttons = {
            {
                { text = _("Unread"),      checked_func = function() return selected["UNREAD"] end,      callback = toggle_action("UNREAD") },
                { text = _("In Progress"), checked_func = function() return selected["IN_PROGRESS"] end, callback = toggle_action("IN_PROGRESS") },
                { text = _("Completed"),   checked_func = function() return selected["READ"] end,        callback = toggle_action("READ") }
            },
            {
                { text = _("Apply Filter"), callback = apply_action() },
                { text = _("Cancel"),       callback = function() UIManager:close(dialog) end }
            }
        }
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------------
-- Book selection
-- ---------------------------------------------------------------------------

function KomgaBrowser:onBookSelect(book)
    if not self.selected_books then
        self.selected_books = {}
    end
    local book_id = book.id
    if self.selected_books[book_id] then
        self.selected_books[book_id] = nil
        logger.info("KomgaBrowser: Deselected book", book_id)
    else
        self.selected_books[book_id] = book
        logger.info("KomgaBrowser: Selected book", book_id)
    end
    self:updateItems()
end

function KomgaBrowser:onMenuHold(entry)
    local is_book = false
    if entry then
        if entry.cover_type == "book" or entry.book ~= nil then
            is_book = true
        elseif entry.id and not entry.cover_type and not entry.callback then
            is_book = true
        end
    end
    if not is_book then
        return
    end

    local _ = self.plugin.i18n._
    local T = self.plugin.i18n.T
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    
    local buttons = {}
    
    -- Option 1: "Download this book"
    local target_book = nil
    if entry and entry.cover_type == "book" and entry.book then
        target_book = entry.book
    elseif entry and entry.id and not entry.cover_type then
        target_book = entry
    end
    
    if target_book then
        local title = target_book.metadata and target_book.metadata.title or target_book.name or "this book"
        table.insert(buttons, { {
            text = T(_("Download '%1'"), title),
            callback = function()
                UIManager:close(dialog)
                self.plugin.sync:downloadBook(target_book, target_book.seriesTitle)
            end,
            align = "left"
        } })
    end
    
    -- Option 2: "Download X selected books"
    local selected_list = {}
    if self.selected_books then
        if self.item_table then
            for _, item in ipairs(self.item_table) do
                if item.cover_type == "book" and self.selected_books[item.cover_id] then
                    table.insert(selected_list, item.book)
                end
            end
        end
        local inserted_ids = {}
        for _, b in ipairs(selected_list) do
            inserted_ids[b.id] = true
        end
        for id, b in pairs(self.selected_books) do
            if not inserted_ids[id] then
                table.insert(selected_list, b)
            end
        end
    end
    
    if #selected_list > 0 then
        local selected_to_download = {}
        local selected_already_downloaded_count = 0
        for _, b in ipairs(selected_list) do
            if self.plugin.sync:isBookDownloaded(b) then
                selected_already_downloaded_count = selected_already_downloaded_count + 1
            else
                table.insert(selected_to_download, b)
            end
        end

        if #selected_to_download > 0 then
            local text
            if selected_already_downloaded_count > 0 then
                text = T(_("Download remaining %1 selected books"), #selected_to_download)
            else
                text = T(_("Download %1 selected books"), #selected_to_download)
            end
            table.insert(buttons, { {
                text = text,
                callback = function()
                    UIManager:close(dialog)
                    self.plugin.sync:downloadBooksSeq(selected_to_download, 1, function()
                        self.plugin:notify(_("All selected downloads finished!"), "info")
                        self.selected_books = {}
                        self:updateItems()
                    end)
                end,
                align = "left"
            } })
        else
            table.insert(buttons, { {
                text = T(_("All %1 selected books are already downloaded"), #selected_list),
                callback = function()
                    UIManager:close(dialog)
                end,
                align = "left"
            } })
        end
    end
    
    -- Option 3: "Download all books on this page"
    local all_books = {}
    if self.item_table then
        local start_idx = 1
        local end_idx = #self.item_table
        if self._pagination then
            local p = self._pagination
            local page_num = self.page or 1
            start_idx = math.max(1, (page_num - 1) * p.page_size + 1)
            end_idx = math.min(#self.item_table, page_num * p.page_size)
        end
        for i = start_idx, end_idx do
            local item = self.item_table[i]
            if item and item.cover_type == "book" and item.book then
                table.insert(all_books, item.book)
            end
        end
    end
    
    if #all_books > 0 then
        local all_to_download = {}
        local all_already_downloaded_count = 0
        for _, b in ipairs(all_books) do
            if self.plugin.sync:isBookDownloaded(b) then
                all_already_downloaded_count = all_already_downloaded_count + 1
            else
                table.insert(all_to_download, b)
            end
        end

        if #all_to_download > 0 then
            local text
            if all_already_downloaded_count > 0 then
                text = T(_("Download remaining %1 books on this page"), #all_to_download)
            else
                text = T(_("Download all %1 books on this page"), #all_to_download)
            end
            table.insert(buttons, { {
                text = text,
                callback = function()
                    UIManager:close(dialog)
                    self.plugin.sync:downloadBooksSeq(all_to_download, 1, function()
                        self.plugin:notify(_("All downloads finished!"), "info")
                        self.selected_books = {}
                        self:updateItems()
                    end)
                end,
                align = "left"
            } })
        else
            table.insert(buttons, { {
                text = T(_("All %1 books on this page are already downloaded"), #all_books),
                callback = function()
                    UIManager:close(dialog)
                end,
                align = "left"
            } })
        end
    end
    
    -- Option 4: "Cancel"
    table.insert(buttons, { {
        text = _("Cancel"),
        callback = function()
            UIManager:close(dialog)
        end,
        align = "center"
    } })
    
    dialog = ButtonDialog:new{
        title = _("Bulk Download Options"),
        buttons = buttons,
        shrink_unneeded_width = true,
    }
    UIManager:show(dialog)
end

return KomgaBrowser
