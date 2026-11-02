--[[--
The "Text" panel: a bottom sheet in the reader, like the Kindle's "Aa"
panel, with only what you change while reading:

  Font   up to four fonts, each written in its own typeface
  Size   A− [ 10.5 pt · about 50 characters a line ] A+
  Page   Compact, Normal, Roomy: three pictures of a page

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
@tparam table fonts { {name, file}... } offered as tiles (at most 4), may be empty
@treturn table nodes, number panel_y (top edge of the sheet)
]]
function Panel.layout(t, values, _, fonts)
    _ = _ or function(s) return s end
    fonts = fonts or {}
    local spec, ph = values.spec, values.physical
    local nodes = {}
    local m = t.margin
    local w = t.width - 2 * m
    local gap_v = t.height_mm < 135 and t:space(2) or t:space(3)

    -- laid out from y = 0, then moved to the bottom of the screen
    local y = t:space(1)
    local header_h = t.touch
    textNode(nodes, t, { id = "title", x = m, y = y + math.floor((header_h - t.type.title.line) / 2), w = math.floor(w / 2),
        text = _("Text"), style = "title" })
    textNode(nodes, t, { id = "close", x = t.width - m - t.touch, y = y + math.floor((header_h - t.type.title.line) / 2),
        w = t.touch, text = "✕", style = "title", align = "right" })
    tap(nodes, t.width - m - t.touch * 1.5, y, t.touch * 1.5 + m, header_h, { type = "close" })
    y = y + header_h + t:space(1)
    nodes[#nodes + 1] = { kind = "rule", id = "header_rule", x = 0, y = y, w = t.width, h = t.hairline, color = "hairline" }
    y = y + gap_v

    -- 1. Font: each choice written in its own typeface
    if #fonts > 0 then
        textNode(nodes, t, { id = "label_font", x = m, y = y, w = w, text = _("Font"), style = "label" })
        y = y + t.type.label.line + t:space(1)
        local n = math.min(4, #fonts)
        local gap = t:space(2)
        local fw = math.floor((w - (n - 1) * gap) / n)
        local fh = t.touch + t.type.micro.line + t:space(2)
        for i = 1, n do
            local f = fonts[i]
            local fx = m + (i - 1) * (fw + gap)
            local selected = f.name == values.font or f.selected
            nodes[#nodes + 1] = { kind = "box", id = "font_box_" .. i, x = fx, y = y, w = fw, h = fh, border = "text",
                bw = selected and math.max(3, t.hairline * 3) or t.hairline, radius = math.floor(t:mm(1.5)) }
            textNode(nodes, t, { id = "font_sample_" .. i, x = fx + t:space(1), y = y + t:space(1), w = fw - t:space(2),
                h = t.touch - t:space(1), text = "Aa", style = "title", align = "center", font_file = f.file })
            textNode(nodes, t, { id = "font_name_" .. i, x = fx + t:space(1), y = y + t.touch, w = fw - t:space(2),
                text = f.name, style = selected and "micro_bold" or "micro", align = "center" })
            tap(nodes, fx, y, fw, fh, { type = "set", key = "font", value = f.name })
        end
        y = y + fh + gap_v
    end

    -- 2. Size: small A, the size, big A. On landscape screens, Size and Page
    -- share one row, so the sheet stays short.
    local full_w, size_top = w, y
    if t.landscape then w = math.floor((full_w - t.gutter * 2) / 2) end
    textNode(nodes, t, { id = "label_size", x = m, y = y, w = w, text = _("Size"), style = "label" })
    y = y + t.type.label.line + t:space(1)
    local btn = t.touch
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
    -- the value and its detail may be taller than the buttons on small screens
    local row_h = math.max(btn, t.type.title.line + t.type.micro.line)
    local by = y + math.floor((row_h - btn) / 2)
    for _i, node in ipairs(nodes) do
        if node.id == "size_down_box" or node.id == "size_up_box" or node.id == "size_down" or node.id == "size_up" then
            node.y = node.y + (by - y)
        end
    end
    local vy = y + math.floor((row_h - t.type.title.line - t.type.micro.line) / 2)
    textNode(nodes, t, { id = "size_value", x = mid_x, y = vy, w = mid_w, text = pt_text, style = "title", align = "center" })
    textNode(nodes, t, { id = "size_detail", x = mid_x, y = vy + t.type.title.line, w = mid_w,
        text = string.format(_("about %d characters a line"), ph.chars_per_line), style = "micro", color = "secondary",
        align = "center" })
    tap(nodes, m, y, btn + t:space(1), row_h, { type = "size", delta = -ReaderLayout.STEP })
    tap(nodes, m + w - btn - t:space(1), y, btn + t:space(1), row_h, { type = "size", delta = ReaderLayout.STEP })
    y = y + row_h + gap_v
    local page_x = m
    if t.landscape then
        page_x, y = m + w + t.gutter * 2, size_top
    end

    -- 3. Page: three pictures of a page, margins and spacing together
    local page_now = ReaderLayout.page(spec.page)
    local icon_w = math.floor(math.min(t:mm(10), (w - 4 * t:space(4)) / 3))
    if t.landscape then icon_w = math.floor(math.min(icon_w, t:mm(7))) end
    local icon_h = math.floor(icon_w * 4 / 3 + 0.5)
    local options = {}
    for _i, p in ipairs(ReaderLayout.PAGES) do
        options[#options + 1] = {
            key = "page", value = p.id, selected = p.id == page_now.id, caption = _(p.name),
            page = { margin = Panel.MARGIN_SIZE[p.margins], gap = Panel.SPACING_GAP[p.spacing],
                align = spec.align, paragraphs = spec.book_style ~= false and "book" or "publisher" },
        }
    end
    local row_w = 3 * icon_w + 2 * math.min(t:space(4) * 2, t:mm(12))
    local page_bottom = pageRow(nodes, t, { id = "page", text = _("Page") }, page_x + math.floor((w - row_w) / 2), y,
        row_w, options, icon_w, icon_h)
    -- the label sits at the block's left edge like the others
    for _i, node in ipairs(nodes) do if node.id == "label_page" then node.x, node.w = page_x, w end end
    y = math.max(page_bottom, t.landscape and (size_top + t.type.label.line + t:space(1) + math.max(t.touch,
        t.type.title.line + t.type.micro.line)) or 0) + gap_v
    w = full_w

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
