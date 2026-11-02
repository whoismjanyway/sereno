--[[--
The home screen widget: draws the nodes from sereno/home/layout with
KOReader's text shaping, handles taps and holds, and keeps its clock line
up to date through the refresh coordinator (one partial refresh a minute,
paused while the device sleeps or the screen is covered).
]]

local Context = require("sereno/home/context")
local Layout = require("sereno/home/layout")
local Presenter = require("sereno/home/presenter")
local Theme = require("sereno/ui/theme")

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Screen = Device.screen

local INK = {
    text = Blitbuffer.COLOR_BLACK,
    secondary = Blitbuffer.COLOR_GRAY_4 or Blitbuffer.COLOR_DARK_GRAY,
    hairline = Blitbuffer.COLOR_DARK_GRAY,
    track = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY,
    paper = Blitbuffer.COLOR_WHITE,
}

local HomeScreen = InputContainer:extend{
    name = "sereno_home",
    covers_fullscreen = true, -- lets UIManager skip painting what's below
    -- injected by main.lua
    sources = nil,   -- { history, book_info, new_books, metrics, cover }
    options = nil,   -- { page_method, wpm, translate, thousands }
    refresh = nil,   -- sereno/eink/refresh coordinator
    on_action = nil, -- function(action) called for taps on books and nav items
    on_hold = nil,   -- function(file) long-press on a book
}

function HomeScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.theme = Theme.new{
        width = self.dimen.w, height = self.dimen.h, dpi = Screen:getDPI(),
        scale_by_size = function(n) return Screen:scaleBySize(n) end,
    }
    self.faces = {}
    self.widgets = {}
    -- measure with the real fonts, so the layout's boxes match what is drawn
    self.theme.measure = function(text, style_name, width)
        local w = TextBoxWidget:new{ text = text, face = self:face(style_name), width = width }
        local n = #(w.vertical_string_list or {})
        w:free()
        return math.max(1, n)
    end
    self.theme.measure_width = function(text, style_name)
        local w = TextWidget:new{ text = text, face = self:face(style_name), padding = 0 }
        local width = w:getSize().w
        w:free()
        return width
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
            Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

function HomeScreen:face(style_name)
    local f = self.faces[style_name]
    if not f then
        local style = self.theme.type[style_name]
        f = Font:getFace(style.font, self.theme:faceSize(style.size))
        self.faces[style_name] = f
    end
    return f
end

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
    self:freeWidgets()
    local status, opts = self:statusCopy()
    self.model = Context.build(self.sources, {
        page_method = opts.page_method, wpm = opts.wpm,
        shelf_size = self.theme.columns >= 8 and 10 or 8,
    })
    local copy = Presenter.present(self.model, opts.translate or function(s) return s end, status, opts.thousands)
    self.nodes = Layout.home(self.theme, self.model, copy)
    self.widgets = {}
    for i, node in ipairs(self.nodes) do
        if node.id == "status_right" then self.status_index = i end
    end
end

function HomeScreen:freeWidgets()
    for _i, w in pairs(self.widgets or {}) do
        if w.free then w:free() end
    end
    self.widgets = {}
end

-- Text node -> widget, created lazily and cached until the next build.
function HomeScreen:textWidget(i, node)
    local w = self.widgets[i]
    if w then return w end
    local style = self.theme.type[node.style]
    local face = self:face(node.style)
    local color = INK[node.color] or INK.text
    local single = (node.max_lines or 1) <= 1
    local text = node.text
    if not single then
        -- TextBoxWidget breaks a word that is wider than the box in the middle
        -- ("Frankenstei / n"); shorten such a word with an ellipsis instead
        text = text:gsub("%S+", function(word)
            if self.theme.measure_width(word, node.style) <= node.w then return word end
            local cut = word
            repeat
                cut = cut:gsub("[%z\1-\127\192-\255][\128-\191]*$", "")
            until cut == "" or self.theme.measure_width(cut .. "…", node.style) <= node.w
            return cut .. "…"
        end)
    end
    if single then
        w = TextWidget:new{ text = node.text, face = face, max_width = node.w, fgcolor = color, padding = 0 }
    else
        w = TextBoxWidget:new{
            text = text, face = face, width = node.w, height = node.h,
            height_overflow_show_ellipsis = true, alignment = node.align or "left",
            fgcolor = color, bgcolor = INK.paper,
            line_height = math.max(0, style.line / face.size - 1),
        }
    end
    self.widgets[i] = w
    return w
end

local function paintTypesetCover(self, bb, x, y, node)
    local t = self.theme
    bb:paintRect(x, y, node.w, node.h, INK.paper)
    bb:paintBorder(x, y, node.w, node.h, t.hairline, INK.text)
    local book = node.book or {}
    local inset = math.floor(node.w * 0.1)
    local title_px = math.max(8, math.floor(node.w / 7))
    local title_face = Font:getFace(Theme.FONTS.serif, t:faceSize(title_px))
    local title = TextBoxWidget:new{
        text = Presenter.shortTitle(book.title or ""), face = title_face, width = node.w - 2 * inset,
        height = math.floor(node.h * 0.5), height_overflow_show_ellipsis = true, alignment = "center",
        fgcolor = INK.text, bgcolor = INK.paper,
    }
    local ty = y + math.floor(node.h * 0.2)
    title:paintTo(bb, x + inset, ty)
    local rule_y = ty + title:getSize().h + math.floor(title_px * 0.6)
    title:free()
    bb:paintRect(x + math.floor(node.w * 0.4), rule_y, math.floor(node.w * 0.2), t.hairline, INK.text)
    local author = type(book.authors) == "table" and book.authors[1] or book.authors
    if author and author ~= "" then
        local a_face = Font:getFace(Theme.FONTS.sans, t:faceSize(math.max(6, math.floor(node.w / 13))))
        local a = TextWidget:new{ text = author:upper(), face = a_face, max_width = node.w - 2 * inset, fgcolor = INK.text, padding = 0 }
        local size = a:getSize()
        a:paintTo(bb, x + math.floor((node.w - size.w) / 2), y + node.h - math.floor(node.h * 0.12) - size.h)
        a:free()
    end
