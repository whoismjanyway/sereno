--[[--
Reading layout: the page you read, set in points and millimetres.

KOReader stores the reader's font size and margins in "relative pixels"
that it multiplies by Screen:scaleBySize, i.e. by min(width, height) / 600,
ignoring the screen's density. With its defaults (font 22, margins 10):

  6" Kindle, 167 dpi     9.5 pt text, 1.5 mm side margins
  Paperwhite 5, 300 dpi  10.9 pt text, 1.8 mm side margins
  Kindle Scribe, 300 dpi 16.4 pt text, 2.6 mm side margins

so text grows with the pixel count and the margins stay a hair wide on
every device: the text runs almost to the bezel.

Sereno describes a page the way the Kindle's own "Aa" panel does, with
as few knobs as possible:

  font        one of the fonts KOReader has
  text size   points, in half-point steps around a base set by the diagonal
  page        Compact, Normal or Roomy: margins in millimetres and line
              spacing that belong together; on big screens the margins
              grow instead of the lines
  (and, in Settings, justified or left-aligned text and book-style paragraphs)

Everything is converted back to KOReader's units for the
screen at hand. Pure Lua; the screen is passed in.
]]

local ReaderLayout = {}

-- average advance of running text in Noto Serif (KOReader's default face),
-- spaces included, in em: measured on set pages with KOReader's renderer
ReaderLayout.CHAR_EM = 0.52
-- crengine's interline spacing 100 % is the font's own line height
-- (ascender + descender): 1.36 em for Noto Serif, KOReader's default face
ReaderLayout.LINE_EM = 1.36

ReaderLayout.KOREADER_DEFAULT = { font_size = 22, h_margin = 10, t_margin = 10, b_margin = 10, line_spacing = 100 }

-- size range offered by the panel, in points relative to the base size
ReaderLayout.MIN_DELTA, ReaderLayout.MAX_DELTA, ReaderLayout.STEP = -2, 10, 0.5

ReaderLayout.SPACING = {
    { id = "tight", name = "Tight", line_spacing = 100 },  -- 1.36 em
    { id = "normal", name = "Normal", line_spacing = 110 }, -- 1.5 em, a well-set paperback
    { id = "loose", name = "Loose", line_spacing = 125 },  -- 1.7 em
}

-- Margins as in printed books: never less than a finger's grip on small
-- screens, and the column capped to a comfortable line length.
ReaderLayout.MARGINS = {
    { id = "narrow", name = "Narrow", side_mm = 5, top_mm = 5, bottom_mm = 4, max_chars = 75 },
    { id = "normal", name = "Normal", side_mm = 8, top_mm = 8, bottom_mm = 6, max_chars = 66 },
    { id = "wide", name = "Wide", side_mm = 14, top_mm = 11, bottom_mm = 8, max_chars = 58 },
}

ReaderLayout.ALIGNMENTS = {
    { id = "justify", name = "Justified" },
    { id = "left", name = "Left" },
}

-- The page, as the panel offers it: three choices, each a pair of margins
-- and line spacing that belong together (KISS: no separate knobs).
ReaderLayout.PAGES = {
    { id = "compact", name = "Compact", spacing = "tight", margins = "narrow" },
    { id = "normal", name = "Normal", spacing = "normal", margins = "normal" },
    { id = "roomy", name = "Roomy", spacing = "loose", margins = "wide" },
}

-- names of earlier versions' presets
local LEGACY = { paperback = { page = "normal" }, airy = { page = "roomy", pt = 0.5 }, large = { page = "normal", pt = 4 } }

--[[--
KOReader style tweaks (frontend/ui/data/css_tweaks.lua) that make a book
look typeset rather than like a word-processor page: first-line indents
instead of blank lines between paragraphs, no indent after a heading,
centred headings, no widows or orphans, hyphenation everywhere.
]]
ReaderLayout.BOOK_TWEAKS = {
    "paragraph_indent",
    "paragraph_first_no_indent",
    "paragraph_no_whitespace",
    "headings_align_center",
    "widows_orphans_avoid",
    "hyphenate_all_auto",
}
ReaderLayout.ALIGN_TWEAKS = { justify = "text_align_most_justify", left = "text_align_most_left" }

local function find(list, id)
    for _i, item in ipairs(list) do
        if item.id == id then return item end
    end
end

function ReaderLayout.page(id) return find(ReaderLayout.PAGES, id) or ReaderLayout.PAGES[2] end
function ReaderLayout.spacing(id) return find(ReaderLayout.SPACING, id) or ReaderLayout.SPACING[2] end
function ReaderLayout.margins(id) return find(ReaderLayout.MARGINS, id) or ReaderLayout.MARGINS[2] end

--[[--
A page description ("spec"): { pt, page, font, align, book_style }.
Accepts a page id, nil (Normal), or a spec, including earlier versions'
(preset names, or separate spacing and margins).
]]
function ReaderLayout.spec(p)
    if p == nil then p = "normal" end
    if type(p) ~= "table" then
        local legacy = LEGACY[p]
        p = legacy and { page = legacy.page, pt = legacy.pt } or { page = p }
    end
    local page = p.page
    if not find(ReaderLayout.PAGES, page or "") then
        page = (p.margins == "narrow" and "compact") or (p.margins == "wide" and "roomy") or "normal"
    end
    return {
        pt = p.pt or 0,
        page = page,
        font = p.font,
        align = (p.align == "left") and "left" or "justify",
        book_style = p.book_style ~= false,
    }
end

--- Reading size in points by physical diagonal: about 45-55 characters a
-- line on 6-7" screens with normal margins, like a mass-market paperback.
function ReaderLayout.basePt(diagonal_in)
    if diagonal_in < 6.5 then return 10 end
    if diagonal_in < 7.5 then return 10.5 end
    if diagonal_in < 9 then return 11.5 end
    -- 10" screens are read from further away, often on a desk or a lap
    return 13.5
end

function ReaderLayout.diagonal(screen)
    return math.sqrt(screen.width ^ 2 + screen.height ^ 2) / screen.dpi
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
        line_em = ReaderLayout.LINE_EM * (v.line_spacing or 100) / 100,
        chars_per_line = math.floor(content_w / (font_px * ReaderLayout.CHAR_EM)),
        lines_per_page = math.floor(text_h / line_px),
        line_spacing = v.line_spacing or 100,
    }
