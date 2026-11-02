-- Draws the design-system explainers used in the docs:
--   type-scale.svg     every text style of the theme, with its size and leading
--   physical-size.svg  KOReader's default UI text vs Sereno's, at true
--                      physical size, on four devices, with a millimetre ruler
--   margins.svg        content column and margins of each device, to scale
--
-- Usage (from the repository root): luajit tools/specimen.lua [out_dir]
package.path = "sereno.koplugin/?.lua;" .. package.path
local Theme = require("sereno/ui/theme")

local out_dir = arg[1] or "previews"
os.execute('mkdir -p "' .. out_dir .. '"')

local function esc(s) return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function family(font) return font:find("Serif") and "Noto Serif, serif" or "Noto Sans, sans-serif" end
local function weight(font) return font:find("Bold") and "bold" or "normal" end

local function write(name, w, h, body)
    local f = assert(io.open(out_dir .. "/" .. name, "w"))
    f:write(string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">\n<rect width="%d" height="%d" fill="#fff"/>\n',
        w, h, w, h, w, h))
    f:write(table.concat(body, "\n"))
    f:write("\n</svg>\n")
    f:close()
end

local function text(body, x, y, size, str, opts)
    opts = opts or {}
    body[#body + 1] = string.format('<text x="%.1f" y="%.1f" font-family="%s" font-weight="%s" font-size="%.1f" fill="%s" text-anchor="%s">%s</text>',
        x, y, opts.family or "Noto Sans, sans-serif", opts.weight or "normal", size, opts.fill or "#000", opts.anchor or "start", esc(str))
end

local DEVICES = {
    { name = "Kindle (2019)", detail = "6\", 167 dpi", width = 600, height = 800, dpi = 167 },
    { name = "Kobo Clara", detail = "6\", 300 dpi", width = 1072, height = 1448, dpi = 300 },
    { name = "Kindle Paperwhite 5", detail = "6.8\", 300 dpi", width = 1236, height = 1648, dpi = 300 },
    { name = "Kindle Scribe", detail = "10.2\", 300 dpi", width = 1860, height = 2480, dpi = 300 },
}

-- KOReader: Font:getFace(cfont = 24) scaled by Screen:scaleBySize, which uses
-- min(width, height) / 600 and ignores the DPI unless it's overridden.
local function koreaderBodyPt(d)
    local px = math.ceil(24 * math.min(d.width, d.height) / 600)
    return px / d.dpi * 72, px
end

