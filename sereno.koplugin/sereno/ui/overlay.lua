--[[--
A window over the current screen that paints Sereno nodes and routes taps:
the quick controls sheet and the reader's bars. `build()` returns the
nodes and the regions that belong to the overlay; a tap anywhere else
closes it, so the page or screen underneath is one tap away.
]]

local Painter = require("sereno/ui/painter")
local Theme = require("sereno/ui/theme")

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local Overlay = InputContainer:extend{
    name = "sereno_overlay",
    build_nodes = nil, -- function(theme) -> nodes, regions = { {x, y, w, h}... }
    on_action = nil,   -- function(action, ges, overlay) -> true to rebuild
    on_close = nil,
    close_on_swipe = nil, -- "north" | "south": a swipe that way closes it
}

function Overlay:init()
    self.theme = Theme.new{
        width = Screen:getWidth(), height = Screen:getHeight(), dpi = Screen:getDPI(),
        scale_by_size = function(n) return Screen:scaleBySize(n) end,
    }
    self.painter = Painter.new(self.theme, self.cover)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.theme.width, h = self.theme.height }
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:rebuild()
end

function Overlay:rebuild()
    self.painter:reset()
    self.nodes, self.regions = self.build_nodes(self.theme)
end

function Overlay:paintTo(bb, x, y)
    self.painter:paint(bb, self.nodes, x, y)
end

local function inside(regions, pos)
    for _i, r in ipairs(regions or {}) do
        if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h then return true end
    end
    return false
end

function Overlay:refresh()
    for _i, r in ipairs(self.regions or {}) do
        UIManager:setDirty(self, "ui", Geom:new{ x = r.x, y = r.y, w = r.w, h = r.h })
    end
end

function Overlay:onTap(_arg, ges)
    local n = Painter.hit(self.nodes, ges.pos)
    if n then
        if n.action.type == "close" then return self:onClose() end
        local keep = self.on_action and self.on_action(n.action, ges, self)
        if keep and self.nodes then
            self:rebuild()
            self:refresh()
        end
        return true
    end
    if not inside(self.regions, ges.pos) then return self:onClose() end
    return true
end

function Overlay:onSwipe(_arg, ges)
    if self.close_on_swipe and ges.direction == self.close_on_swipe then return self:onClose() end
    return true
end

function Overlay:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    -- what was under the overlay shows again in full
    UIManager:setDirty("all", "ui")
    return true
end

function Overlay:onCloseWidget()
    self.painter:free()
end

return Overlay
