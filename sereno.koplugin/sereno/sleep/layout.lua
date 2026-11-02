--[[--
Sereno's sleep screen: the book you are reading, its cover large, its
title, and how far you are, like a book left on the table; with no book,
the Sereno mark. Drawn into an image that KOReader's own sleep screen
shows (its "random image from a folder" mode, pointed at Sereno's folder),
so the rest of KOReader's sleep screen options keep working unchanged.

Pure Lua: SleepLayout.layout(t, book, copy) -> nodes

book { file, title, authors, percent, page_now, page_total } or nil
copy { progress (e.g. "Page 68 of 179 · 38%"), date, logo (path of the mark) }
]]

local Layout = require("sereno/home/layout")

local SleepLayout = {}

function SleepLayout.layout(t, book, copy)
    local nodes = {}
    local x, w = t.margin, t.content_width
    nodes[#nodes + 1] = { kind = "box", id = "paper", x = 0, y = 0, w = t.width, h = t.height, fill = "paper" }
    local logo = math.floor(t:mm(9))
    local bottom = t.height - t:space(6)
    -- the mark and the date at the foot of the page, quietly
    nodes[#nodes + 1] = { kind = "image", id = "logo", file = copy.logo, x = math.floor((t.width - logo) / 2),
        y = bottom - logo - t.type.micro.line - t:space(1), w = logo, h = logo }
    nodes[#nodes + 1] = { kind = "text", id = "date", x = x, y = bottom - t.type.micro.line, w = w, h = t.type.micro.line,
        text = copy.date or "", style = "micro", color = "secondary", max_lines = 1, align = "center" }
    local foot = bottom - logo - t.type.micro.line - t:space(4)

    if not book then
        local big = math.floor(math.min(t:mm(36), w * 0.5))
        nodes[2].x, nodes[2].y, nodes[2].w, nodes[2].h = math.floor((t.width - big) / 2), math.floor(t.height * 0.32), big, big
        nodes[#nodes + 1] = { kind = "text", id = "name", x = x, y = nodes[2].y + big + t:space(3), w = w,
            h = t.type.display.line, text = "Sereno", style = "display", max_lines = 1, align = "center" }
        return nodes
    end

    -- text under the cover: title, author, progress
    local title_lines = 2
    local text_h = title_lines * t.type.headline.line + t:space(1) + t.type.body.line
        + t:space(4) + math.max(3, math.floor(t:mm(1))) + t:space(2) + t.type.caption.line
    local top = t:space(8)
    local cover_h = math.floor(math.min(t:coverHeight(math.floor(w * 0.62)), foot - top - text_h - t:space(5)))
    local cover_w = math.floor(cover_h * 2 / 3)
    local cx = math.floor((t.width - cover_w) / 2)
    Layout.coverWithShadow(nodes, t, "cover", cx, top, cover_w, cover_h, book)
    local y = top + cover_h + t:space(5)
    nodes[#nodes + 1] = { kind = "text", id = "title", x = x, y = y, w = w, h = title_lines * t.type.headline.line,
        text = book.title or "", style = "headline", max_lines = title_lines, align = "center" }
    y = y + title_lines * t.type.headline.line + t:space(1)
    if book.authors and book.authors ~= "" then
        nodes[#nodes + 1] = { kind = "text", id = "authors", x = x, y = y, w = w, h = t.type.body.line,
            text = book.authors, style = "body", color = "secondary", max_lines = 1, align = "center" }
    end
    y = y + t.type.body.line + t:space(4)
    if (book.percent or 0) > 0 then
        local bw = math.floor(math.min(w * 0.6, t:mm(60)))
        local bh = math.max(3, math.floor(t:mm(1)))
        nodes[#nodes + 1] = { kind = "bar", id = "progress", x = math.floor((t.width - bw) / 2), y = y, w = bw, h = bh,
            fraction = book.percent }
        y = y + bh + t:space(2)
        nodes[#nodes + 1] = { kind = "text", id = "progress_line", x = x, y = y, w = w, h = t.type.caption.line,
            text = copy.progress or "", style = "caption", color = "secondary", max_lines = 1, align = "center" }
    end
    return nodes
end

return SleepLayout
