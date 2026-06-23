local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local Screen = Device.screen
local _ = require("gettext")
local logger = require("logger")

local Screen = require("device").screen

local GRID_LAYOUT = {
    padding = Screen:scaleBySize(6),
    cover_text_gap = Screen:scaleBySize(8),
    text_height = Screen:scaleBySize(45),
}

local KomgaGridItem = InputContainer:extend{
    entry = nil,
    width = nil,
    height = nil,
    menu = nil,
}

function KomgaGridItem:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
        HoldSelect = {
            GestureRange:new{ ges = "hold", range = self.dimen },
        },
    }
    local _ = self.menu and self.menu.plugin and self.menu.plugin.i18n and self.menu.plugin.i18n._ or function(s) return s end
    local title_text = self.entry.text or self.entry.title or _("Unknown")
    if self.entry.cover_type == "book" and not self.entry.cover_id then
        if self.menu and self.menu.selected_books and self.menu.selected_books[self.entry.cover_id] then
            title_text = "[✓] " .. title_text
        else
            title_text = "[ ] " .. title_text
        end
    end
    local text_width = self.width - (GRID_LAYOUT.padding * 2)
    
    local cover_widget
    if self.entry.cover_id and self.entry.cover_type then
        local DataStorage = require("datastorage")
        local lfs = require("libs/libkoreader-lfs")
        local covers_dir = DataStorage:getDataDir() .. "/komga_covers"
        local cache_key = self.entry.cover_type .. "_" .. self.entry.cover_id
        local local_path = covers_dir .. "/" .. cache_key .. ".jpg"
        
        -- Space taken by text and padding
        local v_text_space = GRID_LAYOUT.text_height + GRID_LAYOUT.cover_text_gap
        local v_padding = GRID_LAYOUT.padding * 2
        local cover_h = self.height - v_text_space - v_padding
        local cover_w = math.floor(cover_h * 2 / 3)
        
        -- Ensure cover doesn't exceed cell width
        local max_w = self.width - (GRID_LAYOUT.padding * 2)
        if cover_w > max_w then
            cover_w = max_w
            cover_h = math.floor(cover_w * 3 / 2)
        end
        
        if lfs.attributes(local_path, "mode") == "file" then
            local ImageWidget = require("ui/widget/imagewidget")
            cover_widget = ImageWidget:new{
                file = local_path,
                width = cover_w,
                height = cover_h,
                alpha = true,
            }
        else
            -- Placeholder when cover is missing but expected
            cover_widget = CenterContainer:new{
                dimen = Geom:new{ w = cover_w, h = cover_h },
                TextWidget:new{
                    text = "📖",
                    face = Font:getFace("cfont", 60),
                }
            }
        end

        local function create_badge(text, font_size, is_progress)
            local badge_w, badge_h
            if is_progress then
                local text_len = string.len(text)
                badge_w = math.floor(Screen:scaleBySize(12) + text_len * Screen:scaleBySize(6))
                badge_h = Screen:scaleBySize(18)
            else
                badge_w = Screen:scaleBySize(22)
                badge_h = Screen:scaleBySize(22)
            end

            local badge = FrameContainer:new{
                bordersize = Screen:scaleBySize(1),
                padding = 0,
                background = Blitbuffer.COLOR_WHITE,
                dimen = Geom:new{ w = badge_w, h = badge_h },
                CenterContainer:new{
                    dimen = Geom:new{ w = badge_w, h = badge_h },
                    TextWidget:new{
                        text = text,
                        face = Font:getFace("smallinfofont", font_size or 11),
                        fgcolor = Blitbuffer.COLOR_BLACK,
                    }
                }
            }
            return badge, badge_w, badge_h
        end

        local check_badge = create_badge("✓", 14, false)

        local dl_badge, dl_w, dl_h
        local progress_badge, prog_w, prog_h

        if self.entry.cover_type == "book" or self.entry.book ~= nil then
            local book = self.entry.book
            if type(book) == "table" then
                -- Check downloaded status
                local is_downloaded = false
                if self.menu and self.menu.plugin and self.menu.plugin.sync and book.id then
                    is_downloaded = self.menu.plugin.sync:isBookDownloaded(book)
                end
                if is_downloaded then
                    dl_badge, dl_w, dl_h = create_badge("↓", 14, false)
                end

                -- Check read progress status
                local readProgress = book.readProgress
                if type(readProgress) ~= "table" then
                    progress_badge, prog_w, prog_h = create_badge(_("New"), 10, true)
                elseif readProgress.completed then
                    progress_badge, prog_w, prog_h = create_badge(_("Done"), 10, true)
                else
                    local current_page = readProgress.page or 0
                    local total_pages = (book.media and book.media.pagesCount) or 0
                    local progress_text
                    if total_pages > 0 then
                        progress_text = tostring(current_page) .. "/" .. tostring(total_pages)
                    else
                        progress_text = tostring(current_page) .. "p"
                    end
                    progress_badge, prog_w, prog_h = create_badge(progress_text, 10, true)
                end
            end
        end
        
        local orig_paintTo = cover_widget.paintTo
        cover_widget.paintTo = function(this, canvas, x, y)
            orig_paintTo(this, canvas, x, y)
            -- Top-Left: Selected Checkmark
            if self.menu and self.menu.selected_books and self.menu.selected_books[self.entry.cover_id] then
                check_badge:paintTo(canvas, x + Screen:scaleBySize(4), y + Screen:scaleBySize(4))
            end
            -- Top-Right: Downloaded status
            if dl_badge then
                dl_badge:paintTo(canvas, x + cover_w - dl_w - Screen:scaleBySize(4), y + Screen:scaleBySize(4))
            end
            -- Bottom-Right: Progress status
            if progress_badge then
                progress_badge:paintTo(canvas, x + cover_w - prog_w - Screen:scaleBySize(4), y + cover_h - prog_h - Screen:scaleBySize(4))
            end
        end
    end
    
    local current_font_size = 16
    local min_font_size = 12
    local title_face
    
    while current_font_size > min_font_size do
        title_face = Font:getFace("smallinfofont", current_font_size)
        local test_widget = TextBoxWidget:new{
            text = title_text,
            face = title_face,
            width = text_width,
            alignment = "center",
            bold = true,
        }
        
        if test_widget:getSize().h <= GRID_LAYOUT.text_height then
            break
        end
        current_font_size = current_font_size - 1
    end
    
    title_face = Font:getFace("smallinfofont", current_font_size)
    local title_widget = TextBoxWidget:new{
        text = title_text,
        face = title_face,
        width = text_width,
        height = GRID_LAYOUT.text_height,
        alignment = "center",
        bold = true,
    }

    local text_group = VerticalGroup:new{
        align = "center",
        title_widget,
    }
    
    local col_elements = { align = "center" }
    if cover_widget then
        table.insert(col_elements, cover_widget)
        table.insert(col_elements, VerticalSpan:new{ width = GRID_LAYOUT.cover_text_gap })
    end
    table.insert(col_elements, text_group)

    local content_frame = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = GRID_LAYOUT.padding,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width - (GRID_LAYOUT.padding * 2), h = self.height - (GRID_LAYOUT.padding * 2) },
            VerticalGroup:new(col_elements)
        }
    }

    self[1] = content_frame
