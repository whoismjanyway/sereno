--[[--
Sereno's full-screen shell: the home screen and the Library, Reading,
Collections and Search tabs, all behind the same tab bar, so you never
fall back into KOReader's file browser while moving around.

Gestures:
  tap           books open, folders and collections go in, tabs switch
  hold          a book's pages & readability
  swipe ← / →   next / previous page of a grid
  swipe ↓ from the top, or a tap on the clock line: quick controls

The clock line repaints once a minute through the refresh coordinator.
]]

local Browse = require("sereno/shell/browse")
local Context = require("sereno/home/context")
local Layout = require("sereno/home/layout")
local Painter = require("sereno/ui/painter")
local Presenter = require("sereno/home/presenter")
local ShellLayout = require("sereno/shell/layout")
local Theme = require("sereno/ui/theme")

local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local HomeScreen = InputContainer:extend{
    name = "sereno_home",
    covers_fullscreen = true, -- lets UIManager skip painting what's below
    tab = "home",
    -- injected by main.lua
    sources = nil,   -- { history, book_info, new_books, metrics, cover, stats,
                     --   home_dir, list_dir, collections, collection, search }
    options = nil,   -- { page_method, wpm, translate, thousands }
    refresh = nil,   -- sereno/eink/refresh coordinator
    on_action = nil, -- function(action, home) for what the shell doesn't handle itself
    on_hold = nil,   -- function(file) long-press on a book
    on_controls = nil, -- function() open the quick controls
}

function HomeScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.theme = Theme.new{
        width = self.dimen.w, height = self.dimen.h, dpi = Screen:getDPI(),
        scale_by_size = function(n) return Screen:scaleBySize(n) end,
    }
    self.painter = Painter.new(self.theme, self.sources and self.sources.cover)
    self.states = { library = {}, history = {}, collections = {}, search = {} }
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
            Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
            Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

--- Kept for callers that measure with the home screen's fonts.
function HomeScreen:face(style_name) return self.painter:face(style_name) end

function HomeScreen:statusCopy()
    local opts = self.options or {}
    local status = {}
    local ok_dt, datetime = pcall(require, "datetime")
    if ok_dt and datetime.secondsToHour then
        status.time = datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
    else
        status.time = os.date("%H:%M")
    end
    if Device:hasBattery() then
        local powerd = Device:getPowerDevice()
        status.battery = powerd:getCapacity()
        status.charging = powerd:isCharging()
    end
    return status, opts
end

function HomeScreen:build()
    self.painter:reset()
    local status, opts = self:statusCopy()
    local _ = opts.translate or function(s) return s end
    if self.tab == "home" then
        self.model = Context.build(self.sources, {
            page_method = opts.page_method, wpm = opts.wpm,
            shelf_size = self.theme.columns >= 8 and 10 or 8,
        })
        local copy = Presenter.present(self.model, _, status, opts.thousands)
        self.nodes = Layout.home(self.theme, self.model, copy)
        self.paging = nil
    else
        local state = self.states[self.tab]
        self.browse = Browse.build(self.tab, state, self.sources)
        local copy = Presenter.browse(self.browse, _, status, opts.thousands)
        self.nodes, self.paging = ShellLayout.browse(self.theme, self.browse, copy, state.page)
        state.page = self.paging.page
    end
    self.status_index = nil
    self.status_bottom = 0
    for i, node in ipairs(self.nodes) do
        if node.id == "status_right" then
            self.status_index = i
            self.status_bottom = node.y + node.h
        end
    end
end

--- Shows a tab ("home", "library", "history", "collections", "search").
function HomeScreen:showTab(tab)
    self.tab = tab
    self:build()
    UIManager:setDirty(self, "ui")
end

function HomeScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Painter.INK.paper)
    self.painter:paint(bb, self.nodes, x, y)
end

-- What the shell handles itself; returns true when done.
function HomeScreen:handle(action)
    local state = self.states[self.tab]
    if action.type == "nav" then
        if action.target == self.tab and self.tab ~= "home" then
            -- tapping the current tab goes back to its top level
            self.states[self.tab] = { sort = state.sort }
        end
        self:showTab(action.target)
        return true
    elseif action.type == "folder" then
        self.states.library.path, self.states.library.page = action.path, 1
        self:showTab("library")
        return true
    elseif action.type == "collection" then
        state.collection, state.page = action.name, 1
        self:showTab("collections")
        return true
    elseif action.type == "collections_root" then
        state.collection, state.page = nil, 1
        self:showTab("collections")
        return true
    elseif action.type == "page" then
        state.page = (state.page or 1) + action.delta
        self:showTab(self.tab)
        return true
    elseif action.type == "sort" then
        state.sort, state.page = Browse.nextSort(state.sort or "title"), 1
        self:showTab(self.tab)
        return true
    end
    return false
end

--- Search tab: shows the results for `query`.
function HomeScreen:setQuery(query)
    self.states.search.query, self.states.search.page = query, 1
    self:showTab("search")
end

function HomeScreen:onTap(_arg, ges)
    local n = Painter.hit(self.nodes, ges.pos)
    if n then
        if not self:handle(n.action) and self.on_action then self.on_action(n.action, self) end
        return true
    end
    -- the clock line at the top opens the quick controls
    if ges.pos.y <= self.status_bottom + self.theme:space(2) and self.on_controls then
        self.on_controls()
    end
    return true
end

function HomeScreen:onHold(_arg, ges)
    local n = Painter.hit(self.nodes, ges.pos)
    if n and n.action and n.action.type == "open" and self.on_hold then self.on_hold(n.action.file, self) end
    return true
end

function HomeScreen:onSwipe(_arg, ges)
    local dir = ges.direction
    if dir == "south" and ges.pos.y < self.theme.height * 0.15 then
        if self.on_controls then self.on_controls() end
        return true
    end
    if self.paging and self.paging.pages > 1 then
        if dir == "west" and self.paging.page < self.paging.pages then return self:handle({ type = "page", delta = 1 }) end
        if dir == "east" and self.paging.page > 1 then return self:handle({ type = "page", delta = -1 }) end
    end
    return true
end

function HomeScreen:onClose()
    UIManager:close(self)
    return true
end

--- Rebuilds with fresh data (after a book was counted, or on resume).
function HomeScreen:update()
    self:build()
    UIManager:setDirty(self, "ui")
end

-- Clock line: registered with the shared coordinator as a periodic widget.
function HomeScreen:onShow()
    if self.refresh and self.status_index then
        self.refresh:register(self, {
            window = self, policy = "periodic", period = 60,
            region = function()
                local n = self.status_index and self.nodes[self.status_index]
                return n and { x = n.x, y = n.y, w = n.w, h = n.h } or { x = 0, y = 0, w = 1, h = 1 }
            end,
            visible = function() return UIManager:getTopmostVisibleWidget() == self end,
            update = function()
                local status = self:statusCopy()
                local n = self.status_index and self.nodes[self.status_index]
                if n then
                    local text = status.time or ""
                    if status.battery then
                        text = text .. " · " .. status.battery .. "%" .. (status.charging and " +" or "")
                    end
                    n.text = text
                    local w = self.painter.widgets[n]
                    if w then
                        w:free()
                        self.painter.widgets[n] = nil
                    end
                end
            end,
        })
    end
    UIManager:setDirty(self, "flashui")
end

function HomeScreen:onCloseWidget()
    if self.refresh then self.refresh:unregister(self) end
    self.painter:free()
end

return HomeScreen
