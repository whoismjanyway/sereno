--[[--
KOReader widget for the "Text & page" panel (sereno/reader/panel.lua): a
bottom sheet over the book. Taps change one thing at a time and the book
re-flows behind the sheet, so the effect is visible at once; a tap above
the sheet, or Back, closes it.
]]

local Panel = require("sereno/reader/panel")
local Theme = require("sereno/ui/theme")

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local INK = {
    text = Blitbuffer.COLOR_BLACK,
    secondary = Blitbuffer.COLOR_GRAY_4 or Blitbuffer.COLOR_DARK_GRAY,
    hairline = Blitbuffer.COLOR_DARK_GRAY,
    paper = Blitbuffer.COLOR_WHITE,
}

local PanelWidget = InputContainer:extend{
    name = "sereno_page_panel",
    values = nil,     -- sereno/reader/layout.compute() for the current spec
    translate = nil,
    on_action = nil,  -- function(action) -> new values (or nil to close)
}

function PanelWidget:init()
    self.theme = Theme.new{
        width = Screen:getWidth(), height = Screen:getHeight(), dpi = Screen:getDPI(),
        scale_by_size = function(n) return Screen:scaleBySize(n) end,
    }
    self.faces, self.widgets = {}, {}
    self.theme.measure_width = function(text, style_name)
        local w = TextWidget:new{ text = text, face = self:face(style_name), padding = 0 }
        local width = w:getSize().w
        w:free()
        return width
    end
    local full = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = full } } }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

function PanelWidget:face(style_name)
    local f = self.faces[style_name]
    if not f then
        local style = self.theme.type[style_name]
        f = Font:getFace(style.font, self.theme:faceSize(style.size))
        self.faces[style_name] = f
    end
    return f
end

function PanelWidget:build()
    self:freeWidgets()
    self.nodes, self.top = Panel.layout(self.theme, self.values, self.translate)
    -- only the sheet is ours: the book above stays visible and is not repainted
    self.dimen = Geom:new{ x = 0, y = self.top, w = self.theme.width, h = self.theme.height - self.top }
end

function PanelWidget:freeWidgets()
    for _i, w in pairs(self.widgets or {}) do
        if w.free then w:free() end
    end
    self.widgets = {}
end

function PanelWidget:paintTo(bb, x, y)
    local hairline = self.theme.hairline
    local function rect(rx, ry, rw, rh, ink)
        bb:paintRect(x + rx, y + ry, rw, rh, INK[ink] or INK.text)
    end
    for i, node in ipairs(self.nodes) do
        local nx, ny = x + node.x, y + node.y
        if node.kind == "box" then
            local r = node.radius or 0
            if node.fill then
                if r > 0 then bb:paintRoundedRect(nx, ny, node.w, node.h, INK[node.fill], r)
                else bb:paintRect(nx, ny, node.w, node.h, INK[node.fill]) end
            end
            if node.border then bb:paintBorder(nx, ny, node.w, node.h, node.bw or hairline, INK[node.border], r) end
        elseif node.kind == "rule" then
            bb:paintRect(nx, ny, node.w, node.h, INK[node.color] or INK.text)
        elseif node.kind == "page" then
            Panel.paintPage(node, rect, hairline)
        elseif node.kind == "text" then
            local w = self.widgets[i]
            if not w then
                w = TextWidget:new{ text = node.text, face = self:face(node.style), max_width = node.w,
                    fgcolor = INK[node.color] or INK.text, padding = 0 }
                self.widgets[i] = w
            end
            local size = w:getSize()
            local dx = 0
            if node.align == "center" then dx = math.floor((node.w - size.w) / 2)
            elseif node.align == "right" then dx = node.w - size.w end
            w:paintTo(bb, nx + dx, ny + math.floor((node.h - size.h) / 2))
        end
    end
end

function PanelWidget:onTap(_arg, ges)
    local pos = ges.pos
    if pos.y < self.top then return self:onClose() end
    for i = #self.nodes, 1, -1 do
        local n = self.nodes[i]
        if n.kind == "tap" and pos.x >= n.x and pos.x < n.x + n.w and pos.y >= n.y and pos.y < n.y + n.h then
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
            return true
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
    self:freeWidgets()
end

return PanelWidget