end

function KomgaGridItem:onTapSelect(arg, ges)
    if self.menu and self.menu.onMenuSelect then
        self.menu:onMenuSelect(self.entry)
        return true
    end
    return false
end

function KomgaGridItem:onHoldSelect(arg, ges)
    if self.menu and self.menu.onMenuHold then
        self.menu:onMenuHold(self.entry)
        return true
    end
    return false
end

local KomgaGridMenu = Menu:extend{
    columns = 3,
    grid_rows = 3,
}

function KomgaGridMenu:_recalculateDimen()
    -- Calculate available dimensions for the list
    local available_width = self.inner_dimen.w
    local available_height = self.inner_dimen.h

    -- Subtract UI overhead
    if not self.is_borderless then available_height = available_height - 2 end
    if not self.no_title and self.title_bar then
        available_height = available_height - self.title_bar.dimen.h
    end
    if self.page_info then
        available_height = available_height - self.page_info:getSize().h
    end

    local rows_per_page = self.grid_rows or 3
    self.item_height = math.floor(available_height / rows_per_page)

    self.perpage = rows_per_page
    
    local logical_per_page = rows_per_page * self.columns
    self.page_num = math.ceil(#self.item_table / logical_per_page)
    if self.page_num > 0 and self.page > self.page_num then
        self.page = self.page_num
    end

    self.item_width = available_width
    self.item_dimen = Geom:new{
        x = 0, y = 0, w = self.item_width, h = self.item_height,
    }
end

function KomgaGridMenu:updateItems(select_number)
    self.layout = {}
    self.item_group:clear()

    local old_dimen = self.dimen and self.dimen:copy()
    self:_recalculateDimen()
    
    if self.page_info then self.page_info:resetLayout() end
    if self.return_button then self.return_button:resetLayout() end

    local logical_per_page = self.perpage * self.columns
    local idx_offset = (self.page - 1) * logical_per_page
    local rows_per_page = self.perpage

    for row = 1, rows_per_page do
        local row_elements = { align = "center" }
        local layout_row = {}
        
        for col = 1, self.columns do
            local entry_idx = idx_offset + (row - 1) * self.columns + col
            local entry = self.item_table[entry_idx]

            if entry then
                local grid_item = KomgaGridItem:new{
                    entry = entry,
                    width = math.floor(self.item_width / self.columns),
                    height = self.item_height,
                    menu = self,
                }
                table.insert(row_elements, grid_item)
                table.insert(layout_row, grid_item)
            else
                -- Insert empty space to maintain alignment
                table.insert(row_elements, HorizontalSpan:new{ width = math.floor(self.item_width / self.columns) })
            end
        end
        
        table.insert(self.item_group, HorizontalGroup:new(row_elements))
        if #layout_row > 0 then
            table.insert(self.layout, layout_row)
        end
    end

    self:updatePageInfo(select_number)

    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        return "ui", refresh_dimen
    end)
end

function KomgaGridMenu:onMenuSelect(item)
    if item and item.callback then
        item.callback(item)
    end
end

function KomgaGridMenu:onMenuHold(item)
    -- Will be overridden or looked up in subclass/metatable
end

return KomgaGridMenu
