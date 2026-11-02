--[[--
Lays out the home screen as a flat list of positioned nodes. Pure Lua:
the KOReader adapter (sereno/home/homescreen.lua) turns nodes into widgets,
and tools/preview.lua turns them into SVG, so the same layout can be
checked on many screen sizes without a device.

Node kinds:
  text   { x, y, w, h, text, style, color, max_lines, align }
  cover  { x, y, w, h, book }
  rule   { x, y, w, h, color }
  bar    { x, y, w, h, fraction }
  tap    { x, y, w, h, action }   -- invisible touch area

Principles: one focal point (the book you are reading), everything on a
grid and a 1.5 mm baseline unit, generous margins, at most three type
sizes per screen, no icons where a word is clearer, and nothing that
needs to repaint except the clock line.
]]

local Layout = {}

-- Average glyph advance as a fraction of the font size. Only used when no
-- real measuring function is available (previews, tests); on a device the
-- theme carries `measure`, backed by KOReader's own text shaping.
Layout.ADVANCE = { serif = 0.5, sans = 0.55 }

-- removes the last UTF-8 character
local function dropLast(s)
    return (s:gsub("[%z\1-\127\192-\255][\128-\191]*$", ""))
end

local function charCount(s)
    local _, cont = s:gsub("[\128-\191]", "")
    return #s - cont
end

