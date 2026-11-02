-- Design system: sizes come from physical units, not pixels.
local H = require("helper")
local test, eq, near, truthy = H.it, H.eq, H.near, H.truthy
local Theme = require("sereno/ui/theme")

local DEVICES = {
    basic = { width = 600, height = 800, dpi = 167 },
    paperwhite = { width = 1236, height = 1648, dpi = 300 },
    oasis = { width = 1264, height = 1680, dpi = 300 },
    scribe = { width = 1860, height = 2480, dpi = 300 },
}

H.describe("theme")

test("body text has the same printed size on 6-7\" screens of any density", function()
    local basic, pw = Theme.new(DEVICES.basic), Theme.new(DEVICES.paperwhite)
    local mm_basic = basic.type.body.size / basic.dpi * 25.4
    local mm_pw = pw.type.body.size / pw.dpi * 25.4
    near(mm_basic, mm_pw, 0.25, "body size in mm")
end)

test("bigger screens get a slightly bigger body size, not a scaled-up one", function()
    local pw, scribe = Theme.new(DEVICES.paperwhite), Theme.new(DEVICES.scribe)
    truthy(scribe.body_pt > pw.body_pt)
    -- KOReader's scaleBySize would grow text by the pixel ratio (~1.5x here)
    truthy(scribe.type.body.size / pw.type.body.size < 1.2)
end)

test("modular scale", function()
    local t = Theme.new(DEVICES.paperwhite)
    near(t.type.title.size / t.type.body.size, 1.25 ^ 2, 0.05)
    truthy(t.type.caption.size < t.type.body.size and t.type.body.size < t.type.headline.size)
    for _name, style in pairs(t.type) do
        truthy(style.line >= style.size, "leading never below 1")
    end
end)

test("margins are at least 6 mm and the column stays readable", function()
    for name, d in pairs(DEVICES) do
        local t = Theme.new(d)
        truthy(t.margin / t.dpi * 25.4 >= 5.9, name .. " margin")
        truthy(t.content_width / t.dpi * 25.4 <= 111, name .. " column")
        truthy(t.touch / t.dpi * 25.4 >= 6.9, name .. " touch target")
    end
end)

test("grid spans add up", function()
    local t = Theme.new(DEVICES.paperwhite)
    near(t:span(t.columns), t.content_width, 1)
    eq(t:space(2), 2 * t.unit)
end)

test("faceSize undoes KOReader's scaleBySize", function()
    local t = Theme.new({ width = 1236, height = 1648, dpi = 300,
        scale_by_size = function(n) return math.ceil(n * 2.06) end })
    local face = t:faceSize(44)
    near(math.ceil(face * 2.06), 44, 2)
end)

test("landscape uses a wider grid", function()
    local t = Theme.new({ width = 1648, height = 1236, dpi = 300 })
    eq(t.landscape, true)
    eq(t.columns, 8)
end)
