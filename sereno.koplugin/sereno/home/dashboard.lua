--[[--
The home screen as a page of tiles:

  1:15                               ☀ wifi 82%  ⟳ 🔍
  Friday 23 October 2026                  [⚙] [▦] [+]
  ───────────────────────────────────────────────────
  ┌ Continue reading            › ┐ ┌ Library ┐
  │ [cover]  Pride and Prejudice  │ └─────────┘
  │          Jane Austen · 4%     │ ┌ Apps    ┐
  └───────────────────────────────┘ └─────────┘
  ┌ Up next          › ┐ ┌ Tasks            › ┐
  └────────────────────┘ └────────────────────┘
  ┌ Monterrey        › ┐ ┌ This week        › ┐
  │ ☁ 11°  Light rain  │ │ _ _ _ █ _ _ _      │
  └────────────────────┘ └────────────────────┘

Every tile shows something real: the book you're reading, the next one,
your own short task list, the weather where you said you are (only when
Wi-Fi is on), and the week's reading time from KOReader's statistics.

Pure Lua: Dashboard.layout(t, model, copy) -> nodes

model {
  hero = { file, title, authors, percent } or nil,
  up_next = { file, title, authors } or nil,
  tasks = { {text, done}... },
  weather = { place, temp, glyph, text } | { place } (no reading yet) | nil (no place set),
  week = { {secs, today}... } (7 days, oldest first), week_secs,
  wifi = true/false/nil, battery, charging, time, date
}
]]

local Layout = require("sereno/home/layout")

local Dashboard = {}

local text = Layout.text

