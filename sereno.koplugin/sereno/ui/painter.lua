--[[--
Draws Sereno's positioned nodes with KOReader's widgets and blitbuffer.
Shared by every Sereno screen (home, library, quick controls, the reader's
bars), so they all look and behave the same.

Node kinds:
  text    { text, style, color, max_lines, align }
  cover   { book }                       -- real cover, or a typeset one
  box     { radius, fill, border, bw }
  rule    { color }
  bar     { fraction, inset }            -- progress
  icon    { name, color }                -- KOReader's own icon set
  circle  { fill, border, bw }           -- round buttons
  glyph   { name, color }                -- small vector symbols drawn here:
                                            moon, sun, power, restart, chevron_down,
                                            chevron_up, folder, dots
  slider  { fraction, ticks = {0..1} }   -- track, fill, knob, chapter ticks
  page    -- a miniature page (sereno/reader/panel.lua)
  tap     -- invisible
]]

local Panel = require("sereno/reader/panel")

local Blitbuffer = require("ffi/blitbuffer")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local logger = require("logger")

local Painter = {}
Painter.__index = Painter

Painter.INK = {
    text = Blitbuffer.COLOR_BLACK,
    secondary = Blitbuffer.COLOR_GRAY_4 or Blitbuffer.COLOR_DARK_GRAY,
    hairline = Blitbuffer.COLOR_DARK_GRAY,
    track = Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_GRAY,
    paper = Blitbuffer.COLOR_WHITE,
}
local INK = Painter.INK

--- @tparam table theme sereno/ui/theme; @tparam function cover(file) -> blitbuffer (optional)
function Painter.new(theme, cover)
    local p = setmetatable({ theme = theme, cover = cover, faces = {}, widgets = {} }, Painter)
    -- measure with the real fonts, so layouts match what is drawn
    theme.measure = function(text, style_name, width)
        local w = TextBoxWidget:new{ text = text, face = p:face(style_name), width = width }
        local n = #(w.vertical_string_list or {})
        w:free()
        return math.max(1, n)
    end
    theme.measure_width = function(text, style_name)
        local w = TextWidget:new{ text = text, face = p:face(style_name), padding = 0 }
        local width = w:getSize().w
        w:free()
        return width
    end
    return p
end

function Painter:face(style_name)
    local f = self.faces[style_name]
    if not f then
        local style = self.theme.type[style_name]
        f = Font:getFace(style.font, self.theme:faceSize(style.size))
        self.faces[style_name] = f
    end
    return f
end

--- Forgets cached widgets (call before painting a new list of nodes).
function Painter:reset()
    for _k, w in pairs(self.widgets) do
        if w.free then w:free() end
    end
    self.widgets = {}
end
Painter.free = Painter.reset

-- Text node -> widget, created lazily and cached by node.
function Painter:textWidget(node)
    local w = self.widgets[node]
    if w then return w end
    local style = self.theme.type[node.style]
    local face = self:face(node.style)
    local color = INK[node.color] or INK.text
    local single = (node.max_lines or 1) <= 1
    local text = node.text or ""
    if single then
        w = TextWidget:new{ text = text, face = face, max_width = node.w, fgcolor = color, padding = 0 }
    else
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
        w = TextBoxWidget:new{
            text = text, face = face, width = node.w, height = node.h,
            height_overflow_show_ellipsis = true, alignment = node.align or "left",
            fgcolor = color, bgcolor = node.bg and INK[node.bg] or INK.paper,
            line_height = math.max(0, style.line / face.size - 1),
        }
    end
    self.widgets[node] = w
    return w
end

local function paintTypesetCover(self, bb, x, y, node)
    local t = self.theme
    bb:paintRect(x, y, node.w, node.h, INK.paper)
    bb:paintBorder(x, y, node.w, node.h, t.hairline, INK.text)
    local inner = math.max(2, math.floor(node.w * 0.08))
    bb:paintBorder(x + inner, y + inner, node.w - 2 * inner, node.h - 2 * inner, t.hairline, INK.hairline)
    local title = (node.book and node.book.title) or ""
    if title ~= "" then
        local w = TextBoxWidget:new{
            text = title, face = self:face("caption"), width = node.w - 4 * inner,
            height = node.h - 4 * inner, height_overflow_show_ellipsis = true,
            alignment = "center", fgcolor = INK.text, bgcolor = INK.paper,
        }
        w:paintTo(bb, x + 2 * inner, y + math.floor(node.h * 0.3))
        w:free()
    end