end

--[[--
KOReader values for a preset id or a spec on this screen.
@treturn table { font_size, h_margins = {l, r}, t_margin, b_margin, line_spacing,
  preset (id or nil), spec, physical = describe() }
]]
function ReaderLayout.compute(screen, preset_or_spec)
    local spec = ReaderLayout.spec(preset_or_spec)
    local delta = math.max(ReaderLayout.MIN_DELTA, math.min(ReaderLayout.MAX_DELTA, spec.pt))
    spec.pt = delta
    local page = ReaderLayout.page(spec.page)
    local spacing, margins = ReaderLayout.spacing(page.spacing), ReaderLayout.margins(page.margins)
    local f = ReaderLayout.scaleFactor(screen)
    local pt = ReaderLayout.basePt(ReaderLayout.diagonal(screen)) + delta
    local font_px = pt * screen.dpi / 72
    -- KOReader accepts half steps for the font size; it never goes below 12
    local font_size = math.max(12, round(font_px / f * 2) / 2)
    font_px = math.ceil(font_size * f)

    local side_px = margins.side_mm * screen.dpi / 25.4
    -- keep lines short enough to read comfortably: widen the margins if needed
    local max_chars = margins.max_chars
    local max_w = max_chars * ReaderLayout.CHAR_EM * font_px
    if screen.width - 2 * side_px > max_w then side_px = (screen.width - max_w) / 2 end
    local h = math.ceil(side_px / f)
    local t = math.ceil(margins.top_mm * screen.dpi / 25.4 / f)
    local b = math.ceil(margins.bottom_mm * screen.dpi / 25.4 / f)
    local values = {
        font_size = font_size,
        h_margins = { h, h },
        t_margin = t,
        b_margin = b,
        line_spacing = spacing.line_spacing,
        preset = spec.page,
        font = spec.font,
        spec = spec,
        align = spec.align,
        book_style = spec.book_style,
    }
    values.physical = ReaderLayout.describe(screen, {
        font_size = font_size, h_margin = h, t_margin = t, b_margin = b, line_spacing = spacing.line_spacing,
    })
    values.physical.pt_nominal = pt
    return values
end

--- The same spec with one axis changed (used by the panel).
function ReaderLayout.with(spec, key, value)
    local s = ReaderLayout.spec(spec)
    if key == "pt" then
        value = math.max(ReaderLayout.MIN_DELTA, math.min(ReaderLayout.MAX_DELTA, value))
    end
    s[key] = value
    return s
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

--[[--
The style tweaks to turn on and off for a spec, as two lists of ids.
Alignment is always set; the book style tweaks only when book_style is on.
]]
function ReaderLayout.tweaks(spec)
    local on, off = {}, {}
    for align, id in pairs(ReaderLayout.ALIGN_TWEAKS) do
        if align == spec.align then on[#on + 1] = id else off[#off + 1] = id end
    end
    for _i, id in ipairs(ReaderLayout.BOOK_TWEAKS) do
        if spec.book_style ~= false then on[#on + 1] = id else off[#off + 1] = id end
    end
    table.sort(on); table.sort(off)
    return on, off
end

--- Every tweak id Sereno may change (to keep the user's own choices aside).
function ReaderLayout.allTweaks()
    local all = {}
    for _i, id in ipairs(ReaderLayout.BOOK_TWEAKS) do all[#all + 1] = id end
    for _a, id in pairs(ReaderLayout.ALIGN_TWEAKS) do all[#all + 1] = id end
    table.sort(all)
    return all
end

return ReaderLayout
