--[[--
Lays out the Library, Reading, Collections and Search tabs: a title row, a
grid of covers (folders and collections as labelled tiles), page turns
instead of scrolling, and the same tab bar as the home screen. Pure Lua,
like sereno/home/layout.lua, whose pieces it reuses.

  ShellLayout.browse(t, model, copy) -> nodes, paging { page, pages, per_page }
]]

local Layout = require("sereno/home/layout")

local ShellLayout = {}

local text, textWidth = Layout.text, Layout.textWidth

--- Columns for the grid: covers about 20–26 mm wide.
function ShellLayout.columns(t)
    local w_mm = t.content_width / t.dpi * 25.4
    if t.landscape then return math.max(5, math.floor(w_mm / 26)) end
    if w_mm < 85 then return 3 end
    if w_mm < 125 then return 4 end
    return 5
end

local function titleRow(nodes, t, model, copy, x, y, w)
    local title = t.type.headline
    local tx, tw = x, w
    local row_h = math.max(title.line, t.touch)
    local ty = y + math.floor((row_h - title.line) / 2)
    if model.back then
        local icon = math.floor(t:mm(5))
        nodes[#nodes + 1] = { kind = "icon", id = "back_icon", name = "chevron.left", x = x - math.floor(icon * 0.2),
            y = y + math.floor((row_h - icon) / 2), w = icon, h = icon, color = "text" }
        nodes[#nodes + 1] = { kind = "tap", id = "back_tap", x = 0, y = y, w = x + icon + t:space(2), h = row_h, action = model.back }
        tx, tw = x + icon + t:space(1), w - icon - t:space(1)
    end
    -- a pill on the right: the sort order, or nothing
    local pill_w = 0
    if copy.sort_label then
        local label = copy.sort_label .. " ▾"
        pill_w = textWidth(t, label, "caption") + 2 * t:space(2)
        local ph = t.type.caption.line + t:space(2)
        local px, py = x + w - pill_w, y + math.floor((row_h - ph) / 2)
        nodes[#nodes + 1] = { kind = "box", id = "sort_box", x = px, y = py, w = pill_w, h = ph, radius = math.floor(ph / 2),
            border = "hairline", bw = t.hairline }
        nodes[#nodes + 1] = { kind = "text", id = "sort", x = px + t:space(2), y = py + t:space(1), w = pill_w - 2 * t:space(2),
            h = t.type.caption.line, text = label, style = "caption", max_lines = 1, align = "center" }
        nodes[#nodes + 1] = { kind = "tap", id = "sort_tap", x = px - t:space(1), y = y, w = pill_w + t:space(1) + t.margin, h = row_h,
            action = { type = "sort" } }
        pill_w = pill_w + t:space(2)
    end
    nodes[#nodes + 1] = { kind = "text", id = "title", x = tx, y = ty, w = tw - pill_w, h = title.line,
        text = copy.title or "", style = "headline", max_lines = 1 }
    y = y + row_h
    if copy.subtitle and copy.subtitle ~= "" then
        y = text(nodes, t, { id = "subtitle", x = x, y = y, w = w, text = copy.subtitle, style = "caption",
            color = "secondary", lines = 1, max_lines = 1 })
    end
    return y
end

local function searchBox(nodes, t, copy, x, y, w)
    local h = t.touch + t:space(1)
    nodes[#nodes + 1] = { kind = "box", id = "search_box", x = x, y = y, w = w, h = h, radius = math.floor(h / 2),
        border = "text", bw = t.hairline }
    local icon = math.floor(t:mm(4.5))
    nodes[#nodes + 1] = { kind = "icon", id = "search_icon", name = "appbar.search", x = x + t:space(2),
        y = y + math.floor((h - icon) / 2), w = icon, h = icon, color = "text" }
    local has_query = copy.query and copy.query ~= ""
    nodes[#nodes + 1] = { kind = "text", id = "search_text", x = x + t:space(3) + icon, y = y + math.floor((h - t.type.body.line) / 2),
        w = w - icon - t:space(5), h = t.type.body.line, text = has_query and copy.query or copy.search_placeholder or "",
        style = "body", color = has_query and "text" or "secondary", max_lines = 1 }
    nodes[#nodes + 1] = { kind = "tap", id = "search_tap", x = x, y = y, w = w, h = h, action = { type = "search_input" } }
    return y + h
end

-- One grid cell: a cover (or a tile for folders and collections), a title
-- under it, and one line of detail. Returns the cell height.
local function cellHeight(t, item_w)
    local cover_h = t:coverHeight(item_w)
    return cover_h + t:space(1) + 2 * t.type.caption.line + t.type.micro.line
end

local function tile(nodes, t, id, x, y, w, h, glyph, label)
    nodes[#nodes + 1] = { kind = "box", id = id .. "_tile", x = x, y = y, w = w, h = h, radius = Layout.radius(t),
        border = "text", bw = t.hairline }
    local g = math.floor(math.min(w * 0.42, t:mm(9)))
    if glyph == "star" then
        nodes[#nodes + 1] = { kind = "icon", id = id .. "_glyph", name = "star.empty", x = x + math.floor((w - g) / 2),
            y = y + math.floor(h * 0.22), w = g, h = g, color = "text" }
    else
        nodes[#nodes + 1] = { kind = "glyph", id = id .. "_glyph", name = "folder", x = x + math.floor((w - g) / 2),
            y = y + math.floor(h * 0.22), w = g, h = g, color = "text" }
    end
    local ly = y + math.floor(h * 0.22) + g + t:space(2)
    local lines = math.max(1, math.min(3, math.floor((y + h - t:space(2) - ly) / t.type.caption.line)))
    nodes[#nodes + 1] = { kind = "text", id = id .. "_name", x = x + t:space(1), y = ly, w = w - t:space(2),
        h = lines * t.type.caption.line, text = label, style = "caption", max_lines = lines, align = "center" }
end

local function grid(nodes, t, items, copy, x, y, w, bottom, page)
    local cols = ShellLayout.columns(t)
    local gap_x = t.gutter
    local item_w = math.floor((w - (cols - 1) * gap_x) / cols)
    local natural = cellHeight(t, item_w)
    local gap_y = t:space(3)
    local captions = t:space(1) + 2 * t.type.caption.line + t.type.micro.line
    local avail = bottom - y
    -- as many rows as fit at full size, but at least two in portrait: covers
    -- get smaller rather than leave a single row on a small screen
    local rows = math.max(t.landscape and 1 or 2, math.floor((avail + gap_y) / (natural + gap_y)))
    local cell_h = math.min(natural, math.floor((avail - (rows - 1) * gap_y) / rows))
    if cell_h - captions < t:mm(14) and rows > 1 then
        rows = rows - 1
        cell_h = math.min(natural, math.floor((avail - (rows - 1) * gap_y) / rows))
    end
    local per_page = rows * cols
    local pages = math.max(1, math.ceil(#items / per_page))
    page = math.max(1, math.min(page or 1, pages))
    local first = (page - 1) * per_page
    local cover_h = cell_h - (t:space(1) + 2 * t.type.caption.line + t.type.micro.line)
    for k = 1, per_page do
        local item = items[first + k]
        if not item then break end
        local col, row = (k - 1) % cols, math.floor((k - 1) / cols)
        local cx = x + col * (item_w + gap_x)
        local cy = y + row * (cell_h + gap_y)
        local id = "cell_" .. k
        local cw = math.min(item_w, math.floor(cover_h * 2 / 3))
        local ix = cx + math.floor((item_w - cw) / 2)
        local action, detail
        if item.kind == "book" then
            Layout.coverWithShadow(nodes, t, id, ix, cy, cw, cover_h, item)
            if item.percent and item.percent > 0 and item.percent < 1 then
                local bh = math.max(3, math.floor(t:mm(1)))
                nodes[#nodes + 1] = { kind = "bar", id = id .. "_bar", x = ix + t:space(1), y = cy + cover_h - bh - t:space(1),
                    w = cw - t:space(2), h = bh, fraction = item.percent, inset = true }
            end
            action = { type = "open", file = item.file }
            if item.status == "complete" then detail = copy.finished
            elseif item.percent and item.percent > 0 then detail = string.format("%d%%", math.floor(item.percent * 100 + 0.5))
            else detail = item.authors end
            nodes[#nodes + 1] = { kind = "text", id = id .. "_title", x = cx, y = cy + cover_h + t:space(1), w = item_w,
                h = 2 * t.type.caption.line, text = item.title or "", style = "caption", max_lines = 2, align = "left" }
        else
            local is_coll = item.kind == "collection"
            tile(nodes, t, id, ix, cy, cw, cover_h, is_coll and "star" or "folder", item.link and (copy.collections or item.name) or item.name)
            action = (item.link and { type = "nav", target = "collections" })
                or (is_coll and { type = "collection", name = item.name }) or { type = "folder", path = item.path }
            if item.count then detail = (copy.count_books or "%d"):format(item.count) end
        end
        if detail and detail ~= "" then
            nodes[#nodes + 1] = { kind = "text", id = id .. "_detail", x = cx, y = cy + cover_h + t:space(1) + 2 * t.type.caption.line,
                w = item_w, h = t.type.micro.line, text = detail, style = "micro", color = "secondary", max_lines = 1 }
        end
        nodes[#nodes + 1] = { kind = "tap", id = id .. "_tap", x = cx, y = cy, w = item_w, h = cell_h, action = action }
    end
    return { page = page, pages = pages, per_page = per_page, rows = rows, cols = cols }
end

local function pager(nodes, t, copy, paging, x, y, w)
    if paging.pages <= 1 then return end
    local h = t.touch
    local label = (copy.page_of or "%d of %d"):format(paging.page, paging.pages)
    nodes[#nodes + 1] = { kind = "text", id = "pager", x = x + t.touch, y = y + math.floor((h - t.type.caption.line) / 2),
        w = w - 2 * t.touch, h = t.type.caption.line, text = label, style = "caption", color = "secondary",
        max_lines = 1, align = "center" }
    local icon = math.floor(t:mm(4.5))
    for _i, side in ipairs({ { "prev", -1, x, "chevron.left" }, { "next", 1, x + w - t.touch, "chevron.right" } }) do
        local active = (side[2] < 0 and paging.page > 1) or (side[2] > 0 and paging.page < paging.pages)
        nodes[#nodes + 1] = { kind = "icon", id = "pager_" .. side[1], name = side[4], x = side[3] + math.floor((t.touch - icon) / 2),
            y = y + math.floor((h - icon) / 2), w = icon, h = icon, color = active and "text" or "secondary" }
        if active then
            nodes[#nodes + 1] = { kind = "tap", id = "pager_" .. side[1] .. "_tap", x = side[3] - t:space(1), y = y,
                w = t.touch + t:space(2), h = h, action = { type = "page", delta = side[2] } }
        end
    end
end

--[[--
@tparam table t theme
@tparam table model sereno/shell/browse model, with state.page
@tparam table copy  strings: title, subtitle, sort_label, query, search_placeholder,
  empty, finished, count_books, page_of, nav
]]
function ShellLayout.browse(t, model, copy, page)
    local nodes = {}
    local x, w = t.margin, t.content_width
    -- the top strip: date on the left, clock and battery on the right, as on
    -- the home screen (and where the quick controls are pulled down from)
    local y = Layout.header(nodes, t, copy, x, t:space(3), w, true) + t:space(3)
    y = titleRow(nodes, t, model, copy, x, y, w) + t:space(3)
    if model.searchable then y = searchBox(nodes, t, copy, x, y, w) + t:space(4) end
    local nav_top = Layout.navBar(nodes, t, copy, t.height)
    local pager_h = t.touch
    local bottom = nav_top - t:space(2) - pager_h
    local paging = { page = 1, pages = 1, per_page = 0 }
    if #model.items == 0 then
        text(nodes, t, { id = "empty", x = x + t:space(4), y = y + t:space(6), w = w - t:space(8), text = copy.empty or "",
            style = "body", color = "secondary", align = "center", max_lines = 4 })
    else
        paging = grid(nodes, t, model.items, copy, x, y, w, bottom, page)
        pager(nodes, t, copy, paging, x, bottom + t:space(1), w)
    end
    return nodes, paging
end

--- A small card of a number and what it means.
local function statTile(nodes, t, id, x, y, w, h, value, label)
    nodes[#nodes + 1] = { kind = "box", id = id .. "_box", x = x, y = y, w = w, h = h, radius = Layout.radius(t),
        border = "hairline", bw = t.hairline }
    nodes[#nodes + 1] = { kind = "text", id = id .. "_value", x = x + t:space(1), y = y + t:space(2), w = w - t:space(2),
        h = t.type.title.line, text = value, style = w < t:mm(20) and "label" or "title", max_lines = 1, align = "center" }
    nodes[#nodes + 1] = { kind = "text", id = id .. "_label", x = x + t:space(1), y = y + t:space(2) + t.type.title.line,
        w = w - t:space(2), h = 2 * t.type.micro.line, text = label, style = "micro", color = "secondary", max_lines = 2,
        align = "center" }
end

--[[--
The Stats tab: the book you're reading, five numbers, the last seven days
as bars, and all-time totals. From KOReader's Reading statistics.
@tparam table model sereno/stats/stats.summarize() result
@tparam table copy  Presenter.stats() strings
]]
function ShellLayout.stats(t, model, copy)
    local nodes = {}
    local x, w = t.margin, t.content_width
    local y = Layout.header(nodes, t, copy, x, t:space(3), w, true) + t:space(3)
    y = titleRow(nodes, t, {}, copy, x, y, w) + t:space(3)
    Layout.navBar(nodes, t, copy, t.height)
    if model.empty then
        text(nodes, t, { id = "empty", x = x + t:space(4), y = y + t:space(6), w = w - t:space(8), text = copy.empty or "",
            style = "body", color = "secondary", align = "center", max_lines = 5 })
        return nodes
    end
    if model.book then
        y = text(nodes, t, { id = "book_label", text = (copy.book_label or ""):upper(), style = "micro", color = "secondary",
            x = x, y = y, w = w, lines = 1 }) + t:space(1)
        y = text(nodes, t, { id = "book_title", text = model.book.title or "", style = "title", x = x, y = y, w = w,
            max_lines = 1, lines = 1 }) + t:space(2)
        local bh = math.max(3, math.floor(t:mm(1.2)))
        nodes[#nodes + 1] = { kind = "bar", id = "book_bar", x = x, y = y, w = w, h = bh, fraction = model.book.percent or 0 }
        y = y + bh + t:space(2)
        y = text(nodes, t, { id = "book_line", text = copy.book_line or "", style = "caption", x = x, y = y, w = w,
            max_lines = 2 }) + t:space(4)
    end
    -- five numbers: one row on wide screens, three and two on small ones
    local cols = t.content_width / t.dpi * 25.4 >= 80 and 5 or 3
    local gap = cols == 5 and t:space(1) or t:space(2)
    local tw = math.floor((w - (cols - 1) * gap) / cols)
    local th = t:space(4) + t.type.title.line + 2 * t.type.micro.line
    for i, tl in ipairs(copy.tiles or {}) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        statTile(nodes, t, "tile_" .. i, x + col * (tw + gap), y + row * (th + gap), tw, th, tl.value, tl.label)
    end
    y = y + math.ceil(#(copy.tiles or {}) / cols) * (th + gap) + t:space(3)
    -- the last seven days, as bars
    local nav_top = t.height - Layout.navHeight(t)
    local chart_h = math.min(math.floor(t:mm(22)), nav_top - y - t:space(4) - t.type.micro.line * 3 - t.type.caption.line)
    if chart_h > t:mm(8) then
        y = text(nodes, t, { id = "week_label", text = (copy.week_label or ""):upper(), style = "micro", color = "secondary",
            x = x, y = y, w = w, lines = 1 }) + t:space(2)
        local n = #model.week
        local slot = w / n
        local bw = math.floor(slot * 0.5)
        for i, d in ipairs(model.week) do
            local fh = model.week_max > 0 and math.floor(chart_h * d.secs / model.week_max) or 0
            local bx = math.floor(x + (i - 1) * slot + (slot - bw) / 2)
            nodes[#nodes + 1] = { kind = "rule", id = "week_base_" .. i, x = bx, y = y + chart_h - t.hairline, w = bw,
                h = t.hairline, color = "hairline" }
            if fh > 0 then
                nodes[#nodes + 1] = { kind = "box", id = "week_bar_" .. i, x = bx, y = y + chart_h - fh, w = bw, h = fh,
                    fill = i == n and "text" or "secondary" }
            end
            nodes[#nodes + 1] = { kind = "text", id = "week_day_" .. i, x = math.floor(x + (i - 1) * slot), y = y + chart_h + t:space(1),
                w = math.floor(slot), h = t.type.micro.line, text = (copy.week_days or {})[i] or "", style = i == n and "micro_bold" or "micro",
                color = i == n and "text" or "secondary", max_lines = 1, align = "center" }
        end
        y = y + chart_h + t:space(1) + t.type.micro.line + t:space(3)
    end
    if copy.total_line and y + t.type.caption.line <= nav_top then
        text(nodes, t, { id = "total_line", text = copy.total_line, style = "caption", color = "secondary", x = x, y = y, w = w,
            lines = 1, max_lines = 1 })
    end
    return nodes
end

--[[--
The Import tab: ways to bring books in, through KOReader's own plugins
(calibre, OPDS), and the folder to copy books into with a cable.
@tparam table items { {id, icon or glyph, title, subtitle, available, info} }
]]
function ShellLayout.import(t, items, copy)
    local nodes = {}
    local x, w = t.margin, t.content_width
    local y = Layout.header(nodes, t, copy, x, t:space(3), w, true) + t:space(3)
    y = titleRow(nodes, t, {}, copy, x, y, w) + t:space(3)
    local nav_top = Layout.navBar(nodes, t, copy, t.height)
    local icon = math.floor(t:mm(6))
    for i, it in ipairs(items) do
        local pad = t:space(3)
        local tx = x + pad + icon + t:space(3)
        local tw = w - (tx - x) - pad - (it.info and 0 or math.floor(t:mm(5)))
        local sub_lines = 3
        local h = pad * 2 + t.type.label.line + t:space(1) + sub_lines * t.type.caption.line
        if y + h > nav_top - t:space(2) then
            sub_lines = 2
            h = pad * 2 + t.type.label.line + t:space(1) + sub_lines * t.type.caption.line
            if y + h > nav_top - t:space(2) then break end
        end
        local color = it.available == false and "secondary" or "text"
        nodes[#nodes + 1] = { kind = "box", id = "import_box_" .. i, x = x, y = y, w = w, h = h, radius = Layout.radius(t),
            border = it.info and "hairline" or "text", bw = t.hairline }
        nodes[#nodes + 1] = { kind = it.glyph and "glyph" or "icon", id = "import_icon_" .. i, name = it.glyph or it.icon,
            x = x + pad, y = y + pad, w = icon, h = icon, color = color }
        nodes[#nodes + 1] = { kind = "text", id = "import_title_" .. i, x = tx, y = y + pad, w = tw, h = t.type.label.line,
            text = it.title, style = "label", color = color, max_lines = 1 }
        nodes[#nodes + 1] = { kind = "text", id = "import_sub_" .. i, x = tx, y = y + pad + t.type.label.line + t:space(1), w = tw,
            h = sub_lines * t.type.caption.line, text = it.subtitle or "", style = "caption", color = "secondary",
            max_lines = sub_lines }
        if not it.info then
            local cw = math.floor(t:mm(4.5))
            nodes[#nodes + 1] = { kind = "icon", id = "import_chevron_" .. i, name = "chevron.right",
                x = x + w - pad - cw, y = y + math.floor((h - cw) / 2), w = cw, h = cw, color = color }
            nodes[#nodes + 1] = { kind = "tap", id = "import_tap_" .. i, x = x, y = y, w = w, h = h,
                action = { type = "import", id = it.id } }
        end
        y = y + h + t:space(3)
    end
    return nodes
end

return ShellLayout