end

function Painter:paintCover(bb, x, y, node)
    local cover_bb = self.cover and node.book and self.cover(node.book.file)
    if not cover_bb then return paintTypesetCover(self, bb, x, y, node) end
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

-- Small symbols KOReader's icon set lacks, drawn from rectangles and circles
-- so they stay crisp on any screen.
function Painter:paintGlyph(bb, x, y, node)
    local w, h = node.w, node.h
    local ink = INK[node.color] or INK.text
    local cx, cy = x + math.floor(w / 2), y + math.floor(h / 2)
    local r = math.floor(math.min(w, h) / 2)
    local stroke = math.max(2, math.floor(r / 6))
    local bg = INK[node.bg] or INK.paper
    local name = node.name
    if name == "moon" then
        bb:paintCircle(cx, cy, math.floor(r * 0.8), ink)
        bb:paintCircle(cx + math.floor(r * 0.38), cy - math.floor(r * 0.3), math.floor(r * 0.66), bg)
    elseif name == "sun" then
        bb:paintCircle(cx, cy, math.floor(r * 0.42), ink)
        local len, gap = math.floor(r * 0.28), math.floor(r * 0.62)
        for _i, d in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
            local rx = cx + d[1] * gap - (d[1] == 0 and math.floor(stroke / 2) or (d[1] < 0 and len or 0))
            local ry = cy + d[2] * gap - (d[2] == 0 and math.floor(stroke / 2) or (d[2] < 0 and len or 0))
            bb:paintRect(rx, ry, d[1] == 0 and stroke or len, d[2] == 0 and stroke or len, ink)
        end
        local o = math.floor(gap * 0.75)
        for _i, d in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
            bb:paintRect(cx + d[1] * o - math.floor(stroke / 2), cy + d[2] * o - math.floor(stroke / 2), stroke, stroke, ink)
        end
    elseif name == "power" or name == "restart" then
        local rr = math.floor(r * 0.72)
        bb:paintCircle(cx, cy, rr, ink, stroke)
        if name == "power" then
            -- a gap at the top with the stem through it
            bb:paintRect(cx - math.floor(rr * 0.45), cy - rr - 1, math.floor(rr * 0.9), math.floor(rr * 0.6), bg)
            bb:paintRect(cx - math.floor(stroke / 2), cy - rr - math.floor(stroke / 2), stroke, rr, ink)
        else
            -- a gap at the top right with an arrow head
            bb:paintRect(cx + 1, cy - rr - 1, rr, math.floor(rr * 0.7), bg)
            local ax, ay = cx + 1, cy - rr
            for k = 0, math.floor(rr * 0.5) do
                bb:paintRect(ax + k, ay - math.floor(rr * 0.5) + k, stroke, (math.floor(rr * 0.5) - k) * 2 + stroke, ink)
            end
        end
    elseif name == "chevron_down" or name == "chevron_up" then
        local half = math.floor(w * 0.35)
        local dir = name == "chevron_down" and 1 or -1
        for k = 0, half do
            local yy = cy + dir * (math.floor(k * 0.45) - math.floor(half * 0.22))
            bb:paintRect(cx - half + k, yy, stroke, stroke, ink)
            bb:paintRect(cx + half - k, yy, stroke, stroke, ink)
        end
    elseif name == "folder" then
        local fh = math.floor(h * 0.62)
        local fy = y + math.floor((h - fh) / 2)
        bb:paintRect(x, fy - math.floor(fh * 0.16), math.floor(w * 0.42), math.floor(fh * 0.2), ink)
        bb:paintBorder(x, fy, w, fh, stroke, ink)
    elseif name == "dots" then
        local d = math.max(2, math.floor(r * 0.18))
        for k = -1, 1 do bb:paintCircle(cx, cy + k * math.floor(r * 0.55), d, ink) end
    end