--- Greedy word wrap with estimated glyph widths. Returns the list of lines,
-- the last one shortened with an ellipsis when `max_lines` cuts the text.
function Layout.wrap(text, style, width, max_lines)
    local adv = style.size * (style.font:find("Serif") and Layout.ADVANCE.serif or Layout.ADVANCE.sans)
    local per_line = math.max(1, math.floor(width / adv))
    local lines, line = {}, ""
    for word in (text or ""):gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if charCount(candidate) > per_line and line ~= "" then
            lines[#lines + 1] = line
            line = word
        else
            line = candidate
        end
        -- a single word longer than the line (narrow captions): shorten it
        if charCount(line) > per_line then
            local cut = line
            while charCount(cut) + 1 > per_line and #cut > 1 do
                cut = dropLast(cut)
            end
            line = cut .. "…"
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    if max_lines and #lines > max_lines then
        local last = lines[max_lines]
        while charCount(last) + 1 > per_line do
            last = dropLast(last)
        end
        lines[max_lines] = last:gsub("[%s%p]*$", "") .. "…"
        for i = #lines, max_lines + 1, -1 do lines[i] = nil end
    end
    return lines
end

local function estLines(t, text, style_name, width, max_lines)
    if not text or text == "" then return 0 end
    local n
    if t.measure then
        n = t.measure(text, style_name, width)
    else
        n = #Layout.wrap(text, t.type[style_name], width)
    end
    return math.max(1, math.min(max_lines or n, n))
end
Layout.estimateLines = estLines

local function text(nodes, t, s)
    local style = t.type[s.style]
    local lines = s.lines or estLines(t, s.text, s.style, s.w, s.max_lines)
    local node = {
        kind = "text", id = s.id, x = s.x, y = s.y, w = s.w, h = lines * style.line,
        text = s.text, style = s.style, color = s.color or "text", max_lines = s.max_lines or lines,
        align = s.align or "left",
    }
    nodes[#nodes + 1] = node
    return node.y + node.h
end

-- a small heading set in capitals with wide tracking, like a book's running head
local function sectionLabel(nodes, t, label, x, y, w)
    return text(nodes, t, { id = "label", text = label:upper(), style = "micro", color = "secondary", x = x, y = y, w = w, lines = 1 })
end

local function progressBlock(nodes, t, book, show_bar, x, y, w)
    if show_bar and book.percent and book.percent > 0 then
        local bar_h = math.max(t.rule, math.floor(t:mm(0.8) + 0.5))
        nodes[#nodes + 1] = { kind = "bar", x = x, y = y, w = w, h = bar_h, fraction = book.percent }
        y = y + bar_h + t:space(2)
    end
    if book.progress_line then
        y = text(nodes, t, { id = "progress", text = book.progress_line, style = "caption", x = x, y = y, w = w, max_lines = 2 })
    end
    if book.time_line then
        y = y + t:space(1)
        y = text(nodes, t, { id = "time_left", text = book.time_line, style = "body", x = x, y = y, w = w, max_lines = 2 })
    end
    if book.detail_line and book.detail_line ~= "" then
        y = y + t:space(1)
        y = text(nodes, t, { id = "detail", text = book.detail_line, style = "caption", color = "secondary", x = x, y = y, w = w, max_lines = 2 })
    end
    return y
end

local function heroText(nodes, t, model, book, tx, ty, tw, a)
    -- rather than cut a long title mid-phrase, drop its subtitle
    local title = book.title
    if book.short_title and estLines(t, title, a.title_style, tw) > a.lines then title = book.short_title end
    ty = text(nodes, t, { id = "hero_title", text = title, style = a.title_style, x = tx, y = ty, w = tw, max_lines = a.lines })
    if book.authors and book.authors ~= "" then
        ty = ty + t:space(1)
        ty = text(nodes, t, { id = "hero_author", text = book.authors, style = "body", color = "secondary", x = tx, y = ty, w = tw, max_lines = a.lines > 2 and 2 or 1 })
    end
    ty = ty + t:space(a.lines > 2 and 4 or 3)
    local shown = a.detail and book or setmetatable({ detail_line = false }, { __index = book })
    return progressBlock(nodes, t, shown, model.state == "reading", tx, ty, tw)
end

-- From most generous to most compact; the first one that fits is used.
local HERO_VARIANTS = {
    { cover = 1, lines = 3, title_style = "headline", detail = true },
    { cover = 1, lines = 2, title_style = "headline", detail = true },
    { cover = 0.85, lines = 2, title_style = "headline", detail = false },
    { cover = 0.75, lines = 2, title_style = "title", detail = false },
    { cover = 0.6, lines = 2, title_style = "title", detail = false },
}

--- Lays out the hero card. Returns its bottom edge and whether it fits `max_h`.
local function hero(nodes, t, model, x, y, w, cover_w, max_h)
    local book = model.hero
    local chosen, chosen_nodes, bottom, fits
    for _i, a in ipairs(HERO_VARIANTS) do
        local trial = {}
        local cover_h = t:coverHeight(math.floor(cover_w * a.cover))
        if max_h then cover_h = math.min(cover_h, max_h) end
        local cw = math.floor(cover_h / 1.5)
        local tx = x + cw + t.gutter
        local text_bottom = heroText(trial, t, model, book, tx, y, w - cw - t.gutter, a)
        bottom = math.max(y + cover_h, text_bottom)
        chosen, chosen_nodes = { w = cw, h = cover_h }, trial
        fits = not max_h or bottom - y <= max_h
        if fits then break end
    end
    nodes[#nodes + 1] = { kind = "cover", id = "hero_cover", x = x, y = y, w = chosen.w, h = chosen.h, book = book }
    for _i, n in ipairs(chosen_nodes) do nodes[#nodes + 1] = n end
    nodes[#nodes + 1] = { kind = "tap", id = "hero_tap", x = x, y = y, w = w, h = bottom - y, action = { type = "open", file = book.file } }
    return bottom, fits
end

local function shelfCell(t, item_w)
    local cover_h = t:coverHeight(math.floor(item_w * 0.86))
    return cover_h, cover_h + t:space(2) + 2 * t.type.caption.line + t.type.micro.line
end
Layout.shelfCell = shelfCell

local function shelf(nodes, t, books, x, y, w, cols, max_rows, max_h)
    if #books == 0 then return y end
    local item_w = math.floor((w - (cols - 1) * t.gutter) / cols)
    local cover_h = shelfCell(t, item_w)
    local caption = t.type.caption
    local meta = t.type.micro
    local cell_h = cover_h + t:space(2) + 2 * caption.line + meta.line
    -- shrink the covers rather than overflow the screen
    if max_h and cell_h > max_h then
        local scale = (max_h - t:space(2) - 2 * caption.line - meta.line) / cover_h
        if scale < 0.6 then return y end
        cover_h = math.floor(cover_h * scale)
        cell_h = cover_h + t:space(2) + 2 * caption.line + meta.line
    end
    local cover_w = math.floor(cover_h / 1.5)
    for i, book in ipairs(books) do
        local row = math.floor((i - 1) / cols)
        if row >= max_rows then break end
        local col = (i - 1) % cols
        local cx = x + col * (item_w + t.gutter)
        local cy = y + row * (cell_h + t:space(3))
        nodes[#nodes + 1] = { kind = "cover", id = "shelf_cover_" .. i, x = cx + math.floor((item_w - cover_w) / 2), y = cy, w = cover_w, h = cover_h, book = book }
        local ty = cy + cover_h + t:space(2)
        ty = text(nodes, t, { id = "shelf_title_" .. i, text = book.short_title or book.title, style = "caption", x = cx, y = ty, w = item_w, max_lines = 2, lines = 2 })
        if book.shelf_meta then
            text(nodes, t, { id = "shelf_meta_" .. i, text = book.shelf_meta, style = "micro", color = "secondary", x = cx, y = ty, w = item_w, lines = 1 })
        end
        nodes[#nodes + 1] = { kind = "tap", id = "shelf_tap_" .. i, x = cx, y = cy, w = item_w, h = cell_h, action = { type = "open", file = book.file } }
    end
    local rows = math.min(max_rows, math.ceil(#books / cols))
    return y + rows * cell_h + (rows - 1) * t:space(3)
end

local function navBar(nodes, t, copy, bottom)
    local items = copy.nav or {}
    local h = t.touch
    local y = bottom - h
    nodes[#nodes + 1] = { kind = "rule", id = "nav_rule", x = t.margin, y = y, w = t.content_width, h = t.hairline, color = "hairline" }
    local n = #items
    if n == 0 then return y end
    local slot = t.content_width / n
    for i, item in ipairs(items) do
        local sx = math.floor(t.margin + (i - 1) * slot)
        local style = t.type.caption
        nodes[#nodes + 1] = {
            kind = "text", id = "nav_" .. item.id, x = sx, y = y + math.floor((h - style.line) / 2), w = math.floor(slot), h = style.line,
            text = item.label, style = "caption", color = "text", max_lines = 1, align = "center",
        }
        nodes[#nodes + 1] = { kind = "tap", id = "nav_tap_" .. item.id, x = sx, y = y, w = math.floor(slot), h = h, action = { type = "nav", target = item.id } }
    end
    return y
end

--[[--
@tparam table t     Theme
@tparam table model Context.build() result, with display strings filled in by the caller:
  hero.progress_line, hero.time_line, hero.detail_line, shelf[i].shelf_meta
@tparam table copy  { status_left, status_right, hero_label, shelf_label, empty_title, empty_body, nav = { {id, label} } }
@treturn table nodes
]]
function Layout.home(t, model, copy)
    local nodes = {}
    local x, w = t.margin, t.content_width
    local top = t:space(3)

    -- status line: the only part that repaints (once a minute)
    local cap = t.type.caption
    nodes[#nodes + 1] = { kind = "text", id = "status_left", x = x, y = top, w = math.floor(w * 0.6), h = cap.line,
        text = copy.status_left or "", style = "caption", color = "secondary", max_lines = 1, align = "left" }
    nodes[#nodes + 1] = { kind = "text", id = "status_right", x = x + math.floor(w * 0.6), y = top, w = w - math.floor(w * 0.6), h = cap.line,
        text = copy.status_right or "", style = "caption", color = "secondary", max_lines = 1, align = "right" }
    local y = top + cap.line + t:space(6)

    local nav_top = navBar(nodes, t, copy, t.height - t:space(2))
    local room_bottom = nav_top - t:space(4)

    if model.state == "empty" or not model.hero then
        y = text(nodes, t, { id = "empty_title", text = copy.empty_title or "", style = "headline", x = x, y = y + t:space(8), w = w, max_lines = 2 })
        text(nodes, t, { id = "empty_body", text = copy.empty_body or "", style = "body", color = "secondary", x = x, y = y + t:space(2), w = math.min(w, t:span(5)), max_lines = 4 })
        return nodes
    end

    local room = room_bottom - y
    local label_h = t.type.micro.line + t:space(3)

    if t.landscape then
        -- hero on the wider left part, shelf as a grid on the right
        local left_w = t:span(5)
        local right_x = x + left_w + t.gutter * 2
        local right_w = w - left_w - t.gutter * 2
        local hy = sectionLabel(nodes, t, copy.hero_label or "", x, y, left_w) + t:space(3)
        hero(nodes, t, model, x, hy, left_w, t:span(2), room_bottom - hy)
        if #model.shelf > 0 then
            local sy = sectionLabel(nodes, t, copy.shelf_label or "", right_x, y, right_w) + t:space(3)
            local cols = 2
            local item_w = math.floor((right_w - t.gutter) / cols)
            local _c, cell = shelfCell(t, item_w)
            local rows = math.max(1, math.floor((room_bottom - sy + t:space(3)) / (cell + t:space(3))))
            shelf(nodes, t, model.shelf, right_x, sy, right_w, cols, rows, room_bottom - sy)
        end
        return nodes
    end

    -- portrait: fit the hero and at least one row of the shelf. On small
    -- screens, tighten the gaps first, then drop the hero's detail line,
    -- then let the shelf covers shrink (down to 70 %).
    local cols = t.columns >= 8 and 5 or 4
    local item_w = math.floor((w - (cols - 1) * t.gutter) / cols)
    local _c, cell = shelfCell(t, item_w)
    local cover_w = math.floor(math.max(t:span(2), w * 0.34))
    local hero_y = y + label_h
    local plan
    if #model.shelf > 0 then
        for _i, gap in ipairs({ 6, 4, 3 }) do
            local shelf_min = t:space(gap) + t.hairline + t:space(math.min(gap, 4)) + label_h
                + math.floor(cell - 0.3 * t:coverHeight(math.floor(item_w * 0.86)))
            local _b, fits = hero({}, t, model, x, hero_y, w, cover_w, room - label_h - shelf_min)
            if fits then
                plan = { gap = gap, hero_max = room - label_h - shelf_min }
                break
            end
        end
    end

    y = sectionLabel(nodes, t, copy.hero_label or "", x, y, w) + t:space(3)
    y = hero(nodes, t, model, x, y, w, cover_w, plan and plan.hero_max or (room - label_h))

    if plan then
        y = y + t:space(plan.gap)
        nodes[#nodes + 1] = { kind = "rule", id = "shelf_rule", x = x, y = y, w = w, h = t.hairline, color = "hairline" }
        y = y + t.hairline + t:space(math.min(plan.gap, 4))
        y = sectionLabel(nodes, t, copy.shelf_label or "", x, y, w) + t:space(3)
        -- big screens get a second row when it fits
        local rows = math.max(1, math.floor((room_bottom - y + t:space(3)) / (cell + t:space(3))))
        shelf(nodes, t, model.shelf, x, y, w, cols, math.min(rows, 2), room_bottom - y)
    end
    return nodes
end

--- Checks a layout for overlaps and overflow; returns a list of problems.
function Layout.check(t, nodes)
    local problems = {}
    for _i, n in ipairs(nodes) do
        if n.kind ~= "tap" then
            if n.x < 0 or n.y < 0 or n.x + n.w > t.width + 0.5 or n.y + n.h > t.height + 0.5 then
                problems[#problems + 1] = string.format("%s (%s) leaves the screen", n.id or "?", n.kind)
            end
        end
    end
    for i = 1, #nodes do
        local a = nodes[i]
        if a.kind == "text" or a.kind == "cover" then
            for j = i + 1, #nodes do
                local b = nodes[j]
                if (b.kind == "text" or b.kind == "cover")
                    and a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h then
                    problems[#problems + 1] = string.format("%s overlaps %s", a.id or "?", b.id or "?")
                end
            end
        end
    end
    return problems
end

return Layout
