local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
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

local LIST_LAYOUT = {
    padding_v = Screen:scaleBySize(2),
    padding_h = Screen:scaleBySize(15),
    cover_text_gap = Screen:scaleBySize(10),
}

local KomgaListItem = InputContainer:extend{
    entry = nil,
    width = nil,
    height = nil,
    menu = nil,
}

function KomgaListItem:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }

    local title_face = Font:getFace("smallinfofont", 20)
    local title_text = self.entry.text or self.entry.title or "Unknown"
    local text_width = self.width - (LIST_LAYOUT.padding_h * 2)
    
    local cover_widget
    if self.entry.cover_id and self.entry.cover_type then
        local DataStorage = require("datastorage")
        local lfs = require("libs/libkoreader-lfs")
        local covers_dir = DataStorage:getDataDir() .. "/komga_covers"
        local cache_key = self.entry.cover_type .. "_" .. self.entry.cover_id
        local local_path = covers_dir .. "/" .. cache_key .. ".jpg"
        
        -- Top/bottom padding
        local v_padding = LIST_LAYOUT.padding_v * 2
        local cover_h = self.height - v_padding - 1 -- -1 for border adjustment
        if cover_h < 10 then cover_h = 10 end
        local cover_w = math.floor(cover_h * 2 / 3)
        
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
                    face = Font:getFace("cfont", math.floor(cover_h / 3)),
                }
            }
        end
        text_width = self.width - (LIST_LAYOUT.padding_h * 2) - cover_w - LIST_LAYOUT.cover_text_gap
    end
    
    local title_widget = TextBoxWidget:new{
        text = title_text,
        face = title_face,
        width = text_width,
        alignment = "left",
        bold = true,
    }

    local text_group = VerticalGroup:new{
        align = "left",
        title_widget,
    }
    
    local row_elements = { align = "center" }
    if cover_widget then
        table.insert(row_elements, cover_widget)
        table.insert(row_elements, HorizontalSpan:new{ width = LIST_LAYOUT.cover_text_gap })
    end
    table.insert(row_elements, text_group)

    local content_frame = FrameContainer:new{
        width = self.width,
        height = self.height - 1,
        padding_top = LIST_LAYOUT.padding_v,
        padding_bottom = LIST_LAYOUT.padding_v,
        padding_left = LIST_LAYOUT.padding_h,
        padding_right = LIST_LAYOUT.padding_h,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width - (LIST_LAYOUT.padding_h * 2), h = self.height - 1 - (LIST_LAYOUT.padding_v * 2) },
            HorizontalGroup:new(row_elements)
        }
    }

    local delimiter = LineWidget:new{
        dimen = Geom:new{ w = self.width, h = 1 },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }

    self[1] = VerticalGroup:new{
        align = "left",
        content_frame,
        delimiter,
    }
end

function KomgaListItem:onTapSelect(arg, ges)
    if self.menu and self.menu.onMenuSelect then
        self.menu:onMenuSelect(self.entry)
        return true
    end
    return false
end

function KomgaListItem:free()
end

local KomgaListMenu = Menu:extend{
    item_height = 110,
}

function KomgaListMenu:_recalculateDimen()
    -- Dynamically determine row height based on whether any item has a cover
    local has_covers = false
    if self.item_table then
        for _, item in ipairs(self.item_table) do
            if item.cover_id then
                has_covers = true
                break
            end
        end
    end
    
    -- Compact height for text-only menus, tall height for cover menus
    local list_height = (self.plugin and self.plugin.settings and self.plugin.settings.list_row_height) or 110
    self.item_height = has_covers and list_height or 70

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

    local rows_per_page = math.floor(available_height / self.item_height)
    if rows_per_page < 1 then rows_per_page = 1 end

    self.perpage = rows_per_page
    self.page_num = math.ceil(#self.item_table / self.perpage)
    if self.page_num > 0 and self.page > self.page_num then
        self.page = self.page_num
    end

    self.item_width = available_width
    self.item_dimen = Geom:new{
        x = 0, y = 0, w = self.item_width, h = self.item_height,
    }
end

function KomgaListMenu:updateItems(select_number)
    self.layout = {}
    self.item_group:clear()

    local old_dimen = self.dimen and self.dimen:copy()
    self:_recalculateDimen()
    
    if self.page_info then self.page_info:resetLayout() end
    if self.return_button then self.return_button:resetLayout() end

    local idx_offset = (self.page - 1) * self.perpage
    local rows_per_page = self.perpage

    -- Add a top delimiter before the first item
    table.insert(self.item_group, LineWidget:new{
        dimen = Geom:new{ w = self.item_width, h = 1 },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    })

    for row = 1, rows_per_page do
        local entry_idx = idx_offset + row
        local entry = self.item_table[entry_idx]

        if entry then
            local list_item = KomgaListItem:new{
                entry = entry,
                width = self.item_width,
                height = self.item_height,
                menu = self,
            }
            table.insert(self.item_group, list_item)
            table.insert(self.layout, { list_item })
        else
            -- Insert empty space to maintain alignment
            table.insert(self.item_group, VerticalSpan:new{ width = self.item_width, height = self.item_height })
        end
    end

    self:updatePageInfo(select_number)

    UIManager:setDirty(self.show_parent, function()
        local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
        return "ui", refresh_dimen
    end)
end

function KomgaListMenu:onMenuSelect(item)
    if item and item.callback then
        item.callback(item)
    end
end

return KomgaListMenu
