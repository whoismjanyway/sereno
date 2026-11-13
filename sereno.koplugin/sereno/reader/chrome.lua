--[[--
The reader's bars: what a tap at the top or bottom of a page shows,
instead of KOReader's menus, laid out like the Kindle's. The page stays
in view between them.

Top bar
  a handle to pull down the quick controls
  ← Back to My Books          rotate · light · Aa · settings · …
Bottom bar
  PAGE 141 OF 3,255
  |<  ────(141)──────────────────  >|
  ☰ Chapter I.                         bookmarks · search
  "Back to page 91" after a jump

Pure Lua: ChromeLayout.layout(t, state, copy) -> nodes, { top_h, bottom_y }

state { title, chapter, page_label, total_label, percent (0..1), ticks = {0..1},
        can_prev, can_next, back_label, panel_open }

Actions: { type = "home" | "rotate" | "controls" | "panel" | "menu" | "more" |
  "toc" | "bookmarks" | "search" | "prev_chapter" | "next_chapter" | "back" }
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

local function iconButton(nodes, t, id, name, x, y, size, action, kind, color)
    local icon = math.floor(t:mm(5))
    nodes[#nodes + 1] = { kind = kind or "icon", id = id, name = name, x = x + math.floor((size - icon) / 2),
        y = y + math.floor((size - icon) / 2), w = icon, h = icon, color = color or "text" }
    nodes[#nodes + 1] = { kind = "tap", id = id .. "_tap", x = x, y = y, w = size, h = size, action = action }
end

function ChromeLayout.layout(t, state, copy)
    local nodes = {}
    -- the bars use the screen's width, not the reading column: they are tools
    local x = math.floor(t:mm(4))
    local w = t.width - 2 * x
    local size = t.touch

    -- top bar ---------------------------------------------------------------
    local handle_h = math.floor(t:mm(3.5))
    local hw = math.floor(t:mm(7))
    nodes[#nodes + 1] = { kind = "rule", id = "handle", x = math.floor((t.width - hw) / 2), y = math.floor(t:mm(1.2)),
        w = hw, h = math.max(2, t.hairline * 2), color = "hairline" }
    nodes[#nodes + 1] = { kind = "tap", id = "handle_tap", x = math.floor((t.width - t.touch * 3) / 2), y = 0,
        w = t.touch * 3, h = handle_h, action = { type = "controls" } }
    local y = handle_h

    -- right: rotate, light, Aa, settings, more
    local tools = { "rotate", "light", "panel", "menu", "more" }
    local rx = x + w - #tools * size
    for i, id in ipairs(tools) do
        local bx = rx + (i - 1) * size
        if id == "panel" then
            -- Aa in a circle, filled while the panel is open
            local d = math.floor(size * 0.82)
            local cx, cy = bx + math.floor((size - d) / 2), y + math.floor((size - d) / 2)
            nodes[#nodes + 1] = { kind = "circle", id = "tool_panel_circle", x = cx, y = cy, w = d, h = d,
                fill = state.panel_open and "text" or nil, border = "text", bw = math.max(2, t.hairline) }
            textNode(nodes, t, { id = "tool_panel", x = cx, y = cy + math.floor((d - t.type.label.line) / 2), w = d,
                text = "Aa", style = "label", align = "center", color = state.panel_open and "paper" or "text" })
            nodes[#nodes + 1] = { kind = "tap", id = "tool_panel_tap", x = bx, y = y, w = size, h = size, action = { type = "panel" } }
        elseif id == "rotate" then
            iconButton(nodes, t, "tool_rotate", "appbar.rotation", bx, y, size, { type = "rotate" })
        elseif id == "light" then
            iconButton(nodes, t, "tool_light", "sun", bx, y, size, { type = "controls" }, "glyph")
        elseif id == "menu" then
            iconButton(nodes, t, "tool_menu", "appbar.settings", bx, y, size, { type = "menu" })
        else
            iconButton(nodes, t, "tool_more", "dots_h", bx, y, size, { type = "more" }, "glyph")
        end
    end
    -- left: ← Back to My Books
    local icon = math.floor(t:mm(5))
    nodes[#nodes + 1] = { kind = "icon", id = "home_icon", name = "chevron.left", x = x - math.floor(icon * 0.25),
        y = y + math.floor((size - icon) / 2), w = icon, h = icon, color = "text" }
    local label_w = math.max(0, rx - x - icon - t:space(2))
    textNode(nodes, t, { id = "home_label", x = x + icon, y = y + math.floor((size - t.type.label.line) / 2), w = label_w,
        text = copy.home or "", style = "label" })
    nodes[#nodes + 1] = { kind = "tap", id = "home_tap", x = 0, y = y, w = math.max(x + icon + t.touch, rx - t:space(1)), h = size,
        action = { type = "home" } }
    y = y + size + t:space(1)
    local top_h = y
    table.insert(nodes, 1, { kind = "box", id = "top_sheet", x = 0, y = 0, w = t.width, h = top_h, fill = "paper" })
    nodes[#nodes + 1] = { kind = "rule", id = "top_edge", x = 0, y = top_h, w = t.width, h = t.hairline, color = "text" }

    -- bottom bar ------------------------------------------------------------
    local slider_h = t.touch
    local pad = t.landscape and t:space(1) or t:space(2)
    local bottom_h = pad + t.type.caption.line + t:space(1) + slider_h + t:space(1) + size + pad
    local by = t.height - bottom_h
    local first_bottom = #nodes + 1
    nodes[#nodes + 1] = { kind = "box", id = "bottom_sheet", x = 0, y = by, w = t.width, h = bottom_h, fill = "paper" }
    nodes[#nodes + 1] = { kind = "rule", id = "bottom_edge", x = 0, y = by - t.hairline, w = t.width, h = t.hairline, color = "text" }
    local yy = by + pad
    -- PAGE 141 OF 3,255
    local page_line = state.page_label and (copy.page_of or "Page %s of %s"):format(state.page_label, state.total_label or "?")
        or string.format("%d%%", math.floor((state.percent or 0) * 100 + 0.5))
    textNode(nodes, t, { id = "page_line", x = x, y = yy, w = w, style = "caption", align = "center",
        text = page_line:upper() })
    yy = yy + t.type.caption.line + t:space(1)
    -- |<  slider  >|
    iconButton(nodes, t, "prev_chapter", "chevron.first", x, yy, size, { type = "prev_chapter" })
    iconButton(nodes, t, "next_chapter", "chevron.last", x + w - size, yy, size, { type = "next_chapter" })
    local sx, sw = x + size, w - 2 * size
    nodes[#nodes + 1] = { kind = "slider", id = "progress", x = sx, y = yy, w = sw, h = slider_h,
        fraction = state.percent or 0, ticks = state.ticks, knob_label = state.page_label }
    nodes[#nodes + 1] = { kind = "tap", id = "progress_tap", x = sx, y = yy, w = sw, h = slider_h,
        action = { type = "seek", x0 = sx + math.floor(slider_h / 2), x1 = sx + sw - math.floor(slider_h / 2) } }
    yy = yy + slider_h + t:space(1)
    -- ☰ the chapter (to the contents) · bookmarks · search
    local ic = math.floor(t:mm(5))
    nodes[#nodes + 1] = { kind = "icon", id = "toc_icon", name = "appbar.navigation", x = x, y = yy + math.floor((size - ic) / 2),
        w = ic, h = ic, color = "text" }
    local cw = w - ic - t:space(2) - 2 * size
    textNode(nodes, t, { id = "chapter", x = x + ic + t:space(2), y = yy + math.floor((size - t.type.label.line) / 2), w = cw,
        text = state.chapter or copy.contents or "", style = "label" })
    nodes[#nodes + 1] = { kind = "tap", id = "toc_tap", x = 0, y = yy, w = x + ic + t:space(2) + cw, h = size, action = { type = "toc" } }
    iconButton(nodes, t, "bookmarks", "bookmark", x + w - 2 * size, yy, size, { type = "bookmarks" })
    iconButton(nodes, t, "search", "appbar.search", x + w - size, yy, size, { type = "search" })
    -- chapter skips that lead nowhere are dimmed
    for i = first_bottom, #nodes do
        local id = nodes[i].id
        if (id == "prev_chapter" and not state.can_prev) or (id == "next_chapter" and not state.can_next) then
            nodes[i].color = "secondary"
        end
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
    return nodes, { top_h = top_h + t.hairline, bottom_y = by - t.hairline }
end

--- Fraction of the book for a tap at `px` on the slider.
function ChromeLayout.seekFraction(action, px)
    return math.max(0, math.min(1, (px - action.x0) / math.max(1, action.x1 - action.x0)))
end

return ChromeLayout