end

function Painter:paintSlider(bb, x, y, node)
    local t = self.theme
    local track = math.max(2, math.floor(t:mm(0.5)))
    local cy = y + math.floor(node.h / 2)
    local knob = math.floor(math.min(node.h, t:mm(4)) / 2)
    local x0, x1 = x + knob, x + node.w - knob
    local fx = x0 + math.floor((x1 - x0) * math.max(0, math.min(1, node.fraction or 0)))
    bb:paintRect(x0, cy - math.floor(track / 2), x1 - x0, track, INK.hairline)
    for _i, tick in ipairs(node.ticks or {}) do
        local tx = x0 + math.floor((x1 - x0) * tick)
        bb:paintRect(tx, cy - track * 2, math.max(1, t.hairline), track * 4, INK.hairline)
    end
    bb:paintRect(x0, cy - track, fx - x0, track * 2, INK.text)
    bb:paintCircle(fx, cy, knob, INK.paper)
    bb:paintCircle(fx, cy, knob, INK.text, math.max(2, math.floor(knob / 3)))
end

function Painter:paint(bb, nodes, ox, oy)
    ox, oy = ox or 0, oy or 0
    local t = self.theme
    for _i, node in ipairs(nodes) do
        local nx, ny = ox + node.x, oy + node.y
        local kind = node.kind
        if kind == "text" then
            local w = self:textWidget(node)
            local size = w:getSize()
            local dx = 0
            if node.align == "center" then dx = math.floor((node.w - size.w) / 2)
            elseif node.align == "right" then dx = node.w - size.w end
            local dy = (node.max_lines or 1) <= 1 and math.floor((node.h - size.h) / 2) or 0
            w:paintTo(bb, nx + dx, ny + dy)
        elseif kind == "cover" then
            local ok, err = pcall(self.paintCover, self, bb, nx, ny, node)
            if not ok then logger.warn("Sereno: cover drawing failed", err) end
        elseif kind == "box" then
            local r = node.radius or 0
            if node.fill then
                if r > 0 then bb:paintRoundedRect(nx, ny, node.w, node.h, INK[node.fill], r)
                else bb:paintRect(nx, ny, node.w, node.h, INK[node.fill]) end
            end
            if node.border then
                bb:paintBorder(nx, ny, node.w, node.h, node.bw or t.hairline, INK[node.border], r)
            end
        elseif kind == "circle" then
            local r = math.floor(math.min(node.w, node.h) / 2)
            local cx, cy = nx + math.floor(node.w / 2), ny + math.floor(node.h / 2)
            if node.fill then bb:paintCircle(cx, cy, r, INK[node.fill]) end
            if node.border then bb:paintCircle(cx, cy, r, INK[node.border], node.bw or t.hairline) end
        elseif kind == "icon" then
            local w = self.widgets[node]
            if not w then
                -- inactive items are dimmed rather than drawn in a lighter grey
                w = IconWidget:new{ icon = node.name, width = node.w, height = node.h, dim = node.color == "secondary",
                    invert = node.invert }
                self.widgets[node] = w
            end
            w:paintTo(bb, nx, ny)
        elseif kind == "glyph" then
            self:paintGlyph(bb, nx, ny, node)
        elseif kind == "rule" then
            bb:paintRect(nx, ny, node.w, node.h, INK[node.color] or INK.text)
        elseif kind == "bar" then
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
        elseif kind == "slider" then
            self:paintSlider(bb, nx, ny, node)
        elseif kind == "page" then
            local moved = setmetatable({ x = nx, y = ny }, { __index = node })
            Panel.paintPage(moved, function(rx, ry, rw, rh, ink) bb:paintRect(rx, ry, rw, rh, INK[ink] or INK.text) end, t.hairline)
        end
    end
end

--- The topmost tap node under a point, or nil.
function Painter.hit(nodes, pos)
    for i = #nodes, 1, -1 do
        local n = nodes[i]
        if n.kind == "tap" and pos.x >= n.x and pos.x < n.x + n.w and pos.y >= n.y and pos.y < n.y + n.h then
            return n
        end
    end
end

return Painter
