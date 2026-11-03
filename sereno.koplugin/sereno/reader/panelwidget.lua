--[[--
KOReader widget for the "Text" panel (sereno/reader/panel.lua): a
bottom sheet over the book. Taps change one thing at a time and the book
re-flows behind the sheet, so the effect is visible at once; a tap above
the sheet, or Back, closes it.
]]

local Panel = require("sereno/reader/panel")
local Painter = require("sereno/ui/painter")
local Theme = require("sereno/ui/theme")

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local PanelWidget = InputContainer:extend{
    name = "sereno_page_panel",
    values = nil,     -- sereno/reader/layout.compute() for the current spec
    opts = nil,       -- function() -> { fonts, font_file, themes } (Panel.layout's opts)
    tab = nil,        -- "themes" | "font" | "layout"
    translate = nil,
    on_action = nil,  -- function(action) -> new values (or nil to keep them)
    on_tab = nil,     -- function(tab) remembers the last tab
}

function PanelWidget:init()
    self.theme = Theme.new{
        width = Screen:getWidth(), height = Screen:getHeight(), dpi = Screen:getDPI(),
        scale_by_size = function(n) return Screen:scaleBySize(n) end,
    }
    self.painter = Painter.new(self.theme)
    local full = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = full } },
            Hold = { GestureRange:new{ ges = "hold", range = full } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

function PanelWidget:build()
    self.painter:reset()
    local opts = self.opts and self.opts() or {}
    opts.tab, opts.font_list, opts.font_page = self.tab or "font", self.font_list, self.font_page
    self.nodes, self.top = Panel.layout(self.theme, self.values, self.translate, opts)
    -- only the sheet is ours: the book above stays visible and is not repainted
    self.dimen = Geom:new{ x = 0, y = self.top, w = self.theme.width, h = self.theme.height - self.top }
end

function PanelWidget:paintTo(bb, x, y)
    self.painter:paint(bb, self.nodes, x, y)
end

function PanelWidget:redraw(old_top)
    self:build()
    -- the book re-flowed behind us; repaint it where the sheet shrank
    if old_top and self.top > old_top then UIManager:setDirty("all", "ui") end
    UIManager:setDirty(self, "ui")
end

-- What the panel handles itself: switching tabs and paging the font list.
function PanelWidget:handle(action)
    if action.type == "tab" then
        self.tab, self.font_list = action.tab, nil
        if self.on_tab then self.on_tab(action.tab) end
        return true
    elseif action.type == "font_list" then
        self.font_list, self.font_page = true, 1
        return true
    elseif action.type == "font_page" then
        self.font_page = (self.font_page or 1) + action.delta
        return true
    end
    return false
end

function PanelWidget:run(action)
    local old_top = self.top
    if self:handle(action) then return self:redraw(old_top) end
    local values = self.on_action and self.on_action(action, self)
    if values then self.values = values end
    self:redraw(old_top)
end

function PanelWidget:onTap(_arg, ges)
    local pos = ges.pos
    if pos.y < self.top then return self:onClose() end
    local n = Painter.hit(self.nodes, pos)
    if n then
        if n.action.type == "close" then return self:onClose() end
        self:run(n.action)
    end
    return true
end

function PanelWidget:onHold(_arg, ges)
    local n = Painter.hit(self.nodes, ges.pos)
    if n and n.hold_action then self:run(n.hold_action) end
    return true
end

function PanelWidget:onClose()
    UIManager:close(self)
    UIManager:setDirty("all", "ui")
    return true
end

function PanelWidget:onCloseWidget()
    self.painter:free()
end

return PanelWidget