local function one(nodes, t, s)
    s.kind = "text"
    s.h = s.h or t.type[s.style].line
    s.max_lines = 1
    s.color = s.color or "text"
    s.align = s.align or "left"
    nodes[#nodes + 1] = s
    return s.y + s.h
end

local function tap(nodes, id, x, y, w, h, action)
    nodes[#nodes + 1] = { kind = "tap", id = id, x = x, y = y, w = w, h = h, action = action }
end

-- a tile: an outlined box with an italic-feeling serif heading and a chevron
local function tile(nodes, t, id, x, y, w, h, heading, action, chevron)
    nodes[#nodes + 1] = { kind = "box", id = id .. "_tile", x = x, y = y, w = w, h = h, radius = Layout.radius(t),
        border = "hairline", bw = math.max(1, t.hairline) }
    local pad = t:space(2)
    local cy = y + pad
    if heading then
        local chev = chevron ~= false and math.floor(t:mm(4)) or 0
        one(nodes, t, { id = id .. "_heading", x = x + pad, y = cy, w = w - 2 * pad - chev, text = heading, style = "title_small" })
        if chev > 0 then
            nodes[#nodes + 1] = { kind = "icon", id = id .. "_chevron", name = "chevron.right", x = x + w - pad - chev,
                y = cy + math.floor((t.type.title_small.line - chev) / 2), w = chev, h = chev, color = "text" }
        end
        cy = cy + t.type.title_small.line + t:space(1)
    end
    if action then tap(nodes, id .. "_tap", x, y, w, h, action) end
    return cy, pad
end

-- status line: the clock on the left; light, Wi-Fi, battery, refresh and search on the right
local function statusBar(nodes, t, model, copy, x, y, w)
    local h = t.touch
    local cap = t.type.caption
    nodes[#nodes + 1] = { kind = "text", id = "status_right", clock = "time", x = x, y = y + math.floor((h - cap.line) / 2),
        w = math.floor(w * 0.3), h = cap.line, text = model.time or "", style = "caption", color = "text", max_lines = 1,
        align = "left" }
    local ic = math.floor(t:mm(4.2))
    local items = {
        { "light", "sun", "glyph", { type = "controls" } },
    }
    if model.wifi ~= nil then
        items[#items + 1] = { "wifi", "wifi", "icon", { type = "wifi" }, model.wifi and "text" or "secondary" }
    end
    if model.battery then items[#items + 1] = { "battery", tostring(model.battery) .. "%" .. (model.charging and "+" or "") } end
    items[#items + 1] = { "refresh", "restart", "glyph", { type = "refresh" } }
    items[#items + 1] = { "search", "appbar.search", "icon", { type = "nav", target = "search" } }
    local rx = x + w
    for i = #items, 1, -1 do
        local it = items[i]
        if it[3] then
            rx = rx - h
            nodes[#nodes + 1] = { kind = it[3], id = "status_" .. it[1], name = it[2], x = rx + math.floor((h - ic) / 2),
                y = y + math.floor((h - ic) / 2), w = ic, h = ic, color = it[5] or "text" }
            tap(nodes, "status_" .. it[1] .. "_tap", rx, y, h, h, it[4])
        else
            local bw = Layout.textWidth(t, it[2], "caption") + t:space(2)
            rx = rx - bw
            one(nodes, t, { id = "status_" .. it[1], x = rx, y = y + math.floor((h - cap.line) / 2), w = bw, text = it[2],
                style = "caption", align = "center" })
        end
    end
    return y + h
end

-- date on the left; settings, apps and import as square buttons on the right
local function dateRow(nodes, t, copy, x, y, w)
    local b = math.floor(t.touch * 1.15)
    local gap = t:space(1)
    local buttons = {
        { "settings", "appbar.settings", "icon", { type = "settings" } },
        { "apps", "grid", "glyph", { type = "nav", target = "apps" } },
        { "add", "plus", "icon", { type = "nav", target = "import" } },
    }
    local bx = x + w - #buttons * b - (#buttons - 1) * gap
    -- the date large when it fits beside the buttons, smaller when not (6" screens, long month names)
    local dw = bx - x - t:space(2)
    local style = "title"
    for _i, st in ipairs({ "title", "title_small", "body" }) do
        style = st
        if Layout.textWidth(t, copy.date or "", st) <= dw then break end
    end
    one(nodes, t, { id = "date", x = x, y = y + math.floor((b - t.type[style].line) / 2), w = dw,
        text = copy.date or "", style = style == "title_small" and "title_small_upright" or style })
    local ic = math.floor(t:mm(4.5))
    for i, bt in ipairs(buttons) do
        local cx = bx + (i - 1) * (b + gap)
        nodes[#nodes + 1] = { kind = "box", id = "btn_" .. bt[1], x = cx, y = y, w = b, h = b, radius = math.floor(t:mm(1)),
            border = "hairline", bw = math.max(1, t.hairline) }
        nodes[#nodes + 1] = { kind = bt[3], id = "btn_" .. bt[1] .. "_icon", name = bt[2], x = cx + math.floor((b - ic) / 2),
            y = y + math.floor((b - ic) / 2), w = ic, h = ic, color = "text" }
        tap(nodes, "btn_" .. bt[1] .. "_tap", cx, y, b, b, bt[4])
    end
    return y + b
end

local function heroTile(nodes, t, model, copy, x, y, w, h)
    local hero = model.hero
    if not hero then
        local cy, pad = tile(nodes, t, "hero", x, y, w, h, copy.no_book, { type = "nav", target = "import" })
        text(nodes, t, { id = "hero_empty", x = x + pad, y = cy, w = w - 2 * pad, text = copy.no_book_body or "",
            style = "body", color = "secondary", max_lines = math.max(1, math.floor((y + h - pad - cy) / t.type.body.line)) })
        return
    end
    local cy, pad = tile(nodes, t, "hero", x, y, w, h, copy.continue_reading, { type = "open", file = hero.file })
    local room = y + h - pad - cy
    local cover_h = math.max(t.touch, room)
    local cover_w = math.floor(cover_h / 1.5)
    if cover_w > w * 0.42 then cover_w = math.floor(w * 0.42) cover_h = math.floor(cover_w * 1.5) end
    Layout.coverWithShadow(nodes, t, "hero_cover", x + pad, cy + math.floor((room - cover_h) / 2), cover_w, cover_h, hero)
    local tx = x + pad + cover_w + t:space(3)
    local tw = x + w - pad - tx
    -- title, author and progress, centred against the cover
    local title_lines = math.max(1, math.min(3, Layout.estimateLines(t, hero.title, "body", tw, 3)))
    local block = title_lines * t.type.body.line + t:space(1) + t.type.caption.line * 2
    local ty = cy + math.max(0, math.floor((room - block) / 2))
    ty = text(nodes, t, { id = "hero_title", x = tx, y = ty, w = tw, text = hero.title or "", style = "body", max_lines = title_lines })
    ty = ty + t:space(1)
    if hero.authors and hero.authors ~= "" then
        ty = one(nodes, t, { id = "hero_author", x = tx, y = ty, w = tw, text = hero.authors, style = "caption" })
    end
    if hero.percent_label then
        one(nodes, t, { id = "hero_percent", x = tx, y = ty, w = tw, text = hero.percent_label, style = "caption" })
    end
end

-- Library and Apps: a big icon over a word
local function iconTile(nodes, t, id, x, y, w, h, label, kind, name, action)
    tile(nodes, t, id, x, y, w, h, nil, action)
    local ic = math.floor(math.min(t:mm(6), h * 0.35))
    local block = ic + t:space(2) + t.type.title_small.line
    local iy = y + math.floor((h - block) / 2)
    nodes[#nodes + 1] = { kind = kind, id = id .. "_icon", name = name, x = x + math.floor((w - ic) / 2), y = iy, w = ic, h = ic,
        color = "text" }
    one(nodes, t, { id = id .. "_label", x = x + t:space(1), y = iy + ic + t:space(2), w = w - t:space(2), text = label,
        style = "title_small", align = "center" })
end

local function lines(t, cy, bottom, style)
    return math.max(0, math.floor((bottom - cy) / t.type[style].line))
end

local function upNextTile(nodes, t, model, copy, x, y, w, h)
    local book = model.up_next
    local cy, pad = tile(nodes, t, "next", x, y, w, h, copy.up_next, book and { type = "open", file = book.file }
        or { type = "nav", target = "library" })
    local bottom = y + h - pad
    if not book then
        one(nodes, t, { id = "next_empty", x = x + pad, y = cy, w = w - 2 * pad, text = copy.nothing_next, style = "body" })
        return
    end
    local n = lines(t, cy, bottom - (book.authors and t.type.caption.line or 0), "body")
    if n >= 1 then
        cy = text(nodes, t, { id = "next_title", x = x + pad, y = cy, w = w - 2 * pad, text = book.title or "", style = "body",
            max_lines = math.min(2, n) })
    end
    if book.authors and cy + t.type.caption.line <= bottom then
        one(nodes, t, { id = "next_author", x = x + pad, y = cy, w = w - 2 * pad, text = book.authors, style = "caption",
            color = "secondary" })
    end
end

local function tasksTile(nodes, t, model, copy, x, y, w, h)
    local cy, pad = tile(nodes, t, "tasks", x, y, w, h, copy.tasks, { type = "nav", target = "tasks" })
    local open = {}
    for _i, task in ipairs(model.tasks or {}) do if not task.done then open[#open + 1] = task end end
    if #open == 0 then
        one(nodes, t, { id = "tasks_empty", x = x + pad, y = cy, w = w - 2 * pad, text = copy.no_tasks, style = "body" })
        return
    end
    local n = lines(t, cy, y + h - pad, "body")
    local dot = math.floor(t:mm(1.3))
    for i = 1, math.min(n, #open) do
        local ly = cy + (i - 1) * t.type.body.line
        local label = open[i].text
        if i == n and #open > n then label = string.format(copy.more_tasks or "+%d more", #open - n + 1) end
        nodes[#nodes + 1] = { kind = "circle", id = "task_dot_" .. i, x = x + pad, y = ly + math.floor((t.type.body.line - dot) / 2),
            w = dot, h = dot, border = "text", bw = math.max(1, t.hairline) }
        one(nodes, t, { id = "task_" .. i, x = x + pad + dot + t:space(1), y = ly, w = w - 2 * pad - dot - t:space(1),
            text = label, style = "body" })
    end
end

local function weatherTile(nodes, t, model, copy, x, y, w, h)
    local wx = model.weather
    local heading = wx and wx.place or copy.weather
    local cy, pad = tile(nodes, t, "weather", x, y, w, h, heading, { type = "weather" })
    local bottom = y + h - pad
    if not wx then
        text(nodes, t, { id = "weather_hint", x = x + pad, y = cy, w = w - 2 * pad, text = copy.weather_set,
            style = "body", color = "secondary", max_lines = math.max(1, lines(t, cy, bottom, "body")) })
        return
    end
    if not wx.temp then
        text(nodes, t, { id = "weather_hint", x = x + pad, y = cy, w = w - 2 * pad, text = copy.weather_wait,
            style = "body", color = "secondary", max_lines = math.max(1, lines(t, cy, bottom, "body")) })
        return
    end
    -- the symbol and the temperature on one line, the sky in words under it
    local big = t.type.display.line
    local room = bottom - cy
    local style = room >= big + t.type.caption.line and "display" or "headline"
    local ic = math.floor(t.type[style].line * 0.8)
    local ly = cy + math.max(0, math.floor((room - t.type[style].line - t.type.caption.line) / 2))
    nodes[#nodes + 1] = { kind = "glyph", id = "weather_icon", name = wx.glyph or "cloud", x = x + pad,
        y = ly + math.floor((t.type[style].line - ic) / 2), w = ic, h = ic, color = "text" }
    one(nodes, t, { id = "weather_temp", x = x + pad + ic + t:space(2), y = ly, w = w - 2 * pad - ic - t:space(2),
        text = wx.temp, style = style })
    if wx.text and ly + t.type[style].line + t.type.caption.line <= bottom then
        one(nodes, t, { id = "weather_text", x = x + pad, y = ly + t.type[style].line, w = w - 2 * pad, text = wx.text,
            style = "caption" })
    end
end

local function weekTile(nodes, t, model, copy, x, y, w, h)
    local cy, pad = tile(nodes, t, "week", x, y, w, h, copy.this_week, { type = "nav", target = "stats" })
    local bottom = y + h - pad
    local cap = t.type.caption.line
    local chart_h = math.max(t:space(2), bottom - cap - t:space(1) - cy)
    local week = model.week or {}
    local n = 7
    local slot = (w - 2 * pad) / n
    local bw = math.max(3, math.floor(slot * 0.55))
    local max = 0
    for _i, d in ipairs(week) do if (d.secs or 0) > max then max = d.secs end end
    local base = cy + chart_h
    for i = 1, n do
        local d = week[i] or {}
        local bx = math.floor(x + pad + (i - 1) * slot + (slot - bw) / 2)
        local secs = d.secs or 0
        if secs > 0 and max > 0 then
            local bh = math.max(t.rule * 2, math.floor(chart_h * secs / max))
            nodes[#nodes + 1] = { kind = "box", id = "week_bar_" .. i, x = bx, y = base - bh, w = bw, h = bh,
                fill = "text" }
        else
            -- a dash for a day without reading
            nodes[#nodes + 1] = { kind = "rule", id = "week_bar_" .. i, x = bx, y = base - t.rule, w = bw, h = t.rule,
                color = d.today and "text" or "hairline" }
        end
    end
    one(nodes, t, { id = "week_total", x = x + pad, y = bottom - cap, w = w - 2 * pad, text = copy.week_total or "",
        style = "caption" })
end

--- The tiles' model from the home model (sereno/home/context), the dashboard source and the status line.
function Dashboard.view(model, dash, status)
    dash, status = dash or {}, status or {}
    local view = {
        hero = model.hero, up_next = model.up_next or (model.shelf or {})[1],
        tasks = dash.tasks, weather = dash.weather, week = dash.week, wifi = dash.wifi,
        time = status.time, battery = status.battery, charging = status.charging,
    }
    if view.up_next and type(view.up_next.authors) == "table" then
        view.up_next.authors = table.concat(view.up_next.authors, ", ")
    end
    return view
end

function Dashboard.layout(t, model, copy)
    local nodes = {}
    local x, w = t.margin, t.content_width
    -- the tiles use more of the screen than running text does
    if not t.landscape then
        x = math.floor(t:mm(4))
        w = t.width - 2 * x
    end
    local y = statusBar(nodes, t, model, copy, x, t:space(1), w)
    y = dateRow(nodes, t, copy, x, y + t:space(1), w) + t:space(2)
    nodes[#nodes + 1] = { kind = "rule", id = "date_rule", x = x, y = y, w = w, h = t.hairline, color = "hairline" }
    y = y + t:space(3)
    local gap = t:space(2)
    local bottom = t.height - t:space(3)

    if t.landscape then
        -- left: the book and the two shortcuts; right: the four tiles
        local lw = math.floor((w - gap) * 0.48)
        local rx, rw = x + lw + gap, w - lw - gap
        local room = bottom - y
        local hero_h = math.floor((room - gap) * 0.62)
        heroTile(nodes, t, model, copy, x, y, lw, hero_h)
        local sy, sh = y + hero_h + gap, room - hero_h - gap
        local half = math.floor((lw - gap) / 2)
        iconTile(nodes, t, "library", x, sy, half, sh, copy.library, "icon", "appbar.filebrowser", { type = "nav", target = "library" })
        iconTile(nodes, t, "apps", x + half + gap, sy, lw - half - gap, sh, copy.apps, "glyph", "grid", { type = "nav", target = "apps" })
        local th = math.floor((room - gap) / 2)
        local cw = math.floor((rw - gap) / 2)
        upNextTile(nodes, t, model, copy, rx, y, cw, th)
        tasksTile(nodes, t, model, copy, rx + cw + gap, y, rw - cw - gap, th)
        weatherTile(nodes, t, model, copy, rx, y + th + gap, cw, room - th - gap)
        weekTile(nodes, t, model, copy, rx + cw + gap, y + th + gap, rw - cw - gap, room - th - gap)
        return nodes
    end

    local room = bottom - y - 2 * gap
    local ha = math.floor(room * 0.38)
    local hb = math.floor(room * 0.29)
    local hc = room - ha - hb
    -- row 1: the book (two thirds), Library and Apps stacked
    local side = math.floor((w - gap) * 0.3)
    local hw = w - side - gap
    heroTile(nodes, t, model, copy, x, y, hw, ha)
    local small = math.floor((ha - gap) / 2)
    iconTile(nodes, t, "library", x + hw + gap, y, side, small, copy.library, "icon", "appbar.filebrowser",
        { type = "nav", target = "library" })
    iconTile(nodes, t, "apps", x + hw + gap, y + small + gap, side, ha - small - gap, copy.apps, "glyph", "grid",
        { type = "nav", target = "apps" })
    y = y + ha + gap
    -- rows 2 and 3: two tiles each
    local cw = math.floor((w - gap) / 2)
    upNextTile(nodes, t, model, copy, x, y, cw, hb)
    tasksTile(nodes, t, model, copy, x + cw + gap, y, w - cw - gap, hb)
    y = y + hb + gap
    weatherTile(nodes, t, model, copy, x, y, cw, hc)
    weekTile(nodes, t, model, copy, x + cw + gap, y, w - cw - gap, hc)
    return nodes
end

return Dashboard
