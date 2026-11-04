--[[--
The "Text" panel: a bottom sheet in the reader, in three tabs, like the
Kindle's "Aa" panel:

  Themes   Compact, Standard, Large, and your own saved settings
  Font     the font family (written in its own typeface, a list behind
           it), Bold as a bar of boxes, Size as a numbered bar of boxes
  Layout   the page (Compact, Normal, Roomy) and the alignment, as
           pictures of a page

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

-- A bar of boxes, like the Kindle's: − [■■■□□□] +, the current level
-- numbered above it. Tapping a box sets that level. Returns the bottom.
local function levelBar(nodes, t, id, label, x, y, w, n, current, action_key, show_number, numbers)
    local row_h = math.max(t.touch, t.type.title.line)
    local label_w = math.floor(w * 0.22)
    textNode(nodes, t, { id = "label_" .. id, x = x, y = y + math.floor((row_h - t.type.body.line) / 2), w = label_w,
        text = label, style = "body" })
    local btn = t.touch
    local bx = x + label_w
    local bw = w - label_w
    textNode(nodes, t, { id = id .. "_minus", x = bx, y = y + math.floor((row_h - t.type.title.line) / 2), w = btn,
        text = "−", style = "title", align = "center" })
    textNode(nodes, t, { id = id .. "_plus", x = bx + bw - btn, y = y + math.floor((row_h - t.type.title.line) / 2), w = btn,
        text = "+", style = "title", align = "center" })
    tap(nodes, bx, y, btn, row_h, { type = "level", key = action_key, delta = -1 })
    tap(nodes, bx + bw - btn, y, btn, row_h, { type = "level", key = action_key, delta = 1 })
    local gap = math.max(1, math.floor(t:mm(0.6)))
    local sx, sw = bx + btn + t:space(1), bw - 2 * btn - t:space(2)
    local box_w = math.floor((sw - (n - 1) * gap) / n)
    local box_h = math.max(4, math.floor(t:mm(2.2)))
    local by = y + math.floor((row_h - box_h) / 2)
    for i = 1, n do
        local cx = sx + (i - 1) * (box_w + gap)
        nodes[#nodes + 1] = { kind = "box", id = id .. "_box_" .. i, x = cx, y = by, w = box_w, h = box_h,
            fill = i <= current and "text" or "paper", border = "text", bw = t.hairline }
        tap(nodes, cx - math.floor(gap / 2), y, box_w + gap, row_h, { type = "level", key = action_key, value = i })
    end
    if show_number and current >= 1 then
        local cx = sx + (current - 1) * (box_w + gap)
        local nw = math.max(box_w, t:mm(5))
        textNode(nodes, t, { id = id .. "_number", x = cx + math.floor((box_w - nw) / 2), y = by - t.type.micro.line, w = nw,
            text = tostring(numbers and numbers[current] or current), style = "micro", align = "center" })
    end
    return y + row_h
end

local function tabs(nodes, t, _, active, x, y, w)
    local list = { { "themes", _("Themes") }, { "font", _("Font") }, { "layout", _("Layout") } }
    local cx = x
    local h = t.touch
    for _i, tab in ipairs(list) do
        local style = tab[1] == active and "label" or "body"
        local tw = textWidth(t, tab[2], style) + 2 * t:space(2)
        textNode(nodes, t, { id = "tab_" .. tab[1], x = cx, y = y + math.floor((h - t.type[style].line) / 2), w = tw,
            text = tab[2], style = style, align = "center", color = tab[1] == active and "text" or "secondary" })
        if tab[1] == active then
            nodes[#nodes + 1] = { kind = "rule", id = "tab_underline", x = cx + t:space(1), y = y + h - t.rule, w = tw - t:space(2),
                h = t.rule, color = "text" }
        end
        tap(nodes, cx, y, tw, h, { type = "tab", tab = tab[1] })
        cx = cx + tw + t:space(1)
    end
    return y + h
end

local function themesTab(nodes, t, _, values, opts, x, y, w)
    local themes = opts.themes or {}
    local cols = 2
    local gap = t.gutter * 2
    local cw = math.floor((w - gap) / cols)
    local icon_w = math.floor(t:mm(6))
    local icon_h = math.floor(icon_w * 4 / 3)
    local row_h = math.max(t.touch, icon_h) + t:space(2)
    for i, th in ipairs(themes) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        local cx, cy = x + col * (cw + gap), y + row * row_h
        local page = ReaderLayout.page(th.spec.page)
        local current = th.current
        nodes[#nodes + 1] = { kind = "page", id = "theme_page_" .. i, x = cx, y = cy + math.floor((row_h - icon_h) / 2),
            w = icon_w, h = icon_h, selected = current, margin = Panel.MARGIN_SIZE[page.margins],
            gap = Panel.SPACING_GAP[page.spacing], align = "justify", paragraphs = "book" }
        local tx = cx + icon_w + t:space(2)
        local name_h = t.type.body.line + (current and t.type.micro.line or 0)
        local ty = cy + math.floor((row_h - name_h) / 2)
        textNode(nodes, t, { id = "theme_name_" .. i, x = tx, y = ty, w = cw - icon_w - t:space(2),
            text = th.builtin and _(th.name) or th.name, style = current and "label" or "body" })
        if current then
            textNode(nodes, t, { id = "theme_current_" .. i, x = tx, y = ty + t.type.body.line, w = cw - icon_w - t:space(2),
                text = _("Current theme"), style = "micro", color = "secondary" })
        end
        nodes[#nodes + 1] = { kind = "tap", x = cx, y = cy, w = cw, h = row_h, action = { type = "theme", id = th.id },
            hold_action = not th.builtin and { type = "theme_delete", id = th.id } or nil }
    end
    y = y + math.ceil(#themes / cols) * row_h + t:space(3)
    local bh = t.touch
    nodes[#nodes + 1] = { kind = "box", id = "save_box", x = x, y = y, w = w, h = bh, border = "text", bw = t.hairline }
    textNode(nodes, t, { id = "save", x = x, y = y + math.floor((bh - t.type.body.line) / 2), w = w,
        text = _("Save current settings"), style = "body", align = "center" })
    tap(nodes, x, y, w, bh, { type = "theme_save" })
    y = y + bh + t:space(1)
    textNode(nodes, t, { id = "themes_hint", x = x, y = y, w = w, text = _("Hold a theme you saved to delete it"),
        style = "micro", color = "secondary", align = "center" })
    return y + t.type.micro.line
end

local function fontTab(nodes, t, _, values, opts, x, y, w)
    -- Font family: the name, written in its own typeface
    local row_h = t.touch + t:space(2)
    textNode(nodes, t, { id = "label_family", x = x, y = y + math.floor((row_h - t.type.body.line) / 2), w = math.floor(w * 0.4),
        text = _("Font family"), style = "body" })
    local name = values.font or ""
    local name_w = math.min(math.floor(w * 0.5), textWidth(t, name, "caption") + t:space(1))
    local sample_w = math.floor(t:mm(10))
    local chev = t.touch
    local nx = x + w - chev - name_w
    textNode(nodes, t, { id = "family_sample", x = nx - sample_w - t:space(1), y = y + math.floor((row_h - t.type.headline.line) / 2),
        w = sample_w, text = "Aa", style = "headline", align = "right", font_file = opts.font_file })
    textNode(nodes, t, { id = "family_name", x = nx, y = y + math.floor((row_h - t.type.caption.line) / 2), w = name_w,
        text = name, style = "caption" })
    nodes[#nodes + 1] = { kind = "icon", id = "family_chevron", name = "chevron.right", x = x + w - math.floor(t:mm(4.5)),
        y = y + math.floor((row_h - t:mm(4.5)) / 2), w = math.floor(t:mm(4.5)), h = math.floor(t:mm(4.5)), color = "text" }
    tap(nodes, x, y, w, row_h, { type = "font_list" })
    y = y + row_h
    nodes[#nodes + 1] = { kind = "rule", id = "font_rule_1", x = x, y = y, w = w, h = t.hairline, color = "hairline" }
    y = y + t:space(2)
    -- Bold: five boxes over KOReader's font weight
    y = levelBar(nodes, t, "bold", _("Bold"), x, y, w, #ReaderLayout.WEIGHTS - 1,
        ReaderLayout.weightLevel(values.weight) - 1, "weight", false) + t:space(2)
    nodes[#nodes + 1] = { kind = "rule", id = "font_rule_2", x = x, y = y, w = w, h = t.hairline, color = "hairline" }
    y = y + t:space(2) + t.type.micro.line
    -- Size: numbered boxes
    y = levelBar(nodes, t, "size", _("Size"), x, y, w, #ReaderLayout.SIZE_LEVELS, ReaderLayout.sizeLevel(values.spec.pt),
        "pt", true)
    local ph = values.physical
    textNode(nodes, t, { id = "size_detail", x = x, y = y, w = w, style = "micro", color = "secondary", align = "right",
        text = string.format(_("%s pt · about %d characters a line"), (string.format("%.1f", ph.font_pt):gsub("%.0$", "")),
            ph.chars_per_line) })
    return y + t.type.micro.line
end

local function fontList(nodes, t, _, values, opts, x, y, w, max_bottom)
    local fonts = opts.fonts or {}
    local row_h = t.touch + t:space(1)
    -- back to the Font tab
    nodes[#nodes + 1] = { kind = "icon", id = "list_back", name = "chevron.left", x = x - math.floor(t:mm(1)),
        y = y + math.floor((t.touch - t:mm(5)) / 2), w = math.floor(t:mm(5)), h = math.floor(t:mm(5)), color = "text" }
    textNode(nodes, t, { id = "list_title", x = x + math.floor(t:mm(5)), y = y + math.floor((t.touch - t.type.label.line) / 2),
        w = w - math.floor(t:mm(5)), text = _("Font family"), style = "label" })
    tap(nodes, 0, y, x + w, t.touch, { type = "tab", tab = "font" })
    y = y + t.touch + t:space(1)
    local per_page = math.max(3, math.floor((max_bottom - y - t.touch) / row_h))
    local pages = math.max(1, math.ceil(#fonts / per_page))
    local page = math.max(1, math.min(opts.font_page or 1, pages))
    for k = 1, per_page do
        local f = fonts[(page - 1) * per_page + k]
        if not f then break end
        local ry = y + (k - 1) * row_h
        local selected = f.name == values.font
        textNode(nodes, t, { id = "font_row_sample_" .. k, x = x, y = ry + math.floor((row_h - t.type.title.line) / 2),
            w = math.floor(t:mm(11)), text = "Aa", style = "title", font_file = f.file })
        textNode(nodes, t, { id = "font_row_name_" .. k, x = x + math.floor(t:mm(13)), y = ry + math.floor((row_h - t.type.body.line) / 2),
            w = w - math.floor(t:mm(20)), text = f.name, style = selected and "label" or "body" })
        if selected then
            textNode(nodes, t, { id = "font_row_check_" .. k, x = x + w - t.touch, y = ry + math.floor((row_h - t.type.title.line) / 2),
                w = t.touch, text = "✓", style = "title", align = "right" })
        end
        nodes[#nodes + 1] = { kind = "rule", id = "font_row_rule_" .. k, x = x, y = ry + row_h - t.hairline, w = w,
            h = t.hairline, color = "hairline" }
        tap(nodes, x, ry, w, row_h, { type = "set", key = "font", value = f.name })
    end
    y = y + per_page * row_h
    if pages > 1 then
        textNode(nodes, t, { id = "font_pager", x = x + t.touch, y = y + math.floor((t.touch - t.type.caption.line) / 2),
            w = w - 2 * t.touch, text = string.format(_("%d of %d"), page, pages), style = "caption", color = "secondary",
            align = "center" })
        local icon = math.floor(t:mm(4.5))
        for _i, side in ipairs({ { "prev", -1, x, "chevron.left" }, { "next", 1, x + w - t.touch, "chevron.right" } }) do
            local active = (side[2] < 0 and page > 1) or (side[2] > 0 and page < pages)
            nodes[#nodes + 1] = { kind = "icon", id = "font_pager_" .. side[1], name = side[4],
                x = side[3] + math.floor((t.touch - icon) / 2), y = y + math.floor((t.touch - icon) / 2), w = icon, h = icon,
                color = active and "text" or "secondary" }
            if active then tap(nodes, side[3], y, t.touch, t.touch, { type = "font_page", delta = side[2] }) end
        end
        y = y + t.touch
    end
    return y
end

local function layoutTab(nodes, t, _, values, opts, x, y, w)
    local spec = values.spec
    local icon_w = math.floor(math.min(t:mm(9), (w - 6 * t:space(4)) / 5))
    if t.landscape then icon_w = math.min(icon_w, math.floor(t:mm(7))) end
    local icon_h = math.floor(icon_w * 4 / 3 + 0.5)
    local paragraphs = spec.book_style ~= false and "book" or "publisher"
    local pages = {}
    for _i, p in ipairs(ReaderLayout.PAGES) do
        pages[#pages + 1] = { key = "page", value = p.id, selected = p.id == ReaderLayout.page(spec.page).id, caption = _(p.name),
            page = { margin = Panel.MARGIN_SIZE[p.margins], gap = Panel.SPACING_GAP[p.spacing], align = spec.align,
                paragraphs = paragraphs } }
    end
    local now = ReaderLayout.page(spec.page)
    local aligns = {}
    for _i, a in ipairs(ReaderLayout.ALIGNMENTS) do
        aligns[#aligns + 1] = { key = "align", value = a.id, selected = spec.align == a.id, caption = _(a.name),
            page = { margin = Panel.MARGIN_SIZE[now.margins], gap = Panel.SPACING_GAP[now.spacing], align = a.id,
                paragraphs = paragraphs } }
    end
    local styles = {}
    for _i, st in ipairs({ { true, "Book" }, { false, "Status bar" } }) do
        styles[#styles + 1] = { key = "folio", value = st[1], selected = (spec.folio ~= false) == st[1], caption = _(st[2]),
            page = { margin = Panel.MARGIN_SIZE[now.margins], gap = Panel.SPACING_GAP[now.spacing], align = spec.align,
                paragraphs = paragraphs, folio = st[1] and "book" or "bar" } }
    end
    local gap = t.gutter * 2
    local left_w = math.floor((w - gap) * 0.6)
    local b1 = pageRow(nodes, t, { id = "page", text = _("Page") }, x, y, left_w, pages, icon_w, icon_h)
    local b2 = pageRow(nodes, t, { id = "align", text = _("Alignment") }, x + left_w + gap, y, w - left_w - gap, aligns,
        icon_w, icon_h)
    y = math.max(b1, b2) + t:space(3)
    -- the page style: a book's running head and page number, or KOReader's status bar
    y = pageRow(nodes, t, { id = "folio", text = _("Page style") }, x, y, left_w, styles, icon_w, icon_h) + t:space(2)
    local ph = values.physical
    textNode(nodes, t, { id = "layout_detail", x = x, y = y, w = w, style = "micro", color = "secondary", align = "center",
        text = string.format(_("%d mm margins · %d lines a page"), math.floor(ph.side_mm + 0.5), ph.lines_per_page) })
    return y + t.type.micro.line
end

--[[--
@tparam table t sereno/ui/theme for the screen
@tparam table values sereno/reader/layout.compute() result for the current spec (with .font)
@tparam function _ translate
@tparam table opts {
  tab = "themes" | "font" | "layout",
  font_list = bool (the Font family list instead of the Font tab), font_page,
  fonts = { {name, file}... }, font_file (of the current font),
  themes = { {id, name, spec, builtin, current}... } }
@treturn table nodes, number panel_y (top edge of the sheet)
]]
function Panel.layout(t, values, _, opts)
    _ = _ or function(s) return s end
    opts = opts or {}
    local tab = opts.tab or "font"
    local nodes = {}
    local m = t.margin
    local w = t.width - 2 * m
    local gap_v = t.height_mm < 135 and t:space(2) or t:space(3)

    -- laid out from y = 0, then moved to the bottom of the screen
    local y = t:space(1)
    local tabs_bottom = tabs(nodes, t, _, tab, m, y, w - t.touch)
    textNode(nodes, t, { id = "close", x = t.width - m - t.touch, y = y + math.floor((t.touch - t.type.title.line) / 2),
        w = t.touch, text = "✕", style = "title", align = "right" })
    tap(nodes, t.width - m - t.touch * 1.5, y, t.touch * 1.5 + m, t.touch, { type = "close" })
    y = tabs_bottom
    nodes[#nodes + 1] = { kind = "rule", id = "header_rule", x = 0, y = y, w = t.width, h = t.hairline, color = "text" }
    y = y + gap_v

    if tab == "themes" then
        y = themesTab(nodes, t, _, values, opts, m, y, w)
    elseif tab == "layout" then
        y = layoutTab(nodes, t, _, values, opts, m, y, w)
    elseif opts.font_list then
        y = fontList(nodes, t, _, values, opts, m, y, w, math.floor(t.height * 0.62))
    else
        y = fontTab(nodes, t, _, values, opts, m, y, w)
    end
    y = y + gap_v

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
    local line_h0 = math.max(1, math.floor(w * 0.035 + 0.5))
    if node.folio == "book" then
        -- a short running head at the top, a page number at the foot
        top = math.max(top, math.floor(h * 0.2))
        local hw = math.floor(w * 0.3)
        rect(x + math.floor((w - hw) / 2), y + math.floor(h * 0.09), hw, line_h0, "text")
        local fw = math.max(2, math.floor(w * 0.08))
        rect(x + math.floor((w - fw) / 2), y + h - math.floor(h * 0.1), fw, line_h0 + 1, "text")
    elseif node.folio == "bar" then
        -- a status line across the foot
        rect(x + m, y + h - math.floor(h * 0.1), math.floor((w - 2 * m) * 0.3), line_h0, "text")
        rect(x + w - m - math.floor((w - 2 * m) * 0.15), y + h - math.floor(h * 0.1), math.floor((w - 2 * m) * 0.15), line_h0, "text")
    end
    local line_h = math.max(1, math.floor(w * 0.035 + 0.5))
    local gap = math.max(line_h + 1, math.floor(w * node.gap + 0.5))
    local tw = w - 2 * m
    -- a fixed pattern of ragged line ends, so left-aligned pages look ragged
    local ragged = { 0.92, 0.78, 0.97, 0.85, 0.72, 0.95, 0.81, 0.9, 0.76, 0.98, 0.83, 0.88 }
    local indent = math.floor(tw * 0.18)
    local ly, i, line_in_para = y + top, 0, 0
    local para_len = { 4, 3, 5, 4, 3, 4 }
    local p = 1
    local bottom_room = node.folio and math.floor(h * 0.18) or top
    while ly + line_h <= y + h - bottom_room do
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
