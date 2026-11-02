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
    local a = ReaderLayout.compute(BASIC, "normal").physical
    local b = ReaderLayout.compute(PW, "normal").physical
    -- normal margins: 8 mm, like the Kindle's own default and a paperback's outer margin
    near(a.side_mm, 8, 0.6)
    near(b.side_mm, 8, 0.6)
    truthy(a.chars_per_line >= 38 and a.chars_per_line <= 60, "6\": " .. a.chars_per_line .. " characters a line")
    truthy(b.chars_per_line >= 40 and b.chars_per_line <= 60, "6.8\": " .. b.chars_per_line .. " characters a line")
    near(a.font_pt, 10, 0.6)
    near(b.font_pt, 10.5, 0.6)
end)

test("line length stays readable: margins grow on big screens", function()
    for _i, p in ipairs(ReaderLayout.PAGES) do
        local v = ReaderLayout.compute(SCRIBE, p.id)
        local m = ReaderLayout.margins(p.margins)
        local cap = m.max_chars
        truthy(v.physical.chars_per_line <= cap + 1, p.id .. ": " .. v.physical.chars_per_line)
        truthy(v.physical.side_mm >= m.side_mm - 0.5, p.id .. " margin")
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

test("margins are never a hair wide: at least 5 mm on every screen and preset", function()
    for _i, screen in ipairs({ BASIC, PW, SCRIBE }) do
        for _j, p in ipairs(ReaderLayout.PAGES) do
            local ph = ReaderLayout.compute(screen, p.id).physical
            truthy(ph.side_mm >= 4.9, p.id .. " side " .. ph.side_mm)
            truthy(ph.top_mm >= 4.9, p.id .. " top " .. ph.top_mm)
        end
    end
end)

test("line spacing gives a book-like leading", function()
    local ph = ReaderLayout.compute(PW, "normal").physical
    near(ph.line_em, 1.5, 0.05)
end)

test("three pages, a size and a font: and earlier settings still read", function()
    local s = ReaderLayout.spec("normal")
    local a = ReaderLayout.compute(PW, s)
    local roomy = ReaderLayout.compute(PW, ReaderLayout.with(s, "page", "roomy"))
    eq(a.font_size, roomy.font_size)
    truthy(roomy.h_margins[1] > a.h_margins[1] and roomy.line_spacing > a.line_spacing, "roomy: wider margins, looser lines")
    local compact = ReaderLayout.compute(PW, ReaderLayout.with(s, "page", "compact"))
    truthy(compact.h_margins[1] < a.h_margins[1] and compact.line_spacing < a.line_spacing, "compact")
    local bigger = ReaderLayout.compute(PW, ReaderLayout.with(s, "pt", s.pt + 1))
    truthy(bigger.font_size > a.font_size, "bigger text")
    eq(ReaderLayout.with(s, "pt", 99).pt, ReaderLayout.MAX_DELTA)
    eq(ReaderLayout.compute(PW, ReaderLayout.with(s, "font", "Literata")).font, "Literata")
    -- 0.2's presets and axes
    eq(ReaderLayout.spec("paperback").page, "normal")
    eq(ReaderLayout.spec("airy").page, "roomy")
    eq(ReaderLayout.spec("large").pt, 4)
    eq(ReaderLayout.spec({ spacing = "tight", margins = "narrow", pt = 1 }).page, "compact")
end)

test("book typography maps to KOReader's style tweaks", function()
    local on, off = ReaderLayout.tweaks(ReaderLayout.spec("normal"))
    truthy(H.contains(on, "text_align_most_justify") and H.contains(off, "text_align_most_left"), "justified")
    truthy(H.contains(on, "paragraph_indent") and H.contains(on, "paragraph_no_whitespace"), "book paragraphs")
    local left = ReaderLayout.with(ReaderLayout.spec("normal"), "align", "left")
    left = ReaderLayout.with(left, "book_style", false)
    on, off = ReaderLayout.tweaks(left)
    truthy(H.contains(on, "text_align_most_left") and H.contains(off, "paragraph_indent"), "left, publisher paragraphs")
    -- every id exists in KOReader, when its source is around
    local dir = os.getenv("KOREADER_DIR")
    local f = dir and io.open(dir .. "/frontend/ui/data/css_tweaks.lua")
    if f then
        local src = f:read("*a"); f:close()
        for _i, id in ipairs(ReaderLayout.allTweaks()) do
            truthy(src:find('id = "' .. id .. '"', 1, true), "KOReader has style tweak " .. id)
        end
    end
end)
