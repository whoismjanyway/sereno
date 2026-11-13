--[[--
What every Sereno screen is drawn from: text measuring and wrapping, the
status header, the tab bar, covers, and the overlap check. Pure Lua: the
KOReader adapter (sereno/ui/painter.lua) turns nodes into pixels, so the
same layouts can be checked on many screen sizes without a device.

Node kinds:
  text   { x, y, w, h, text, style, color, max_lines, align }
  cover  { x, y, w, h, book }              -- real cover, or a typeset one
  box    { x, y, w, h, radius, fill, border, bw }   -- cards, chips, tiles
  rule   { x, y, w, h, color }
  bar    { x, y, w, h, fraction }          -- progress
  icon   { x, y, w, h, name, color }       -- KOReader's own icon set
  tap    { x, y, w, h, action }            -- invisible touch area

Everything sits on a grid and a 1.5 mm baseline unit; only the clock
line repaints. The home screen itself is sereno/home/dashboard.lua.
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

local function radius(t) return math.floor(t:mm(2) + 0.5) end

-- a cover with a soft offset shadow (a flat grey block: e-ink has no blur)
local function coverWithShadow(nodes, t, id, x, y, w, h, book)
    local off = math.max(2, math.floor(t:mm(0.8) + 0.5))
    nodes[#nodes + 1] = { kind = "box", id = id .. "_shadow", x = x + off, y = y + off, w = w, h = h, fill = "track", radius = 0 }
    nodes[#nodes + 1] = { kind = "cover", id = id, x = x, y = y, w = w, h = h, book = book }
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
