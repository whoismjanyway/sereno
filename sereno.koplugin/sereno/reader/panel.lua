--[[--
The "Text & page" panel: a bottom sheet in the reader, in the spirit of the
Kindle's "Aa" panel. Every choice is a picture of a page, so it can be
judged at a glance and tapped with a thumb:

  Layout       Compact · Paperback · Airy · Large print
  Text size    A− [ 10.5 pt · about 50 characters a line ] A+
  Spacing      three pages with tight, normal and loose lines
  Margins      three pages with narrow, normal and wide margins
  Alignment    justified or ragged-right lines
  Paragraphs   book style (indents, no gaps) or the publisher's own

Pure Lua: lays the panel out as positioned nodes, in screen coordinates,
for sereno/reader/panelwidget.lua (KOReader) and the renderers in tools/.

Node kinds (in addition to sereno/home/layout's text, box, rule, tap):
  page { x, y, w, h, selected, margin, gap, align, paragraphs }
       a miniature page: `margin` and `gap` are fractions of the icon's
       width, `align` is "justify" or "left", `paragraphs` "book" or
       "publisher"
]]

local Layout = require("sereno/home/layout")
local ReaderLayout = require("sereno/reader/layout")

local Panel = {}

-- the miniature pages, from the real values each option stands for
Panel.SPACING_GAP = { tight = 0.075, normal = 0.10, loose = 0.135 }
Panel.MARGIN_SIZE = { narrow = 0.08, normal = 0.17, wide = 0.27 }

local function textNode(nodes, t, s)
    s.kind = "text"
    s.h = s.h or t.type[s.style].line
    s.max_lines = 1
    nodes[#nodes + 1] = s
    return s
end

local function tap(nodes, x, y, w, h, action)
    nodes[#nodes + 1] = { kind = "tap", x = x, y = y, w = w, h = h, action = action }
end

local function textWidth(t, text, style)
    if t.measure_width then return t.measure_width(text, style) end
    local st = t.type[style]
    local adv = st.size * (st.font:find("Serif") and Layout.ADVANCE.serif or Layout.ADVANCE.sans)
    local _, cont = text:gsub("[\128-\191]", "")
    return math.ceil((#text - cont) * adv)
end

-- A row of miniature pages under a label; returns the bottom edge.
local function pageRow(nodes, t, label, x, y, w, options, icon_w, icon_h)
    textNode(nodes, t, { id = "label_" .. label.id, x = x, y = y, w = w, text = label.text, style = "label" })
    y = y + t.type.label.line + t:space(1)
    local gap = math.min(t:space(4), math.floor((w - #options * icon_w) / math.max(1, #options - 1)))
    for i, o in ipairs(options) do
        local ix = x + (i - 1) * (icon_w + gap)
        local page = o.page
        page.kind, page.x, page.y, page.w, page.h, page.selected = "page", ix, y, icon_w, icon_h, o.selected
        page.id = "page_" .. label.id .. "_" .. tostring(o.value)
        nodes[#nodes + 1] = page
        -- the caption under each page names the option
        textNode(nodes, t, { id = "caption_" .. label.id .. "_" .. tostring(o.value), x = ix - gap / 2, y = y + icon_h + t:space(1),
            w = icon_w + gap, text = o.caption, style = o.selected and "micro_bold" or "micro",
            color = o.selected and "text" or "secondary", align = "center" })
        -- the touch area covers the page and its caption, at least 7 mm
        tap(nodes, ix - math.floor(gap / 2), y - t:space(1), icon_w + gap, icon_h + t.type.micro.line + t:space(3),
            { type = "set", key = o.key, value = o.value })
    end
    return y + icon_h + t:space(1) + t.type.micro.line
end

--[[--
@tparam table t sereno/ui/theme for the screen
@tparam table values sereno/reader/layout.compute() result for the current spec
@tparam function _ translate
@treturn table nodes, number panel_y (top edge of the sheet)
]]
function Panel.layout(t, values, _)
    _ = _ or function(s) return s end
    local spec, ph = values.spec, values.physical
    local nodes = {}
    local m = t.margin
    -- short screens (6" and smaller) get a tighter rhythm: 2 units instead of 3
    local gap_v = t.height_mm < 135 and t:space(2) or t:space(3)
    local w = t.width - 2 * m
    local col_gap = t.gutter * 2
    -- the four groups of pages sit in a 2 × 2 grid, or in one row when the
    -- screen is wide enough (landscape)
    local cols = (t.landscape or (w - 3 * col_gap) / 4 >= t:mm(30)) and 4 or 2
    local rows = 4 / cols
    local col_w = math.floor((w - (cols - 1) * col_gap) / cols)
    local icon_w = math.min(math.floor(t:mm(10)), math.floor((col_w - 2 * t:space(2)) / 3))
    local icon_h = math.floor(icon_w * 4 / 3 + 0.5)
    -- the sheet takes at most ~70 % of the screen, so the page stays in view:
    -- everything but the two rows of pages is fixed, the pages shrink to fit
    local btn = t.touch + (t.height_mm < 135 and 0 or t:space(2))
    local fixed = t:space(1) + t.touch + t:space(1) + gap_v -- header
        + t.touch + gap_v                              -- layouts
        + btn + gap_v                                  -- text size
        + rows * (t.type.label.line + t:space(1) + t:space(1) + t.type.micro.line + gap_v)
        + t:space(2) + t.type.micro.line + gap_v       -- summary
    local room = math.floor((t.height * 0.7 - fixed) / rows)
    if icon_h > room then
        icon_h = math.max(math.floor(t:mm(6)), room)
        icon_w = math.min(icon_w, math.floor(icon_h * 3 / 4 + 0.5))
    end

    -- laid out from y = 0, then moved to the bottom of the screen
    local y = t:space(1)
    local header_h = t.touch
    textNode(nodes, t, { id = "title", x = m, y = y + math.floor((header_h - t.type.title.line) / 2), w = w / 2,
        text = _("Text & page"), style = "title" })
    textNode(nodes, t, { id = "close", x = t.width - m - t.touch, y = y + math.floor((header_h - t.type.title.line) / 2),
        w = t.touch, text = "✕", style = "title", align = "right" })
    tap(nodes, t.width - m - t.touch * 1.5, y, t.touch * 1.5 + m, header_h, { type = "close" })
    y = y + header_h + t:space(1)
    nodes[#nodes + 1] = { kind = "rule", id = "header_rule", x = 0, y = y, w = t.width, h = t.hairline, color = "hairline" }
    y = y + gap_v

    -- presets as a segmented control
    local seg_h = t.touch
    local n = #ReaderLayout.PRESETS
    local seg_w = math.floor(w / n)
    nodes[#nodes + 1] = { kind = "box", id = "presets", x = m, y = y, w = seg_w * n, h = seg_h, border = "text",
        bw = t.hairline, radius = math.floor(t:mm(1.5)) }
    for i, p in ipairs(ReaderLayout.PRESETS) do
        local sx = m + (i - 1) * seg_w
        local selected = values.preset == p.id
        if selected then
            nodes[#nodes + 1] = { kind = "box", id = "preset_sel_" .. p.id, x = sx, y = y, w = seg_w, h = seg_h, fill = "text",
                radius = math.floor(t:mm(1.5)) }
        elseif i > 1 then
            nodes[#nodes + 1] = { kind = "rule", id = "preset_div_" .. p.id, x = sx, y = y + t:space(1), w = t.hairline,
                h = seg_h - t:space(2), color = "hairline" }
        end
        local label = _(p.name)
        local style = textWidth(t, label, "caption") <= seg_w - t:space(2) and "caption" or "micro"
        textNode(nodes, t, { id = "preset_" .. p.id, x = sx + t:space(1), y = y + math.floor((seg_h - t.type[style].line) / 2),
            w = seg_w - t:space(2), text = label, style = style, align = "center", color = selected and "paper" or "text" })
        tap(nodes, sx, y, seg_w, seg_h, { type = "preset", id = p.id })
    end
    y = y + seg_h + gap_v

    -- text size: small A, the size, big A
    nodes[#nodes + 1] = { kind = "box", id = "size_down_box", x = m, y = y, w = btn, h = btn, border = "text", bw = t.hairline,
        radius = math.floor(btn / 2) }
    textNode(nodes, t, { id = "size_down", x = m, y = y + math.floor((btn - t.type.caption.line) / 2), w = btn, text = "A",
        style = "caption", align = "center" })
    nodes[#nodes + 1] = { kind = "box", id = "size_up_box", x = m + w - btn, y = y, w = btn, h = btn, border = "text",
        bw = t.hairline, radius = math.floor(btn / 2) }
    textNode(nodes, t, { id = "size_up", x = m + w - btn, y = y + math.floor((btn - t.type.title.line) / 2), w = btn, text = "A",
        style = "title", align = "center" })
    local mid_x, mid_w = m + btn + t:space(2), w - 2 * btn - t:space(4)
    local pt_text = string.format("%s pt", (string.format("%.1f", ph.font_pt):gsub("%.0$", "")))
    textNode(nodes, t, { id = "size_value", x = mid_x, y = y + math.floor((btn - t.type.title.line - t.type.micro.line) / 2),
        w = mid_w, text = pt_text, style = "title", align = "center" })
    textNode(nodes, t, { id = "size_detail", x = mid_x,
        y = y + math.floor((btn - t.type.title.line - t.type.micro.line) / 2) + t.type.title.line, w = mid_w,
        text = string.format(_("about %d characters a line"), ph.chars_per_line), style = "micro", color = "secondary",
        align = "center" })
    tap(nodes, m, y, btn + t:space(1), btn, { type = "size", delta = -ReaderLayout.STEP })
    tap(nodes, m + w - btn - t:space(1), y, btn + t:space(1), btn, { type = "size", delta = ReaderLayout.STEP })
    y = y + btn + gap_v

    local function options(key, list, page_of, caption_of)
        local out = {}
        for _i, o in ipairs(list) do
            out[#out + 1] = { key = key, value = o.id, selected = spec[key] == o.id, page = page_of(o), caption = caption_of(o) }
        end
        return out
    end
    local base_page = { margin = Panel.MARGIN_SIZE[spec.margins], gap = Panel.SPACING_GAP[spec.spacing],
        align = spec.align, paragraphs = spec.book_style ~= false and "book" or "publisher" }
    local function page(over)
        local p = {}
        for k, v in pairs(base_page) do p[k] = v end
        for k, v in pairs(over) do p[k] = v end
        return p
    end
    local name = function(o) return _(o.name) end
    local para = {}
    for _i, st in ipairs({ { id = true, key = "book", name = "Book" }, { id = false, key = "publisher", name = "Publisher" } }) do
        para[#para + 1] = { key = "book_style", value = st.id, selected = (spec.book_style ~= false) == st.id,
            page = page{ paragraphs = st.key }, caption = _(st.name) }
    end
    local groups = {
        { id = "spacing", text = _("Spacing"),
          options = options("spacing", ReaderLayout.SPACING, function(o) return page{ gap = Panel.SPACING_GAP[o.id] } end, name) },
        { id = "margins", text = _("Margins"),
          options = options("margins", ReaderLayout.MARGINS, function(o) return page{ margin = Panel.MARGIN_SIZE[o.id] } end, name) },
        { id = "align", text = _("Alignment"),
          options = options("align", ReaderLayout.ALIGNMENTS, function(o) return page{ align = o.id } end, name) },
        { id = "paragraphs", text = _("Paragraphs"), options = para },
    }
    local row_bottom = y
    for i, g in ipairs(groups) do
        local col = (i - 1) % cols
        if col == 0 and i > 1 then y = row_bottom + gap_v end
        local b = pageRow(nodes, t, g, m + col * (col_w + col_gap), y, col_w, g.options, icon_w, icon_h)
        row_bottom = math.max(col == 0 and b or row_bottom, b)
    end
    y = row_bottom + gap_v

    nodes[#nodes + 1] = { kind = "rule", id = "summary_rule", x = m, y = y, w = w, h = t.hairline, color = "hairline" }
    y = y + t:space(2)
    textNode(nodes, t, { id = "summary", x = m, y = y, w = w, style = "micro", color = "secondary", align = "center",
        text = string.format(_("%d mm margins · %d lines a page · applies to new books too"),
            math.floor(ph.side_mm + 0.5), ph.lines_per_page) })
    y = y + t.type.micro.line + gap_v

    -- move the sheet to the bottom of the screen, under a top border
    local panel_h = y
    local top = t.height - panel_h
    for _i, node in ipairs(nodes) do node.y = node.y + top end
    table.insert(nodes, 1, { kind = "box", id = "sheet", x = 0, y = top, w = t.width, h = panel_h, fill = "paper" })
    table.insert(nodes, 2, { kind = "rule", id = "sheet_edge", x = 0, y = top, w = t.width, h = t.rule, color = "text" })
    return nodes, top
end

--[[--
Draws a miniature page with any painter that can fill rectangles:
`rect(x, y, w, h, ink)` with ink "text", "hairline" or "paper".
Shared by the KOReader widget and the SVG/korender tools, so the icons
are the same everywhere.
]]
function Panel.paintPage(node, rect, hairline)
    local x, y, w, h = node.x, node.y, node.w, node.h
    local bw = node.selected and math.max(2, hairline * 3) or hairline
    rect(x, y, w, h, "paper")
    -- border: thick when selected, like the Kindle's panel
    rect(x, y, w, bw, "text"); rect(x, y + h - bw, w, bw, "text")
    rect(x, y, bw, h, "text"); rect(x + w - bw, y, bw, h, "text")
    local m = math.max(bw + 1, math.floor(w * node.margin + 0.5))
    local top = math.max(bw + 1, math.floor(h * 0.12 + 0.5))
    local line_h = math.max(1, math.floor(w * 0.035 + 0.5))
    local gap = math.max(line_h + 1, math.floor(w * node.gap + 0.5))
    local tw = w - 2 * m
    -- a fixed pattern of ragged line ends, so left-aligned pages look ragged
    local ragged = { 0.92, 0.78, 0.97, 0.85, 0.72, 0.95, 0.81, 0.9, 0.76, 0.98, 0.83, 0.88 }
    local indent = math.floor(tw * 0.18)
    local ly, i, line_in_para = y + top, 0, 0
    local para_len = { 4, 3, 5, 4, 3, 4 }
    local p = 1
    while ly + line_h <= y + h - top do
        i = i + 1
        line_in_para = line_in_para + 1
        local last = line_in_para == para_len[(p - 1) % #para_len + 1]
        local lx, lw = x + m, tw
        if line_in_para == 1 and node.paragraphs == "book" and p > 1 then lx, lw = lx + indent, lw - indent end
        if node.align == "left" or last then lw = math.floor(lw * (last and 0.55 or ragged[(i - 1) % #ragged + 1])) end
        rect(lx, ly, lw, line_h, "text")
        ly = ly + gap
        if last then
            p, line_in_para = p + 1, 0
            if node.paragraphs == "publisher" then ly = ly + gap end
        end
    end
end

return Panel
