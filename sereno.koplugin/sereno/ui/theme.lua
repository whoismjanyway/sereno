--[[--
Sereno's design system, derived from the *physical* size of the screen.

KOReader scales UI fonts by the screen's pixel size, not its density
(Screen:scaleBySize ignores DPI unless overridden), and SimpleUI/ZenOS
build on that. The same theme therefore looks large on a 6" Kindle Basic
and small on a 10" Scribe. Sereno starts from millimetres and points
instead, so text has the same printed size on every device:

* Type: a modular scale (major third, ×1.25) around a body size chosen
  by screen diagonal, rounded to whole pixels. Serif for book titles,
  sans for interface text, as in printed books and their covers.
* Leading: 1.35× for body text, tighter for display sizes.
* Space: a baseline unit of 1.5 mm; margins and gutters are multiples.
* Margins: at least 6 mm, and wider on big screens so lines stay short.
* Colour: pure black text, and only two greys, both dark enough to stay
  sharp on 16-level e-ink panels (no light-grey text).

Pure Lua: the screen metrics are passed in.
]]

local Theme = {}
Theme.__index = Theme

Theme.RATIO = 1.25

Theme.FONTS = {
    serif = "NotoSerif-Regular.ttf",
    serif_bold = "NotoSerif-Bold.ttf",
    serif_italic = "NotoSerif-Italic.ttf",
    sans = "NotoSans-Regular.ttf",
    sans_bold = "NotoSans-Bold.ttf",
}

-- e-ink friendly greys (0 = black, 255 = white)
Theme.INK = { text = 0x00, secondary = 0x44, hairline = 0x88, track = 0xCC, paper = 0xFF }

local function round(x) return math.floor(x + 0.5) end

--[[--
@tparam table screen { width = px, height = px, dpi = n, scale_by_size = function(n) (optional) }
]]
function Theme.new(screen)
    local t = setmetatable({}, Theme)
    t.width, t.height = screen.width, screen.height
    t.dpi = (screen.dpi and screen.dpi > 0) and screen.dpi or 160
    t.landscape = t.width > t.height
    t.width_mm = t.width / t.dpi * 25.4
    t.height_mm = t.height / t.dpi * 25.4
    t.diagonal_in = math.sqrt(t.width ^ 2 + t.height ^ 2) / t.dpi
    t.scale_by_size = screen.scale_by_size

    -- body size by physical diagonal: phones-size readers to A4 tablets
    local body_pt
    if t.diagonal_in < 6.5 then body_pt = 10
    elseif t.diagonal_in < 7.5 then body_pt = 10.5
    elseif t.diagonal_in < 9 then body_pt = 11
    else body_pt = 12 end
    t.body_pt = body_pt

    local function size(steps)
        return round(t:pt(body_pt * Theme.RATIO ^ steps))
    end
    -- name = { px, leading, font }
    t.type = {
        micro    = { size = size(-2), leading = 1.3, font = Theme.FONTS.sans },
        micro_bold = { size = size(-2), leading = 1.3, font = Theme.FONTS.sans_bold },
        caption  = { size = size(-1), leading = 1.3, font = Theme.FONTS.sans },
        body     = { size = size(0),  leading = 1.35, font = Theme.FONTS.sans },
        label    = { size = size(0),  leading = 1.2, font = Theme.FONTS.sans_bold },
        title    = { size = size(2),  leading = 1.2, font = Theme.FONTS.serif },
        headline = { size = size(3),  leading = 1.15, font = Theme.FONTS.serif },
        display  = { size = size(5),  leading = 1.05, font = Theme.FONTS.serif },
    }
    for _name, style in pairs(t.type) do
        style.line = round(style.size * style.leading)
    end

    t.unit = math.max(2, round(t:mm(1.5)))
    t.hairline = math.max(1, round(t:mm(0.15)))
    t.rule = math.max(2, round(t:mm(0.4)))

    -- outer margin: >= 6 mm, and keep the content column under ~110 mm
    -- (portrait) or ~180 mm (landscape) so lines and rows stay readable
    local min_margin = t:mm(6)
    local max_column = t:mm(t.landscape and 180 or 110)
    t.margin = round(math.max(min_margin, (t.width - max_column) / 2, t.width * 0.055))
    t.content_width = t.width - 2 * t.margin
    t.gutter = round(t:mm(4))
    t.columns = t.landscape and 8 or (t.width_mm > 140 and 8 or 6)
    t.column_width = (t.content_width - t.gutter * (t.columns - 1)) / t.columns

    -- touch targets: at least 7 mm (WCAG/Material guidance for physical size)
    t.touch = round(t:mm(7))
    return t
end

--- Millimetres to pixels.
function Theme:mm(x) return x * self.dpi / 25.4 end

--- Typographic points to pixels.
function Theme:pt(x) return x * self.dpi / 72 end

--- Width spanned by `n` grid columns.
function Theme:span(n)
    n = math.min(n, self.columns)
    return math.floor(n * self.column_width + (n - 1) * self.gutter + 0.5)
end

--- Baseline units to pixels.
function Theme:space(n) return self.unit * n end

--[[--
The size to pass to KOReader's Font:getFace so the glyphs come out at
`px` real pixels: getFace multiplies by the screen's scaleBySize factor,
which we divide out here.
]]
function Theme:faceSize(px)
    if not self.scale_by_size then return px end
    local factor = self.scale_by_size(1000) / 1000
    if factor <= 0 then return px end
    return math.max(1, math.floor(px / factor + 0.5))
end

--- A cover box for a given width, at the usual 2:3 book proportion.
function Theme:coverHeight(width) return round(width * 1.5) end

return Theme
