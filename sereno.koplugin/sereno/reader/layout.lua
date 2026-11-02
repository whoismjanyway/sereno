--[[--
Reading layout: the page you read, set in points and millimetres.

KOReader stores the reader's font size and margins in "relative pixels"
that it multiplies by Screen:scaleBySize, i.e. by min(width, height) / 600,
ignoring the screen's density. With its defaults (font 22, margins 10):

  6" Kindle, 167 dpi     9.5 pt text, 1.5 mm side margins
  Paperwhite 5, 300 dpi  10.9 pt text, 1.8 mm side margins
  Kindle Scribe, 300 dpi 16.4 pt text, 2.6 mm side margins

so text grows with the pixel count and the margins stay a hair wide on
every device. Sereno's presets are defined physically (points, mm, a
maximum number of characters per line) and converted back to KOReader's
units for the screen at hand. Pure Lua; the screen is passed in.
]]

local ReaderLayout = {}

-- average advance of a serif text face, spaces included, in em
ReaderLayout.CHAR_EM = 0.47
-- KOReader's interline spacing 100 % gives roughly this line height, in em
ReaderLayout.LINE_EM = 1.2

ReaderLayout.KOREADER_DEFAULT = { font_size = 22, h_margin = 10, t_margin = 10, b_margin = 10, line_spacing = 100 }

-- size offsets are added to the base size chosen by screen diagonal
ReaderLayout.PRESETS = {
    { id = "compact", name = "Compact", pt = -0.5, side_mm = 4, top_mm = 3, bottom_mm = 3, line_spacing = 100, max_chars = 75 },
    { id = "paperback", name = "Paperback", pt = 0, side_mm = 6, top_mm = 5, bottom_mm = 5, line_spacing = 110, max_chars = 68 },
    { id = "airy", name = "Airy", pt = 0.5, side_mm = 9, top_mm = 8, bottom_mm = 8, line_spacing = 125, max_chars = 60 },
    { id = "large", name = "Large print", pt = 4, side_mm = 6, top_mm = 5, bottom_mm = 5, line_spacing = 115, max_chars = 50 },
}

function ReaderLayout.preset(id)
    for _i, p in ipairs(ReaderLayout.PRESETS) do
        if p.id == id then return p end
    end
    return ReaderLayout.PRESETS[2]
end

--- Reading size in points by physical diagonal: about 45-55 characters a
-- line on 6-7" screens, like a mass-market paperback.
function ReaderLayout.basePt(diagonal_in)
    if diagonal_in < 6.5 then return 10 end
    if diagonal_in < 7.5 then return 10.5 end
    if diagonal_in < 9 then return 11.5 end
    return 12.5
end

--- KOReader's default scale factor: Screen:scaleBySize(n) = ceil(n * factor).
function ReaderLayout.scaleFactor(screen)
    if screen.scale_by_size then return screen.scale_by_size(1000) / 1000 end
    return math.min(screen.width, screen.height) / 600
end

local function round(x) return math.floor(x + 0.5) end

--[[--
What a set of KOReader values looks like physically on this screen.
@tparam table screen { width, height, dpi, scale_by_size (optional), footer_px (optional) }
@tparam table v { font_size, h_margin, t_margin, b_margin, line_spacing } in KOReader units
]]
function ReaderLayout.describe(screen, v)
    local f = ReaderLayout.scaleFactor(screen)
    local px = function(u) return math.ceil(u * f) end
    local mm = function(p) return p / screen.dpi * 25.4 end
    local font_px = px(v.font_size)
    local side_px = px(v.h_margin)
    local content_w = screen.width - 2 * side_px
    local line_px = font_px * ReaderLayout.LINE_EM * (v.line_spacing or 100) / 100
    local text_h = screen.height - px(v.t_margin) - px(v.b_margin) - (screen.footer_px or 0)
    return {
        font_px = font_px,
        font_pt = font_px / screen.dpi * 72,
        side_px = side_px,
        side_mm = mm(side_px),
        top_px = px(v.t_margin),
        bottom_px = px(v.b_margin),
        top_mm = mm(px(v.t_margin)),
        bottom_mm = mm(px(v.b_margin)),
        line_px = line_px,
        chars_per_line = math.floor(content_w / (font_px * ReaderLayout.CHAR_EM)),
        lines_per_page = math.floor(text_h / line_px),
        line_spacing = v.line_spacing or 100,
    }
end

--[[--
KOReader values for a preset on this screen.
@treturn table { font_size, h_margins = {l, r}, t_margin, b_margin, line_spacing, preset, physical = describe() }
]]
function ReaderLayout.compute(screen, preset_id)
    local p = type(preset_id) == "table" and preset_id or ReaderLayout.preset(preset_id)
    local f = ReaderLayout.scaleFactor(screen)
    local diagonal = math.sqrt(screen.width ^ 2 + screen.height ^ 2) / screen.dpi
    local pt = ReaderLayout.basePt(diagonal) + p.pt
    local font_px = pt * screen.dpi / 72
    -- KOReader accepts half steps for the font size; it never goes below 12
    local font_size = math.max(12, round(font_px / f * 2) / 2)
    font_px = math.ceil(font_size * f)

    local side_px = p.side_mm * screen.dpi / 25.4
    -- keep lines short enough to read comfortably: widen the margins if needed
    local max_w = p.max_chars * ReaderLayout.CHAR_EM * font_px
    if screen.width - 2 * side_px > max_w then side_px = (screen.width - max_w) / 2 end
    local h = round(side_px / f)
    local t = round(p.top_mm * screen.dpi / 25.4 / f)
    local b = round(p.bottom_mm * screen.dpi / 25.4 / f)
    local values = {
        font_size = font_size,
        h_margins = { h, h },
        t_margin = t,
        b_margin = b,
        line_spacing = p.line_spacing,
        preset = p.id,
    }
    values.physical = ReaderLayout.describe(screen, {
        font_size = font_size, h_margin = h, t_margin = t, b_margin = b, line_spacing = p.line_spacing,
    })
    return values
end

ReaderLayout.SETTING_KEYS = { "copt_font_size", "copt_h_page_margins", "copt_t_page_margin", "copt_b_page_margin", "copt_line_spacing" }

--- The settings keys KOReader reads as defaults for new books (G_reader_settings).
function ReaderLayout.defaultSettings(values)
    return {
        copt_font_size = values.font_size,
        copt_h_page_margins = { values.h_margins[1], values.h_margins[2] },
        copt_t_page_margin = values.t_margin,
        copt_b_page_margin = values.b_margin,
        copt_line_spacing = values.line_spacing,
    }
end

return ReaderLayout
