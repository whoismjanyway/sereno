--[[--
The "Send books over Wi-Fi" screen: the address to open in a browser, the
code to type there, the books received so far, and Stop.

Pure Lua: TransferLayout.layout(t, state, copy) -> nodes

state { phase = "connecting" | "running" | "error", url, code, message,
        received = { {name, bytes}... }, receiving = true while a book arrives }
copy  { title, connecting, open, code, keep, received, nothing_yet, receiving, stop }
Taps: { type = "close" } (Stop)
]]

local TransferLayout = {}

local function text(nodes, t, s)
    s.kind = "text"
    s.h = s.h or t.type[s.style].line * (s.max_lines or 1)
    s.max_lines = s.max_lines or 1
    nodes[#nodes + 1] = s
    return s.y + s.h
end

--- "2.4 MB", "830 KB"
function TransferLayout.size(bytes)
    bytes = bytes or 0
    if bytes >= 1024 * 1024 then return string.format("%.1f MB", bytes / (1024 * 1024)) end
    return string.format("%d KB", math.max(1, math.floor(bytes / 1024 + 0.5)))
end

function TransferLayout.layout(t, state, copy)
    local stop_x, stop_w = t.margin, t.content_width -- where Stop is centred
    local nodes = { { kind = "box", id = "sheet", x = 0, y = 0, w = t.width, h = t.height, fill = "paper" } }
    local x, w = t.margin, t.content_width
    local y = t:space(5)
    y = text(nodes, t, { id = "title", x = x, y = y, w = w, text = copy.title, style = "headline" }) + t:space(3)

    if state.phase == "connecting" then
        y = text(nodes, t, { id = "status", x = x, y = y, w = w, text = copy.connecting, style = "body",
            color = "secondary", max_lines = 3 }) + t:space(4)
    elseif state.phase == "error" then
        y = text(nodes, t, { id = "status", x = x, y = y, w = w, text = state.message or "", style = "body",
            max_lines = 5 }) + t:space(4)
    else
        -- landscape: the address and code on the left, what has arrived on the right
        local top, full_w = y, w
        if t.landscape then w = math.floor((full_w - t.gutter * 2) / 2) end
        -- 1. the address
        y = text(nodes, t, { id = "open_label", x = x, y = y, w = w, text = copy.open, style = "body",
            color = "secondary", max_lines = 2 }) + t:space(2)
        local pad = t:space(2)
        local bh = t.type.title.line + pad * 2
        nodes[#nodes + 1] = { kind = "box", id = "url_box", x = x, y = y, w = w, h = bh, radius = math.floor(t:mm(2)),
            border = "text", bw = t.hairline }
        text(nodes, t, { id = "url", x = x + pad, y = y + pad, w = w - pad * 2, text = state.url or "",
            style = "title", align = "center" })
        y = y + bh + t:space(3)
        -- 2. the code, large, so it reads across the room
        y = text(nodes, t, { id = "code_label", x = x, y = y, w = w, text = copy.code, style = "body",
            color = "secondary" }) + t:space(1)
        local digits = tostring(state.code or ""):gsub("(%d)", "%1 "):gsub(" $", "")
        y = text(nodes, t, { id = "code", x = x, y = y, w = w, text = digits, style = "display" }) + t:space(3)
        y = text(nodes, t, { id = "keep", x = x, y = y, w = w, text = copy.keep, style = "caption",
            color = "secondary", max_lines = 2 }) + t:space(3)

        -- 3. what has arrived
        if t.landscape then
            x, y = x + w + t.gutter * 2, top
            stop_x, stop_w = x, w
        end
        nodes[#nodes + 1] = { kind = "rule", id = "received_rule", x = x, y = y, w = w, h = t.hairline, color = "hairline" }
        y = y + t:space(2)
        local head = copy.received
        if state.receiving then head = head .. " · " .. copy.receiving end
        y = text(nodes, t, { id = "received_label", x = x, y = y, w = w, text = head, style = "label" }) + t:space(2)
        local list = state.received or {}
        local stop_top = t.height - t:space(5) - t.touch
        if #list == 0 then
            text(nodes, t, { id = "nothing", x = x, y = y, w = w, text = copy.nothing_yet, style = "caption",
                color = "secondary" })
        else
            local line = t.type.body.line + t:space(1)
            local room = math.max(1, math.floor((stop_top - t:space(3) - y) / line))
            local first = math.max(1, #list - room + 1)
            -- newest first
            local row = 0
            for i = #list, first, -1 do
                local it = list[i]
                local sw = math.floor(w * 0.25)
                text(nodes, t, { id = "file_" .. i, x = x, y = y + row * line, w = w - sw - t:space(2), text = it.name,
                    style = "body" })
                text(nodes, t, { id = "file_size_" .. i, x = x + w - sw, y = y + row * line, w = sw,
                    text = TransferLayout.size(it.bytes), style = "caption", color = "secondary", align = "right",
                    h = t.type.body.line })
                row = row + 1
            end
        end
    end

    -- Stop, at the bottom
    local bw = math.min(stop_w, math.floor(t:mm(45)))
    local bx = stop_x + math.floor((stop_w - bw) / 2)
    local by = t.height - t:space(5) - t.touch
    nodes[#nodes + 1] = { kind = "box", id = "stop_box", x = bx, y = by, w = bw, h = t.touch,
        radius = math.floor(t.touch / 2), border = "text", bw = math.max(2, t.hairline) }
    text(nodes, t, { id = "stop", x = bx, y = by + math.floor((t.touch - t.type.label.line) / 2), w = bw,
        text = copy.stop, style = "label", align = "center" })
    nodes[#nodes + 1] = { kind = "tap", id = "stop_tap", x = bx, y = by - t:space(1), w = bw, h = t.touch + t:space(2),
        action = { type = "close" } }
    return nodes
end

return TransferLayout
