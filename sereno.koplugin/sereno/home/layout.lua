--[[--
Lays out the home screen as a flat list of positioned nodes. Pure Lua:
the KOReader adapter (sereno/home/homescreen.lua) turns nodes into widgets,
and tools/preview.lua turns them into SVG, so the same layout can be
checked on many screen sizes without a device.

Node kinds:
  text   { x, y, w, h, text, style, color, max_lines, align }
  cover  { x, y, w, h, book }              -- real cover, or a typeset one
  box    { x, y, w, h, radius, fill, border, bw }   -- cards, chips, tiles
  rule   { x, y, w, h, color }
  bar    { x, y, w, h, fraction }          -- progress
  icon   { x, y, w, h, name, color }       -- KOReader's own icon set
  tap    { x, y, w, h, action }            -- invisible touch area

Principles: one focal point (the book you are reading) in a card, short
facts as chips, the library at a glance in three tiles, a shelf of real
covers, and a tab bar with icons and words. Everything sits on a grid and
a 1.5 mm baseline unit; only the clock line repaints.
]]

local Layout = {}

-- Average glyph advance as a fraction of the font size. Only used when no
-- real measuring function is available (previews, tests); on a device the
-- theme carries `measure`, backed by KOReader's own text shaping.
Layout.ADVANCE = { serif = 0.56, sans = 0.55 }

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


local function textWidth(t, text_, style_name)
    if t.measure_width then return t.measure_width(text_, style_name) end
    local style = t.type[style_name]
    local adv = style.size * (style.font:find("Serif") and Layout.ADVANCE.serif or Layout.ADVANCE.sans)
    return math.ceil(charCount(text_ or "") * adv)
end
Layout.textWidth = textWidth

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

-- a small heading set in capitals, like a book's running head
local function sectionLabel(nodes, t, label, x, y, w, id)
    return text(nodes, t, { id = id or "label", text = (label or ""):upper(), style = "micro", color = "secondary", x = x, y = y, w = w, lines = 1 })
end

local function radius(t) return math.floor(t:mm(2) + 0.5) end