-- 1. type scale ---------------------------------------------------------------
do
    local t = Theme.new(DEVICES[3])
    local styles = { "display", "headline", "title", "body", "label", "caption", "micro" }
    local roles = {
        display = "reserved", headline = "the book you're reading", title = "greeting, counts",
        body = "authors, time left", label = "emphasis", caption = "chips, shelf titles, status", micro = "section heads, tab labels",
    }
    local body, y = {}, 70
    local W = 1700
    local col = 440 -- the labels sit in a left column, samples to the right
    text(body, 40, 40, 26, "Sereno type scale — major third (×1.25) around a 10.5 pt body, Kindle Paperwhite 5 (300 dpi)", { weight = "bold" })
    for _i, name in ipairs(styles) do
        local s = t.type[name]
        local pt = s.size / t.dpi * 72
        y = y + math.max(s.line, 76) + 20
        local base = y - math.floor(s.line * 0.25)
        body[#body + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="#f1f3f5"/>', col, y - s.line, W - col - 40, s.line)
        local sample = (name == "micro") and "CONTINUE READING · ON YOUR SHELF"
            or (s.size > 60 and "The Great Gatsby" or "The Great Gatsby, by F. Scott Fitzgerald")
        text(body, col + 20, base, s.size, sample, { family = family(s.font), weight = weight(s.font) })
        local ly = y - math.max(s.line, 76) + 24
        text(body, 40, ly, 21, string.format("%s · %.1f pt · %d px", name, pt, s.size), { weight = "bold" })
        text(body, 40, ly + 24, 17, string.format("leading %.2f (%d px)", s.leading, s.line), { fill = "#555" })
        text(body, 40, ly + 46, 17, (s.font:gsub("%.ttf", "")) .. " · " .. roles[name], { fill = "#555" })
    end
    write("type-scale.svg", W, y + 60, body)
end

-- 2. physical size ------------------------------------------------------------
do
    local S = 12 -- pixels per millimetre in the drawing
    local body = {}
    local W = 1720
    local y = 50
    text(body, 40, y, 26, "Body text at real size (drawn at 12 px per mm): KOReader's default UI vs Sereno", { weight = "bold" })
    y = y + 34
    text(body, 40, y, 19, "KOReader scales by pixel count, so the same setting prints bigger on bigger screens. Sereno picks a size in points and converts it with the screen's DPI.", { fill = "#555" })
    y = y + 50
    for _i, d in ipairs(DEVICES) do
        local t = Theme.new(d)
        local ko_pt, ko_px = koreaderBodyPt(d)
        text(body, 40, y + 26, 22, d.name, { weight = "bold" })
        text(body, 40, y + 54, 18, d.detail, { fill = "#666" })
        local rows = {
            { "KOReader", ko_pt, string.format("%.1f pt · %d px", ko_pt, ko_px), "#9b2c2c" },
            { "Sereno", t.body_pt, string.format("%.1f pt · %d px", t.body_pt, t.type.body.size), "#1a7f4b" },
        }
        local ry = y
        for _j, r in ipairs(rows) do
            local size = r[2] * 25.4 / 72 * S
            ry = ry + size * 1.35
            text(body, 330, ry, 18, r[1], { weight = "bold", fill = r[4] })
            text(body, 450, ry, size, "Continue reading · 2 h left", {})
            text(body, W - 40, ry, 18, r[3], { anchor = "end", fill = r[4], weight = "bold" })
            ry = ry + 12
        end
        y = math.max(y + 90, ry) + 30
        body[#body + 1] = string.format('<rect x="40" y="%d" width="%d" height="1" fill="#ddd"/>', y - 15, W - 80)
    end
    -- ruler
    y = y + 10
    body[#body + 1] = string.format('<rect x="450" y="%d" width="%d" height="2" fill="#000"/>', y, 80 * S)
    for mm = 0, 80 do
        local h = (mm % 10 == 0) and 18 or ((mm % 5 == 0) and 12 or 7)
        body[#body + 1] = string.format('<rect x="%d" y="%d" width="2" height="%d" fill="#000"/>', 450 + mm * S, y, h)
        if mm % 10 == 0 then text(body, 450 + mm * S, y + 38, 16, mm .. " mm", { anchor = "middle" }) end
    end
    write("physical-size.svg", W, y + 70, body)
end

-- 3. margins, to scale --------------------------------------------------------
do
    local S = 3.2 -- px per mm
    local body = {}
    local x = 40
    local top = 110
    local W = 0
    local tallest = 0
    for _i, d in ipairs(DEVICES) do
        local t = Theme.new(d)
        tallest = math.max(tallest, t.height_mm * S)
    end
    text(body, 40, 40, 26, "Margins and content column, all screens drawn to the same scale", { weight = "bold" })
    text(body, 40, 72, 19, "Margins are at least 6 mm; the column is capped at 110 mm so lines stay short on big screens.", { fill = "#555" })
    for _i, d in ipairs(DEVICES) do
        local t = Theme.new(d)
        local w, h = t.width_mm * S, t.height_mm * S
        local m = t.margin / t.dpi * 25.4 * S
        local y = top + tallest - h
        body[#body + 1] = string.format('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="8" fill="#fff" stroke="#000" stroke-width="2"/>', x, y, w, h)
        body[#body + 1] = string.format('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#e5484d" fill-opacity="0.18"/>', x, y, m, h)
        body[#body + 1] = string.format('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#e5484d" fill-opacity="0.18"/>', x + w - m, y, m, h)
        for c = 0, t.columns - 1 do
            local cx = x + m + c * (t.column_width + t.gutter) / t.dpi * 25.4 * S
            body[#body + 1] = string.format('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#3e63dd" fill-opacity="0.12"/>',
                cx, y + 8, t.column_width / t.dpi * 25.4 * S, h - 16)
        end
        local cy = top + tallest + 34
        text(body, x, cy, 19, d.name, { weight = "bold" })
        text(body, x, cy + 24, 17, string.format("%.0f × %.0f mm screen", t.width_mm, t.height_mm), { fill = "#555" })
        text(body, x, cy + 46, 17, string.format("margin %.1f mm · column %.0f mm", t.margin / t.dpi * 25.4, t.content_width / t.dpi * 25.4), { fill = "#c4232b" })
        text(body, x, cy + 68, 17, string.format("%d columns · body %.1f pt", t.columns, t.body_pt), { fill = "#2a4bb8" })
        x = x + math.max(w, 230) + 50
        W = x
    end
    write("margins.svg", W, top + tallest + 130, body)
end

print("written to " .. out_dir)
