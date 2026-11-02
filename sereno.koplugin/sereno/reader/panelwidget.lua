--[[--
KOReader widget for the "Text & page" panel (sereno/reader/panel.lua): a
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
    fonts = nil,      -- { {name, file}... } for the font row
    translate = nil,
    on_action = nil,  -- function(action) -> new values (or nil to close)
}

function PanelWidget:init()
    self.theme = Theme.new{
        width = Screen:getWidth(), height = Screen:getHeight(), dpi = Screen:getDPI(),
        scale_by_size = function(n) return Screen:scaleBySize(n) end,
    }
    self.painter = Painter.new(self.theme)
    local full = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = full } } }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

function PanelWidget:build()
    self.painter:reset()
    self.nodes, self.top = Panel.layout(self.theme, self.values, self.translate, self.fonts)
    -- only the sheet is ours: the book above stays visible and is not repainted
    self.dimen = Geom:new{ x = 0, y = self.top, w = self.theme.width, h = self.theme.height - self.top }
end

function PanelWidget:paintTo(bb, x, y)
    self.painter:paint(bb, self.nodes, x, y)
end

function PanelWidget:onTap(_arg, ges)
    local pos = ges.pos
    if pos.y < self.top then return self:onClose() end
    local n = Painter.hit(self.nodes, pos)
    if n then
        if n.action.type == "close" then return self:onClose() end
        local values = self.on_action and self.on_action(n.action)
        if values then
            self.values = values
            local old_top = self.top
            self:build()
            -- the book re-flowed behind us; repaint it where the sheet shrank
            if self.top > old_top then UIManager:setDirty("all", "ui") end
            UIManager:setDirty(self, "ui")
        end
    end
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
