--[[--
Quick controls: a sheet pulled down from the top edge, on the home screen,
in the library and while reading. Round buttons for what you reach for
most (Wi-Fi, night mode, the light, rotation, restart, sleep), sliders for
brightness and warmth, and the way into KOReader's own menus.

Pure Lua: ControlsLayout.layout(t, state, copy) -> nodes, bottom

state { time, battery, charging, wifi (true/false, nil without Wi-Fi), night,
        light_on, has_frontlight, brightness, brightness_min, brightness_max,
        has_warmth, warmth, warmth_max, can_rotate, can_restart, can_sleep }

Actions on tap nodes:
  { type = "toggle", id }            wifi, night, light, rotate, restart, sleep
  { type = "seek", id, x0, x1, min, max }   a tap on a slider track
  { type = "step", id, delta }       the − and + beside a slider
  { type = "koreader_menu" } { type = "files" } { type = "close" }
]]

local ControlsLayout = {}

local function textNode(nodes, t, s)
    s.kind = "text"
    s.h = s.h or t.type[s.style].line
    s.max_lines = 1
    nodes[#nodes + 1] = s
    return s
end

--- The buttons this device has, in order.
function ControlsLayout.buttons(state, copy)
    local list = {}
    local function add(id, label, kind, name, active)
        list[#list + 1] = { id = id, label = label, kind = kind, name = name, active = active }
    end
    if state.wifi ~= nil then add("wifi", copy.wifi, "icon", "wifi", state.wifi) end
    add("night", copy.night, "glyph", "moon", state.night)
    if state.has_frontlight then add("light", copy.light, "glyph", "sun", state.light_on) end
    if state.can_rotate ~= false then add("rotate", copy.rotate, "icon", "appbar.rotation", false) end
    if state.can_restart ~= false then add("restart", copy.restart, "glyph", "restart", false) end
    if state.can_sleep ~= false then add("sleep", copy.sleep, "glyph", "power", false) end
    return list
end

local function slider(nodes, t, id, label, value, min, max, x, y, w)
    textNode(nodes, t, { id = id .. "_label", x = x, y = y, w = w, text = label, style = "caption", align = "center" })
    y = y + t.type.caption.line + t:space(1)
    local h = t.touch
    local side = t.touch
    for _i, s in ipairs({ { "minus", "−", x, -1 }, { "plus", "+", x + w - side, 1 } }) do
        textNode(nodes, t, { id = id .. "_" .. s[1], x = s[3], y = y + math.floor((h - t.type.title.line) / 2), w = side,
            text = s[2], style = "title", align = "center" })
        nodes[#nodes + 1] = { kind = "tap", id = id .. "_" .. s[1] .. "_tap", x = s[3], y = y, w = side, h = h,
            action = { type = "step", id = id, delta = s[4] } }
    end
    local sx, sw = x + side + t:space(1), w - 2 * side - t:space(2)
    local fraction = max > min and (value - min) / (max - min) or 0
    nodes[#nodes + 1] = { kind = "slider", id = id .. "_slider", x = sx, y = y, w = sw, h = h, fraction = fraction }
    nodes[#nodes + 1] = { kind = "tap", id = id .. "_slider_tap", x = sx, y = y, w = sw, h = h,
        action = { type = "seek", id = id, x0 = sx, x1 = sx + sw, min = min, max = max } }
    return y + h
end

function ControlsLayout.layout(t, state, copy)
    local nodes = {}
    local x, w = t.margin, t.content_width
    local y = t:space(3)
    -- status: the clock large on the left, network and battery on the right
    textNode(nodes, t, { id = "time", x = x, y = y, w = math.floor(w / 2), text = state.time or "", style = "title" })
    local right = {}
    if state.wifi ~= nil then right[#right + 1] = state.wifi and copy.wifi_on or copy.wifi_off end
    if state.battery then right[#right + 1] = tostring(state.battery) .. "%" .. (state.charging and " +" or "") end
    textNode(nodes, t, { id = "status", x = x + math.floor(w / 2), y = y + t.type.title.line - t.type.caption.line,
        w = w - math.floor(w / 2), text = table.concat(right, " · "), style = "caption", color = "secondary", align = "right" })
    y = y + t.type.title.line + (t.landscape and t:space(2) or t:space(4))

    -- round buttons, evenly spread
    local buttons = ControlsLayout.buttons(state, copy)
    local n = #buttons
    local slot = w / math.max(1, n)
    local d = math.floor(math.min(t:mm(11), slot * 0.78))
    local glyph = math.floor(d * 0.5)
    for i, b in ipairs(buttons) do
        local sx = math.floor(x + (i - 1) * slot)
        local cx = sx + math.floor((slot - d) / 2)
        nodes[#nodes + 1] = { kind = "circle", id = "btn_" .. b.id, x = cx, y = y, w = d, h = d,
            fill = b.active and "track" or "paper", border = "text",
            bw = b.active and math.max(3, t.hairline * 3) or math.max(2, t.hairline) }
        local gx, gy = cx + math.floor((d - glyph) / 2), y + math.floor((d - glyph) / 2)
        nodes[#nodes + 1] = { kind = b.kind, id = "btn_" .. b.id .. "_icon", name = b.name, x = gx, y = gy, w = glyph, h = glyph,
            color = "text", bg = b.active and "track" or "paper" }
        textNode(nodes, t, { id = "btn_" .. b.id .. "_label", x = sx, y = y + d + t:space(1), w = math.floor(slot),
            text = b.label or "", style = b.active and "micro_bold" or "micro", align = "center" })
        nodes[#nodes + 1] = { kind = "tap", id = "btn_" .. b.id .. "_tap", x = sx, y = y - t:space(1), w = math.floor(slot),
            h = d + t:space(2) + t.type.micro.line, action = { type = "toggle", id = b.id } }
    end
    y = y + d + t:space(1) + t.type.micro.line + (t.landscape and t:space(2) or t:space(4))

    if state.has_frontlight then
        -- landscape screens are short: the two sliders sit side by side
        local side = t.landscape and state.has_warmth
        local sw = side and math.floor((w - t.gutter * 2) / 2) or w
        local b1 = slider(nodes, t, "brightness", (copy.brightness or "%d"):format(state.brightness or 0),
            state.brightness or 0, state.brightness_min or 0, state.brightness_max or 100, x, y, sw)
        if state.has_warmth then
            if side then
                slider(nodes, t, "warmth", (copy.warmth or "%d"):format(state.warmth or 0),
                    state.warmth or 0, 0, state.warmth_max or 100, x + sw + t.gutter * 2, y, sw)
            else
                b1 = slider(nodes, t, "warmth", (copy.warmth or "%d"):format(state.warmth or 0),
                    state.warmth or 0, 0, state.warmth_max or 100, x, b1 + t:space(3), w)
            end
        end
        y = b1 + t:space(3)
    end

    -- the way into KOReader's own menus and file browser
    local bh = t.touch
    local gap = t:space(2)
    local bw = math.floor((w - gap) / 2)
    for i, b in ipairs({ { "koreader_menu", copy.koreader_menu }, { "files", copy.files } }) do
        local bx = x + (i - 1) * (bw + gap)
        nodes[#nodes + 1] = { kind = "box", id = b[1] .. "_box", x = bx, y = y, w = bw, h = bh, radius = math.floor(bh / 2),
            border = "text", bw = t.hairline }
        textNode(nodes, t, { id = b[1], x = bx + t:space(1), y = y + math.floor((bh - t.type.caption.line) / 2),
            w = bw - t:space(2), text = b[2] or "", style = "caption", align = "center" })
        nodes[#nodes + 1] = { kind = "tap", id = b[1] .. "_tap", x = bx, y = y, w = bw, h = bh, action = { type = b[1] } }
    end
    y = y + bh + t:space(2)

    -- a handle to push the sheet back up
    local hw = math.floor(t:mm(8))
    nodes[#nodes + 1] = { kind = "glyph", id = "handle", name = "chevron_up", x = math.floor((t.width - hw) / 2), y = y,
        w = hw, h = math.floor(t:mm(4)), color = "text" }
    nodes[#nodes + 1] = { kind = "tap", id = "handle_tap", x = math.floor((t.width - t.touch * 2) / 2), y = y - t:space(1),
        w = t.touch * 2, h = math.floor(t:mm(4)) + t:space(2), action = { type = "close" } }
    y = y + math.floor(t:mm(4)) + t:space(2)

    table.insert(nodes, 1, { kind = "box", id = "sheet", x = 0, y = 0, w = t.width, h = y, fill = "paper" })
    nodes[#nodes + 1] = { kind = "rule", id = "sheet_edge", x = 0, y = y, w = t.width, h = t.rule, color = "text" }
    return nodes, y + t.rule
end

--- Value for a tap at `px` on a slider action.
function ControlsLayout.seekValue(action, px)
    local f = (px - action.x0) / math.max(1, action.x1 - action.x0)
    f = math.max(0, math.min(1, f))
    return math.floor(action.min + f * (action.max - action.min) + 0.5)
end

return ControlsLayout
