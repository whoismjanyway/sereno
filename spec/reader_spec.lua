-- Reading layout: presets in points and millimetres, converted to KOReader units.
local H = require("helper")
local test, eq, near, truthy = H.it, H.eq, H.near, H.truthy
local ReaderLayout = require("sereno/reader/layout")

local BASIC = { width = 600, height = 800, dpi = 167 }
local PW = { width = 1236, height = 1648, dpi = 300 }
local SCRIBE = { width = 1860, height = 2480, dpi = 300 }

H.describe("reading layout")

test("describes KOReader's defaults physically", function()
    local d = ReaderLayout.describe(PW, ReaderLayout.KOREADER_DEFAULT_VALUES or { font_size = 22, h_margin = 10, t_margin = 10, b_margin = 10, line_spacing = 100 })
    near(d.font_pt, 11, 0.2)
    near(d.side_mm, 1.8, 0.1)
    local s = ReaderLayout.describe(SCRIBE, { font_size = 22, h_margin = 10, t_margin = 10, b_margin = 10, line_spacing = 100 })
    truthy(s.font_pt > 16, "KOReader's text grows with pixel count on a Scribe: " .. s.font_pt)
end)

test("presets give similar physical text and margins on every 6-7\" screen", function()
    local a = ReaderLayout.compute(BASIC, "paperback").physical
    local b = ReaderLayout.compute(PW, "paperback").physical
    near(a.side_mm, 6, 0.5)
    near(b.side_mm, 6, 0.5)
    near(a.font_pt, 10, 0.6)
    near(b.font_pt, 10.5, 0.6)
end)

test("line length stays readable: margins grow on big screens", function()
    for _i, p in ipairs(ReaderLayout.PRESETS) do
        local v = ReaderLayout.compute(SCRIBE, p.id)
        truthy(v.physical.chars_per_line <= p.max_chars + 1, p.id .. ": " .. v.physical.chars_per_line)
        truthy(v.physical.side_mm >= p.side_mm - 0.5, p.id .. " margin")
    end
end)

test("values are valid KOReader settings", function()
    local v = ReaderLayout.compute(BASIC, "compact")
    truthy(v.font_size >= 12 and (v.font_size * 2) % 1 == 0, "half steps from 12")
    eq(v.h_margins[1], v.h_margins[2])
    local d = ReaderLayout.defaultSettings(v)
    eq(d.copt_font_size, v.font_size)
    eq(d.copt_h_page_margins[1], v.h_margins[1])
    eq(d.copt_line_spacing, v.line_spacing)
end)

test("the scale factor follows KOReader's scaleBySize when given", function()
    local s = { width = 1236, height = 1648, dpi = 300, scale_by_size = function(n) return math.ceil(n * 2) end }
    eq(ReaderLayout.scaleFactor(s), 2)
    eq(ReaderLayout.scaleFactor(PW), 1236 / 600)
end)