end

function HomeScreen:paintCover(bb, x, y, node)
    local cover_bb = self.sources.cover and node.book and self.sources.cover(node.book.file)
    if not cover_bb then
        return paintTypesetCover(self, bb, x, y, node)
    end
    local img = ImageWidget:new{
        image = cover_bb, image_disposable = false,
        width = node.w, height = node.h, scale_factor = 0,
    }
    local size = img:getSize()
    local ix = x + math.floor((node.w - size.w) / 2)
    local iy = y + node.h - size.h -- covers sit on a common baseline, like books on a shelf
    img:paintTo(bb, ix, iy)
    bb:paintBorder(ix, iy, size.w, size.h, self.theme.hairline, INK.text)
    img:free()
end

function HomeScreen:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, INK.paper)
    for i, node in ipairs(self.nodes) do
        local nx, ny = x + node.x, y + node.y
        if node.kind == "text" then
            local w = self:textWidget(i, node)
            local size = w:getSize()
            local dx = 0
            if node.align == "center" then dx = math.floor((node.w - size.w) / 2)
            elseif node.align == "right" then dx = node.w - size.w end
            local dy = (node.max_lines or 1) <= 1 and math.floor((node.h - size.h) / 2) or 0
            w:paintTo(bb, nx + dx, ny + dy)
        elseif node.kind == "cover" then
            local ok, err = pcall(self.paintCover, self, bb, nx, ny, node)
            if not ok then logger.warn("Sereno: cover drawing failed", err) end
        elseif node.kind == "box" then
            local r = node.radius or 0
            if node.fill then
                if r > 0 then bb:paintRoundedRect(nx, ny, node.w, node.h, INK[node.fill], r)
                else bb:paintRect(nx, ny, node.w, node.h, INK[node.fill]) end
            end
            if node.border then
                bb:paintBorder(nx, ny, node.w, node.h, node.bw or self.theme.hairline, INK[node.border], r)
            end
        elseif node.kind == "icon" then
            local w = self.widgets[i]
            if not w then
                -- inactive tabs are dimmed rather than drawn in a lighter grey
                w = IconWidget:new{ icon = node.name, width = node.w, height = node.h, dim = node.color ~= "text" }
                self.widgets[i] = w
            end
            w:paintTo(bb, nx, ny)
        elseif node.kind == "rule" then
            bb:paintRect(nx, ny, node.w, node.h, INK[node.color] or INK.text)
        elseif node.kind == "bar" then
            local r = math.floor(node.h / 2)
            local filled = math.floor(node.w * math.min(1, node.fraction or 0))
            if node.inset then
                -- drawn over a cover: white track with an outline
                bb:paintRoundedRect(nx, ny, node.w, node.h, INK.paper, r)
                bb:paintBorder(nx, ny, node.w, node.h, 1, INK.text, r)
            else
                bb:paintRoundedRect(nx, ny, node.w, node.h, INK.track, r)
            end
            if filled > 0 then bb:paintRoundedRect(nx, ny, filled, node.h, INK.text, r) end
        end
    end
end

local function hit(nodes, pos)
    for i = #nodes, 1, -1 do
        local n = nodes[i]
        if n.kind == "tap" and pos.x >= n.x and pos.x < n.x + n.w and pos.y >= n.y and pos.y < n.y + n.h then
            return n
        end
    end
end

function HomeScreen:onTap(_arg, ges)
    local n = hit(self.nodes, ges.pos)
    if n and self.on_action then self.on_action(n.action, self) end
    return true
end

function HomeScreen:onHold(_arg, ges)
    local n = hit(self.nodes, ges.pos)
    if n and n.action and n.action.type == "open" and self.on_hold then self.on_hold(n.action.file, self) end
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
        local node = self.nodes[self.status_index]
        self.refresh:register(self, {
            window = self, policy = "periodic", period = 60,
            region = function()
                local n = self.nodes[self.status_index]
                return n and { x = n.x, y = n.y, w = n.w, h = n.h } or { x = node.x, y = node.y, w = node.w, h = node.h }
            end,
            visible = function() return UIManager:getTopmostVisibleWidget() == self end,
            update = function()
                local status = self:statusCopy()
                local n = self.nodes[self.status_index]
                if n then
                    local text = status.time or ""
                    if status.battery then
                        text = text .. " · " .. status.battery .. "%" .. (status.charging and " +" or "")
                    end
                    n.text = text
                    if self.widgets[self.status_index] then
                        self.widgets[self.status_index]:free()
                        self.widgets[self.status_index] = nil
                    end
                end
            end,
        })
    end
    UIManager:setDirty(self, "flashui")
end

function HomeScreen:onCloseWidget()
    if self.refresh then self.refresh:unregister(self) end
    self:freeWidgets()
end

return HomeScreen
