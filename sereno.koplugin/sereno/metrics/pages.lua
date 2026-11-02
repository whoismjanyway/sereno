--[[--
Page-count estimators.

KOReader's own page numbers depend on the current layout (font, size,
margins, screen), so they change whenever you adjust anything, and its
"synthetic page map" only exists after a book has been opened and rendered
(it cuts the text every N characters, 1500 by default).

Sereno estimates pages *without opening the book*, so a whole library can
be counted, and the number stays put whatever your reading settings are.
Four estimators are computed so they can be compared:

* print    – Sereno's print model (default). Typesets the text on a
             reference printed page: words are wrapped greedily into lines,
             every paragraph starts a new line, headings take more room,
             chapters start on a fresh page, images take a third of a page.
             This is what makes it closer to the paper edition than plain
             character counts: dialogue-heavy and verse books get the extra
             pages their many short lines really use.
* apnx     – the "APNX accurate" algorithm from Calibre's Count Pages plugin
             (a line per paragraph start or every 70 characters, 31 lines per
             page, with a characters/2400 backstop), re-implemented here.
* adobe    – Adobe Digital Editions: 1 page per started 1024 bytes of
             *compressed* content in each spine file.
* chars    – a flat characters-per-page count, by default 1500 to match
             KOReader's synthetic page map, so both numbers line up.
]]

local Html = require("sereno/metrics/html")
local Text = require("sereno/metrics/text")

local Pages = {}

--- The reference printed page (a typical trade paperback).
-- Calibrated against print editions, see docs/page-count.md.
Pages.REFERENCE = {
    columns = 64,        -- characters per full line, spaces included
    lines = 32,          -- text lines per page
    indent = 3,          -- first-line indent of a paragraph, in characters
    heading_columns = 40, -- headings use a bigger size: fewer characters per line
    heading_lines = 1.5, -- each heading line is taller
    heading_space = 2,   -- blank lines around a heading
    chapter_sink = 8,    -- chapter titles start lower on the page
    image_lines = 11,    -- an image takes about a third of a page
    break_lines = 2,     -- scene break (<hr>)
}

--- Lines a paragraph needs when greedily wrapped to `columns`.
function Pages.wrapLines(text, columns, indent)
    if text == "" then return 0 end
    if Text.hasWide(text) then
        -- no spaces between words in CJK: lines are filled glyph by glyph
        return math.max(1, math.ceil((Text.columns(text) + (indent or 0)) / columns))
    end
    local ascii = not text:find("[\128-\255]")
    local lines, used, empty = 1, indent or 0, true
    for word in text:gmatch("%S+") do
        local w = ascii and #word or Text.length(word)
        local need = empty and w or w + 1 -- a space before every word but the first
        if used + need > columns and not empty then
            -- word goes to the next line
            lines = lines + 1
            used, need = 0, w
        end
        used = used + need
        empty = false
        if used > columns then
            -- a word longer than a line (URL, long compound): hard-break it
            lines = lines + math.ceil(used / columns) - 1
            used = used % columns
        end
    end
    return lines
end

--[[--
Print model for one content document.
@treturn number pages (0 when the document has neither text nor images)
@treturn number text characters
]]
function Pages.printModelDocument(blocks, ref)
    ref = ref or Pages.REFERENCE
    local lines, chars, has_content = 0, 0, false
    for i, b in ipairs(blocks) do
        if b.kind == "p" then
            local indent = (b.soft or i == 1) and 0 or ref.indent
            lines = lines + Pages.wrapLines(b.text, ref.columns, indent)
            chars = chars + Text.length(b.text)
            has_content = true
        elseif b.kind == "h" then
            local scale = (b.level or 1) <= 2 and 1 or 0.8
            local hl = Pages.wrapLines(b.text, math.floor(ref.heading_columns / scale), 0)
            lines = lines + hl * ref.heading_lines * scale + ref.heading_space
            if i == 1 then lines = lines + ref.chapter_sink end
            chars = chars + Text.length(b.text)
            has_content = true
        elseif b.kind == "img" then
            lines = lines + ref.image_lines
            has_content = true
        elseif b.kind == "hr" then
            lines = lines + ref.break_lines
        end
    end
    if not has_content then return 0, 0 end
    return math.max(1, math.ceil(lines / ref.lines)), chars
end

--[[--
APNX "accurate" algorithm, re-implemented from Calibre's Count Pages plugin
(GPL-3.0, by Grant Drake): scans the raw HTML of the whole book.
]]
function Pages.apnx(raw_html, plain_chars)
    local lower = raw_html:lower()
    local _, num_divs = lower:gsub("<div", "")
    local _, num_paras = lower:gsub("<p", "")
    local split = num_paras > num_divs and "p" or "d"

    local lines = 0
    local p_chars = 0
    local in_p = false
    -- tokenise into tags and text runs instead of looping per character
    for tag, text in lower:gmatch("<([^>]*)>([^<]*)") do
        local closing = tag:sub(1, 1) == "/"
        local first = (closing and tag:sub(2, 2) or tag:sub(1, 1))
        if first == split then
            if closing then
                in_p = false
            else
                in_p = true
                lines = lines + 1
            end
        end
        if in_p and #text > 0 then
            local n = p_chars + #text
            lines = lines + math.floor(n / 70)
            p_chars = n % 70
        end
    end
    local count = math.floor(lines / 31)
    local fast = math.floor((plain_chars or #raw_html) / 2400) + 1
    return math.max(count, fast)
end

--- Adobe Digital Editions: ceil(compressed bytes / 1024) per spine file.
function Pages.adobe(spine)
    local pages = 0
    for _i, item in ipairs(spine) do
        if item.compressed_size and item.compressed_size > 0 then
            pages = pages + math.ceil(item.compressed_size / 1024)
        end
    end
    return pages
end

--- Flat characters per page (KOReader's synthetic page map uses 1500).
function Pages.chars(total_chars, chars_per_page)
    chars_per_page = chars_per_page or 1500
    if total_chars <= 0 then return 0 end
    return math.ceil(total_chars / chars_per_page)
end

Pages.blocks = Html.blocks

return Pages
