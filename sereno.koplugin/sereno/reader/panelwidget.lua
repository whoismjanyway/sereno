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
    tab = nil,        -- "quick" (the Aa drop-down) | "themes" | "font" | "layout"
    top = nil,        -- for "quick": where the reader's top bar ends
    translate = nil,
    on_action = nil,  -- function(action) -> new values (or nil to keep them)
    on_tab = nil,     -- function(tab) remembers the last tab
}

function PanelWidget:init()
    self.anchor_top = self.top
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
    opts.top, opts.bottom_limit = self.anchor_top, self.bottom_limit
    self.nodes, self.top, self.bottom = Panel.layout(self.theme, self.values, self.translate, opts)
    self.bottom = self.bottom or self.theme.height
    -- only the sheet is ours: the book around it stays visible and is not repainted
    self.dimen = Geom:new{ x = 0, y = self.top, w = self.theme.width, h = self.bottom - self.top }
end

function PanelWidget:paintTo(bb, x, y)
    self.painter:paint(bb, self.nodes, x, y)
end

function PanelWidget:redraw(old_top, old_bottom)
    self:build()
    -- the book re-flowed behind us; repaint it where the sheet shrank
    if (old_top and self.top > old_top) or (old_bottom and self.bottom < old_bottom) then UIManager:setDirty("all", "ui") end
    UIManager:setDirty(self, "ui")
    if self.on_redraw then self.on_redraw() end
end

-- What the panel handles itself: switching tabs and paging the font list.
function PanelWidget:handle(action)
    if action.type == "tab" then
        self.tab, self.font_list = action.tab, nil
        if self.on_tab and action.tab ~= "quick" then self.on_tab(action.tab) end
        return true
    elseif action.type == "advanced" then
        -- the full panel, at the bottom, on the tab used last
        self.tab, self.font_list, self.anchor_top = self.advanced_tab or "font", nil, nil
        UIManager:setDirty("all", "ui")
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
    local old_top, old_bottom = self.top, self.bottom
    if self:handle(action) then return self:redraw(old_top, old_bottom) end
    local values = self.on_action and self.on_action(action, self)
    if values then self.values = values end
    self:redraw(old_top, old_bottom)
end

--- The value a tap at `px` on a slider stands for, on the slider's steps.
function PanelWidget.seekValue(action, px)
    local f = (px - action.x0) / math.max(1, action.x1 - action.x0)
    f = math.max(0, math.min(1, f))
    local v = action.min + f * (action.max - action.min)
    return action.min + math.floor((v - action.min) / action.step + 0.5) * action.step
end

function PanelWidget:onTap(_arg, ges)
    local pos = ges.pos
    if pos.y < self.top or pos.y >= self.bottom then return self:onClose() end
    local n = Painter.hit(self.nodes, pos)
    if n then
        if n.action.type == "close" then return self:onClose() end
        if n.action.type == "seek" then
            return self:run({ type = "set", key = n.action.key, value = PanelWidget.seekValue(n.action, pos.x) }) or true
        end
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

-- however the panel goes (a tap, Back, the book closing), Sereno hears of it
function PanelWidget:onCloseWidget()
    self.painter:free()
    if self.on_close then self.on_close() end
end

return PanelWidget