-- a cover with a soft offset shadow (a flat grey block: e-ink has no blur)
local function coverWithShadow(nodes, t, id, x, y, w, h, book)
    local off = math.max(2, math.floor(t:mm(0.8) + 0.5))
    nodes[#nodes + 1] = { kind = "box", id = id .. "_shadow", x = x + off, y = y + off, w = w, h = h, fill = "track", radius = 0 }
    nodes[#nodes + 1] = { kind = "cover", id = id, x = x, y = y, w = w, h = h, book = book }
end

--- Chips: short facts in rounded outlines, wrapped onto at most `max_rows`.
local function chips(nodes, t, list, x, y, w, max_rows)
    if not list or #list == 0 then return y end
    local style = t.type.caption
    local pad = t:space(2)
    local h = style.line + t:space(1)
    local gap = t:space(1)
    local cx, row = x, 1
    for i, label in ipairs(list) do
        local cw = math.min(w, textWidth(t, label, "caption") + 2 * pad)
        if cx > x and cx + cw > x + w then
            row = row + 1
            if row > max_rows then break end
            cx, y = x, y + h + gap
        end
        nodes[#nodes + 1] = { kind = "box", id = "chip_" .. i, x = cx, y = y, w = cw, h = h, radius = math.floor(h / 2), border = "hairline", bw = t.hairline }
        nodes[#nodes + 1] = { kind = "text", id = "chip_text_" .. i, x = cx + pad, y = y + math.floor((h - style.line) / 2), w = cw - 2 * pad, h = style.line,
            text = label, style = "caption", color = "text", max_lines = 1, align = "left" }
        cx = cx + cw + gap
    end
    return y + h
end

local function header(nodes, t, copy, x, y, w, compact)
    local title = t.type.title
    if compact then
        -- one line: date on the left, clock and battery on the right
        local cap = t.type.caption
        local right_w = math.floor(w * 0.4)
        nodes[#nodes + 1] = { kind = "text", id = "status_left", x = x, y = y, w = w - right_w, h = cap.line,
            text = copy.date or copy.status_left or "", style = "caption", color = "secondary", max_lines = 1, align = "left" }
        nodes[#nodes + 1] = { kind = "text", id = "status_right", x = x + w - right_w, y = y, w = right_w, h = cap.line,
            text = copy.status_right or "", style = "caption", color = "secondary", max_lines = 1, align = "right" }
        return y + cap.line
    end
    local cap = t.type.caption
    local right_w = math.floor(w * 0.4)
    nodes[#nodes + 1] = { kind = "text", id = "greeting", x = x, y = y, w = w - right_w, h = title.line,
        text = copy.greeting or "", style = "title", color = "text", max_lines = 1, align = "left" }
    nodes[#nodes + 1] = { kind = "text", id = "status_right", x = x + w - right_w, y = y + title.line - cap.line, w = right_w, h = cap.line,
        text = copy.status_right or "", style = "caption", color = "secondary", max_lines = 1, align = "right" }
    nodes[#nodes + 1] = { kind = "text", id = "status_left", x = x, y = y + title.line, w = w - right_w, h = cap.line,
        text = copy.date or copy.status_left or "", style = "caption", color = "secondary", max_lines = 1, align = "left" }
    return y + title.line + cap.line
end

-- From most generous to most compact; the first that fits is used.
local HERO_VARIANTS = {
    { cover = 1, lines = 3, chip_rows = 2 },
    { cover = 1, lines = 2, chip_rows = 2 },
    { cover = 0.85, lines = 2, chip_rows = 1 },
    { cover = 0.75, lines = 2, chip_rows = 1, title_style = "title" },
    { cover = 0.6, lines = 2, chip_rows = 1, title_style = "title" },
}

local function heroInner(nodes, t, model, copy, tx, ty, tw, a)
    local book = model.hero
    ty = sectionLabel(nodes, t, copy.hero_label, tx, ty, tw, "hero_label") + t:space(2)
    local style = a.title_style or "headline"
    local title = book.title
    if book.short_title and estLines(t, title, style, tw) > a.lines then title = book.short_title end
    ty = text(nodes, t, { id = "hero_title", text = title, style = style, x = tx, y = ty, w = tw, max_lines = a.lines })
    if book.authors and book.authors ~= "" then
        ty = ty + t:space(1)
        ty = text(nodes, t, { id = "hero_author", text = book.authors, style = "body", color = "secondary", x = tx, y = ty, w = tw, max_lines = 1 })
    end
    ty = ty + t:space(3)
    if model.state == "reading" and (book.percent or 0) > 0 then
        local cap = t.type.caption
        local pct_w = book.percent_label and (textWidth(t, book.percent_label, "caption") + t:space(2)) or 0
        local bar_h = math.max(t.rule, math.floor(t:mm(0.9) + 0.5))
        nodes[#nodes + 1] = { kind = "bar", id = "hero_bar", x = tx, y = ty + math.floor((cap.line - bar_h) / 2), w = tw - pct_w, h = bar_h, fraction = book.percent }
        if book.percent_label then
            nodes[#nodes + 1] = { kind = "text", id = "hero_percent", x = tx + tw - pct_w + t:space(2), y = ty, w = pct_w - t:space(2), h = cap.line,
                text = book.percent_label, style = "caption", color = "text", max_lines = 1, align = "right" }
        end
        ty = ty + cap.line + t:space(2)
    elseif book.next_line then
        ty = text(nodes, t, { id = "hero_next", text = book.next_line, style = "body", x = tx, y = ty, w = tw, max_lines = 2 }) + t:space(2)
    end
    return chips(nodes, t, book.chips, tx, ty, tw, a.chip_rows)
end

--- The hero card. Returns its bottom edge and whether it fits `max_h`.
local function heroCard(nodes, t, model, copy, x, y, w, cover_w, max_h)
    local pad = t:space(3)
    local chosen, bottom, fits
    for _i, a in ipairs(HERO_VARIANTS) do
        local trial = {}
        local inner_max = max_h and (max_h - 2 * pad) or nil
        local cover_h = t:coverHeight(math.floor(cover_w * a.cover))
        if inner_max then cover_h = math.min(cover_h, inner_max) end
        local cw = math.floor(cover_h / 1.5)
        coverWithShadow(trial, t, "hero_cover", x + pad, y + pad, cw, cover_h, model.hero)
        local tx = x + pad + cw + t.gutter
        local text_bottom = heroInner(trial, t, model, copy, tx, y + pad, x + w - pad - tx, a)
        bottom = math.max(y + pad + cover_h, text_bottom) + pad
        chosen = trial
        fits = not max_h or bottom - y <= max_h
        if fits then break end
    end
    nodes[#nodes + 1] = { kind = "box", id = "hero_card", x = x, y = y, w = w, h = bottom - y, radius = radius(t), border = "hairline", bw = t.hairline }
    for _i, n in ipairs(chosen) do nodes[#nodes + 1] = n end
    nodes[#nodes + 1] = { kind = "tap", id = "hero_tap", x = x, y = y, w = w, h = bottom - y, action = { type = "open", file = model.hero.file } }
    return bottom, fits
end

local function statsHeight(t)
    return t:space(2) + t.type.title.line + t.type.micro.line + t:space(2)
end

local function statsRow(nodes, t, stats, x, y, w)
    local n = #stats
    local gap = t.gutter
    local tw = math.floor((w - (n - 1) * gap) / n)
    local h = statsHeight(t)
    for i, s in ipairs(stats) do
        local sx = x + (i - 1) * (tw + gap)
        nodes[#nodes + 1] = { kind = "box", id = "stat_" .. i, x = sx, y = y, w = tw, h = h, radius = radius(t), border = "hairline", bw = t.hairline }
        nodes[#nodes + 1] = { kind = "text", id = "stat_value_" .. i, x = sx, y = y + t:space(2), w = tw, h = t.type.title.line,
            text = s.value, style = "title", color = "text", max_lines = 1, align = "center" }
        nodes[#nodes + 1] = { kind = "text", id = "stat_label_" .. i, x = sx, y = y + t:space(2) + t.type.title.line, w = tw, h = t.type.micro.line,
            text = (s.label or ""):upper(), style = "micro", color = "secondary", max_lines = 1, align = "center" }
    end
    return y + h
end

-- the same counts as one line, when the tiles don't fit
local function statsLine(nodes, t, stats, x, y, w)
    local parts = {}
    for _i, st in ipairs(stats) do
        if st.value ~= "0" then parts[#parts + 1] = st.value .. " " .. (st.label or ""):lower() end
    end
    return text(nodes, t, { id = "stats_line", text = table.concat(parts, "  ·  "), style = "caption", color = "secondary", x = x, y = y, w = w, lines = 1 })
end

local function shelfCell(t, item_w)
    local cover_h = t:coverHeight(math.floor(item_w * 0.86))
    return cover_h, cover_h + t:space(2) + 2 * t.type.caption.line + t.type.micro.line
end
Layout.shelfCell = shelfCell

-- how many shelf rows fit in `max_h`, and the cover scale that makes them fit
local function shelfRows(t, item_w, books, cols, max_rows, max_h, min_scale)
    local cover_h = shelfCell(t, item_w)
    local text_h = t:space(2) + 2 * t.type.caption.line + t.type.micro.line
    local wanted = math.min(max_rows, math.ceil(books / cols))
    for rows = wanted, 1, -1 do
        local per_row = (max_h - (rows - 1) * t:space(3)) / rows
        local scale = math.min(1, (per_row - text_h) / cover_h)
        if scale >= (rows > 1 and 0.7 or min_scale or 0.6) then return rows, scale end
    end
    return 0, 0
end
Layout.shelfRows = shelfRows

local function shelf(nodes, t, books, x, y, w, cols, max_rows, max_h)
    if #books == 0 then return y end
    local item_w = math.floor((w - (cols - 1) * t.gutter) / cols)
    local rows, scale = shelfRows(t, item_w, #books, cols, max_rows, max_h or math.huge)
    if rows == 0 then return y end
    local cover_h = math.floor(shelfCell(t, item_w) * scale)
    local text_h = t:space(2) + 2 * t.type.caption.line + t.type.micro.line
    local cell_h = cover_h + text_h
    local cover_w = math.floor(cover_h / 1.5)
    for i, book in ipairs(books) do
        local row = math.floor((i - 1) / cols)
        if row >= rows then break end
        local cx = x + ((i - 1) % cols) * (item_w + t.gutter)
        local cy = y + row * (cell_h + t:space(3))
        coverWithShadow(nodes, t, "shelf_cover_" .. i, cx, cy, cover_w, cover_h, book)
        if book.shelf_progress then
            local bh = math.max(2, math.floor(t:mm(0.6) + 0.5))
            local inset = math.floor(t:mm(1.2))
            nodes[#nodes + 1] = { kind = "bar", id = "shelf_bar_" .. i, x = cx + inset, y = cy + cover_h - bh - inset, w = cover_w - 2 * inset, h = bh, fraction = book.shelf_progress, inset = true }
        end
        local ty = cy + cover_h + t:space(2)
        ty = text(nodes, t, { id = "shelf_title_" .. i, text = book.short_title or book.title, style = "caption", x = cx, y = ty, w = item_w, max_lines = 2, lines = 2 })
        local meta_text = book.shelf_meta
        if book.authors and book.authors ~= "" and book.reason ~= "in_progress" and book.reason ~= "series" then
            meta_text = book.authors
        end
        if meta_text then
            text(nodes, t, { id = "shelf_meta_" .. i, text = meta_text, style = "micro", color = "secondary", x = cx, y = ty, w = item_w, lines = 1 })
        end
        nodes[#nodes + 1] = { kind = "tap", id = "shelf_tap_" .. i, x = cx, y = cy, w = item_w, h = cell_h, action = { type = "open", file = book.file } }
    end
    return y + rows * cell_h + (rows - 1) * t:space(3)
end

-- section heading with a "See all" link on the right
local function sectionHeader(nodes, t, copy, label, x, y, w)
    local lw = copy.see_all and textWidth(t, copy.see_all .. " ›", "caption") or 0
    local bottom = sectionLabel(nodes, t, label, x, y, w - lw - (lw > 0 and t.gutter or 0), "shelf_label")
    if copy.see_all then
        local cap = t.type.caption
        nodes[#nodes + 1] = { kind = "text", id = "see_all", x = x + w - lw, y = y + t.type.micro.line - cap.line, w = lw, h = cap.line,
            text = copy.see_all .. " ›", style = "caption", color = "text", max_lines = 1, align = "right" }
        local tap_w = math.max(lw, t.touch * 2)
        nodes[#nodes + 1] = { kind = "tap", id = "see_all_tap", x = x + w - tap_w, y = y + t.type.micro.line - t.touch, w = tap_w, h = t.touch,
            action = { type = "nav", target = "library" } }
    end
    return bottom
end

local function navHeight(t)
    return math.max(t.touch, math.floor(t:mm(5.5)) + t:space(1) + t.type.micro.line + t:space(2))
end

local function navBar(nodes, t, copy, bottom)
    local items = copy.nav or {}
    local h = navHeight(t)
    local y = bottom - h
    nodes[#nodes + 1] = { kind = "rule", id = "nav_rule", x = 0, y = y, w = t.width, h = t.hairline, color = "hairline" }
    local n = #items
    if n == 0 then return y end
    local slot = t.content_width / n
    local icon = math.floor(t:mm(5.5))
    local micro = t.type.micro
    local top = y + math.floor((h - icon - t:space(1) - micro.line) / 2)
    for i, item in ipairs(items) do
        local sx = math.floor(t.margin + (i - 1) * slot)
        local color = item.active and "text" or "secondary"
        if item.icon or item.glyph then
            nodes[#nodes + 1] = { kind = item.glyph and "glyph" or "icon", id = "nav_icon_" .. item.id, name = item.glyph or item.icon,
                x = sx + math.floor((slot - icon) / 2), y = top, w = icon, h = icon, color = color }
        end
        nodes[#nodes + 1] = { kind = "text", id = "nav_" .. item.id, x = sx, y = top + icon + t:space(1), w = math.floor(slot), h = micro.line,
            text = item.label, style = item.active and "micro_bold" or "micro", color = color, max_lines = 1, align = "center" }
        if item.active then
            local iw = math.floor(icon * 1.4)
            nodes[#nodes + 1] = { kind = "rule", id = "nav_active", x = sx + math.floor((slot - iw) / 2), y = y + t.hairline, w = iw, h = t.rule, color = "text" }
        end
        nodes[#nodes + 1] = { kind = "tap", id = "nav_tap_" .. item.id, x = sx, y = y, w = math.floor(slot), h = h,
            action = { type = "nav", target = item.id } }
    end
    return y
end

Layout.text = text
Layout.header = header
Layout.navBar = navBar
Layout.navHeight = navHeight
Layout.coverWithShadow = coverWithShadow
Layout.radius = radius

--[[--
@tparam table t     Theme
@tparam table model Context.build() result, with display strings filled in by Presenter.present
@tparam table copy  Presenter.present() result
@treturn table nodes
]]
function Layout.home(t, model, copy)
    local x, w = t.margin, t.content_width
    local empty = model.state == "empty" or not model.hero
    -- small screens (under ~13 cm tall) drop the greeting for a one-line header
    local compact_header = t.height / t.dpi * 25.4 < 135 and not empty
    local nodes = {}
    local y = header(nodes, t, copy, x, t:space(3), w, compact_header) + t:space(compact_header and 4 or 5)

    local nav_top = navBar(nodes, t, copy, t.height)
    local room_bottom = nav_top - t:space(3)

    if empty then
        local pad = t:space(4)
        local inner_w = w - 2 * pad
        local ty = text(nodes, t, { id = "empty_title", text = copy.empty_title or "", style = "headline", x = x + pad, y = y + pad, w = inner_w, max_lines = 2 })
        ty = text(nodes, t, { id = "empty_body", text = copy.empty_body or "", style = "body", color = "secondary", x = x + pad, y = ty + t:space(2), w = inner_w, max_lines = 4 })
        table.insert(nodes, #nodes - 1, { kind = "box", id = "empty_card", x = x, y = y, w = w, h = ty + pad - y, radius = radius(t), border = "hairline", bw = t.hairline })
        return nodes
    end

    local has_stats = copy.stats and #copy.stats > 0
    local label_h = t.type.micro.line + t:space(3)

    if t.landscape then
        local left_w = t:span(5)
        local right_x = x + left_w + t.gutter * 2
        local right_w = w - left_w - t.gutter * 2
        local stats_need = has_stats and (t:space(4) + statsHeight(t)) or 0
        local hb = heroCard(nodes, t, model, copy, x, y, left_w, t:span(2), room_bottom - y - stats_need)
        if has_stats and hb + t:space(4) + statsHeight(t) <= room_bottom then
            statsRow(nodes, t, copy.stats, x, hb + t:space(4), left_w)
        elseif has_stats and hb + t:space(3) + t.type.caption.line <= room_bottom then
            statsLine(nodes, t, copy.stats, x, hb + t:space(3), left_w)
        end
        if #model.shelf > 0 then
            local sy = sectionHeader(nodes, t, copy, copy.shelf_label, right_x, y, right_w) + t:space(3)
            -- as many columns as fit with covers at least ~22 mm wide
            local cols = math.max(2, math.floor((right_w + t.gutter) / (t:mm(22) + t.gutter)))
            shelf(nodes, t, model.shelf, right_x, sy, right_w, cols, 3, room_bottom - sy)
        end
        return nodes
    end

    -- portrait: card, library counts, then at least one shelf row. Try the
    -- richest arrangement first: tiles, then a one-line count, then none;
    -- tighter gaps; and the hero card goes compact by itself.
    local cols = t.columns >= 8 and 5 or 4
    local item_w = math.floor((w - (cols - 1) * t.gutter) / cols)
    local _c, cell = shelfCell(t, item_w)
    local cover_w = math.floor(math.max(t:span(2), w * 0.3))
    local room = room_bottom - y
    local full_cover = t:coverHeight(math.floor(item_w * 0.86))
    -- the shelf may shrink to 60 % of its size, but not to make room for counts:
    -- with counts shown, covers keep at least 75 %
    local function shelfMin(scale, rows)
        if #model.shelf == 0 then return 0 end
        local row_h = math.ceil(cell - (1 - scale) * full_cover)
        return label_h + rows * row_h + (rows - 1) * t:space(3) + 2
    end
    local stats_modes = has_stats and { "tiles", "line", "none" } or { "none" }
    -- big screens try two shelf rows first (covers at 75 % at least)
    local row_options = #model.shelf > cols and t.height / t.dpi * 25.4 > 180 and { 2, 1 } or { 1 }
    local plan
    for _r, rows in ipairs(row_options) do
        for _j, mode in ipairs(stats_modes) do
            for _i, gap in ipairs({ 5, 4, 3 }) do
                local stats_need = (mode == "tiles" and (t:space(gap) + statsHeight(t)))
                    or (mode == "line" and (t:space(gap) + t.type.caption.line)) or 0
                local shelf_min = shelfMin((mode == "none" and rows == 1) and 0.6 or 0.75, rows)
                local shelf_need = shelf_min > 0 and (t:space(gap) + shelf_min) or 0
                local _b, fits = heroCard({}, t, model, copy, x, y, w, cover_w, room - stats_need - shelf_need)
                if fits then
                    plan = { gap = gap, stats = mode, hero_max = room - stats_need - shelf_need }
                    break
                end
            end
            if plan then break end
        end
        if plan then break end
    end
    plan = plan or { gap = 3, stats = "none", hero_max = room }

    y = heroCard(nodes, t, model, copy, x, y, w, cover_w, plan.hero_max)
    if plan.stats == "tiles" then
        y = statsRow(nodes, t, copy.stats, x, y + t:space(plan.gap), w)
    elseif plan.stats == "line" then
        y = statsLine(nodes, t, copy.stats, x, y + t:space(plan.gap), w)
    end
    if #model.shelf > 0 then
        y = y + t:space(plan.gap)
        y = sectionHeader(nodes, t, copy, copy.shelf_label, x, y, w) + t:space(3)
        shelf(nodes, t, model.shelf, x, y, w, cols, 2, room_bottom - y)
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
        if a.kind == "text" or a.kind == "cover" or a.kind == "icon" then
            for j = i + 1, #nodes do
                local b = nodes[j]
                if (b.kind == "text" or b.kind == "cover" or b.kind == "icon")
                    and a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h then
                    problems[#problems + 1] = string.format("%s overlaps %s", a.id or "?", b.id or "?")
                end
            end
        end
    end
    return problems
end

return Layout
