--[[--
The reader's bars: what a tap at the top or bottom of a page shows,
instead of KOReader's menus. The page stays in view between them.

Top bar
  a handle to pull down the quick controls
  ‹ Home · Aa (Text & page) · contents · bookmarks · search · ⋮ (KOReader's menu)
  the book's title
Bottom bar
  the chapter, "Page 80 of 197 · 40%"
  |◀ previous chapter · a slider with the chapters marked · next chapter ▶|
  "Back to page 91" after a jump

Pure Lua: ChromeLayout.layout(t, state, copy) -> nodes, { top_h, bottom_y }

state { title, chapter, page_label, total_label, percent (0..1), ticks = {0..1},
        can_prev, can_next, back_label, bookmarked }

Actions: { type = "home" | "panel" | "toc" | "bookmarks" | "bookmark" | "search" |
  "menu" | "controls" | "prev_chapter" | "next_chapter" | "back" | "close" }
  and { type = "seek", x0, x1 } for the slider.
]]

local ChromeLayout = {}

local function textNode(nodes, t, s)
    s.kind = "text"
    s.h = s.h or t.type[s.style].line
    s.max_lines = 1
    nodes[#nodes + 1] = s
    return s
end

local function iconButton(nodes, t, id, name, x, y, size, action, kind)
    local icon = math.floor(t:mm(5))
    nodes[#nodes + 1] = { kind = kind or "icon", id = id, name = name, x = x + math.floor((size - icon) / 2),
        y = y + math.floor((size - icon) / 2), w = icon, h = icon, color = "text" }
    nodes[#nodes + 1] = { kind = "tap", id = id .. "_tap", x = x, y = y, w = size, h = size, action = action }
end

function ChromeLayout.layout(t, state, copy)
    local nodes = {}
    local x, w = t.margin, t.width - 2 * t.margin
    -- the bars use the screen's width, not the reading column: they are tools
    x = math.floor(t:mm(4))
    w = t.width - 2 * x

    -- top bar ---------------------------------------------------------------
    local handle_h = math.floor(t:mm(4.5))
    local y = 0
    local hw = math.floor(t:mm(8))
    nodes[#nodes + 1] = { kind = "glyph", id = "handle", name = "chevron_down", x = math.floor((t.width - hw) / 2),
        y = y + math.floor(t:mm(1)), w = hw, h = handle_h - math.floor(t:mm(1)), color = "text" }
    nodes[#nodes + 1] = { kind = "tap", id = "handle_tap", x = math.floor((t.width - t.touch * 3) / 2), y = 0,
        w = t.touch * 3, h = handle_h, action = { type = "controls" } }
    y = y + handle_h

    local size = t.touch
    -- right: the tools, as KOReader's own icons
    local tools = {
        { "panel", "appbar.textsize" }, { "toc", "appbar.navigation" }, { "bookmarks", "bookmark" },
        { "search", "appbar.search" }, { "menu", "dots", "glyph" },
    }
    local rx = x + w - #tools * size
    for i, tool in ipairs(tools) do
        iconButton(nodes, t, "tool_" .. tool[1], tool[2], rx + (i - 1) * size, y, size, { type = tool[1] }, tool[3])
    end
    -- left: back home
    local icon = math.floor(t:mm(5))
    nodes[#nodes + 1] = { kind = "icon", id = "home_icon", name = "chevron.left", x = x - math.floor(icon * 0.25),
        y = y + math.floor((size - icon) / 2), w = icon, h = icon, color = "text" }
    local label_w = math.max(0, rx - x - icon - t:space(2))
    if t.landscape then label_w = math.min(label_w, t.touch * 2) end
    textNode(nodes, t, { id = "home_label", x = x + icon, y = y + math.floor((size - t.type.body.line) / 2), w = label_w,
        text = copy.home or "", style = "body" })
    nodes[#nodes + 1] = { kind = "tap", id = "home_tap", x = 0, y = y, w = math.min(rx, x + icon + t:space(1) + t.touch * 2), h = size,
        action = { type = "home" } }
    if t.landscape then
        -- short screens: the title shares the toolbar row
        local tx = x + icon + t.touch * 2 + t:space(1)
        textNode(nodes, t, { id = "book_title", x = tx, y = y + math.floor((size - t.type.label.line) / 2),
            w = math.max(0, rx - tx - t:space(2)), text = state.title or "", style = "label", align = "center" })
        y = y + size + t:space(1)
    else
        y = y + size + t:space(1)
        nodes[#nodes + 1] = { kind = "rule", id = "top_rule_1", x = 0, y = y, w = t.width, h = t.hairline, color = "hairline" }
        y = y + t:space(2)
        textNode(nodes, t, { id = "book_title", x = x, y = y, w = w, text = state.title or "", style = "label" })
        y = y + t.type.label.line + t:space(2)
    end
    local top_h = y
    table.insert(nodes, 1, { kind = "box", id = "top_sheet", x = 0, y = 0, w = t.width, h = top_h, fill = "paper" })
    nodes[#nodes + 1] = { kind = "rule", id = "top_edge", x = 0, y = top_h, w = t.width, h = t.rule, color = "text" }

    -- bottom bar ------------------------------------------------------------
    local slider_h = t.touch
    local pad = t.landscape and t:space(2) or t:space(3)
    local bottom_h = pad + t.type.body.line + t.type.caption.line + t:space(1) + slider_h + pad
    local by = t.height - bottom_h
    local first_bottom = #nodes + 1
    nodes[#nodes + 1] = { kind = "box", id = "bottom_sheet", x = 0, y = by, w = t.width, h = bottom_h, fill = "paper" }
    nodes[#nodes + 1] = { kind = "rule", id = "bottom_edge", x = 0, y = by - t.rule, w = t.width, h = t.rule, color = "text" }
    local yy = by + pad
    textNode(nodes, t, { id = "chapter", x = x, y = yy, w = w, text = state.chapter or "", style = "body", align = "center" })
    yy = yy + t.type.body.line
    local pct = math.floor((state.percent or 0) * 100 + 0.5)
    local page_line = state.page_label and (copy.page_of or "Page %s of %s"):format(state.page_label, state.total_label or "?")
    textNode(nodes, t, { id = "page_line", x = x, y = yy, w = w, style = "caption", color = "secondary", align = "center",
        text = page_line and (page_line .. " · " .. pct .. "%") or (pct .. "%") })
    yy = yy + t.type.caption.line + t:space(1)
    iconButton(nodes, t, "prev_chapter", "chevron.first", x, yy, size, { type = "prev_chapter" })
    iconButton(nodes, t, "next_chapter", "chevron.last", x + w - size, yy, size, { type = "next_chapter" })
    if not state.can_prev then nodes[#nodes - 1].color = "secondary" end
    local sx, sw = x + size + t:space(1), w - 2 * size - t:space(2)
    nodes[#nodes + 1] = { kind = "slider", id = "progress", x = sx, y = yy, w = sw, h = slider_h,
        fraction = state.percent or 0, ticks = state.ticks }
    nodes[#nodes + 1] = { kind = "tap", id = "progress_tap", x = sx, y = yy, w = sw, h = slider_h,
        action = { type = "seek", x0 = sx, x1 = sx + sw } }
    for i = first_bottom, #nodes do
        if nodes[i].id == "next_chapter" and not state.can_next then nodes[i].color = "secondary" end
    end

    -- after a jump: the way back, floating above the bottom bar
    if state.back_label then
        local bw = math.floor(t:mm(36))
        local bh = t.touch
        local bx, byy = x + w - bw, by - t.rule - bh - t:space(2)
        nodes[#nodes + 1] = { kind = "box", id = "back_box", x = bx, y = byy, w = bw, h = bh, fill = "paper", border = "text",
            bw = math.max(2, t.hairline * 2), radius = math.floor(t:mm(1)) }
        textNode(nodes, t, { id = "back_label", x = bx + t:space(1), y = byy + math.floor((bh - t.type.caption.line) / 2),
            w = bw - t:space(2), text = state.back_label, style = "caption", align = "center" })
        nodes[#nodes + 1] = { kind = "tap", id = "back_tap", x = bx, y = byy, w = bw, h = bh, action = { type = "back" } }
    end
    return nodes, { top_h = top_h + t.rule, bottom_y = by - t.rule }
end

--- Fraction of the book for a tap at `px` on the slider.
function ChromeLayout.seekFraction(action, px)
    return math.max(0, math.min(1, (px - action.x0) / math.max(1, action.x1 - action.x0)))
end

return ChromeLayout
