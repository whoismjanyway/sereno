--[[--
Sets a book page the way crengine does for KOReader's reader, closely
enough to judge margins and typography from a picture:

* Knuth–Liang hyphenation with crengine's own pattern files
  (cr3gui/data/hyph/*.pattern), at least 2 letters before and after the
  hyphen, as KOReader's defaults;
* greedy line filling (crengine does not use Knuth–Plass either), with
  justified or ragged-right lines; breaks also after an em dash;
* first-line indents of 1.2 em, none after a heading, no blank lines
  between paragraphs (KOReader's "book" style tweaks), centred headings;
* line height = the font's ascender + descender × line spacing %, like
  crengine's interline spacing.

Glyphs are drawn and measured with KOReader's RenderText and FreeType.
Used by tools/korender/render.lua; not part of the plugin.
]]

local BookPage = {}

-- ---------------------------------------------------------------------------
-- Hyphenation (Liang)

local Hyph = {}
Hyph.__index = Hyph

function BookPage.loadPatterns(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local src = f:read("*a")
    f:close()
    local self = setmetatable({ patterns = {}, max_len = 0, left = 2, right = 2 }, Hyph)
    for pat in src:gmatch("<pattern>([^<]*)</pattern>") do
        pat = pat:gsub("^%s+", "."):gsub("%s+$", ".")
        -- ".ach4" -> letters ".ach", values[k] = score before letter k
        local letters, values = {}, {}
        for c in pat:gmatch(".") do
            if c:match("%d") then values[#letters + 1] = tonumber(c)
            else letters[#letters + 1] = c end
        end
        for k = 1, #letters + 1 do values[k] = values[k] or 0 end
        letters = table.concat(letters)
        self.patterns[letters] = values
        if #letters > self.max_len then self.max_len = #letters end
    end
    return self
end

--- Positions (byte offsets, after which a hyphen may go) in an ASCII word.
function Hyph:points(word)
    local lw = word:lower()
    if #lw < self.left + self.right or lw:find("[^a-z]") then return {} end
    local w = "." .. lw .. "."
    local n = #w
    local values = {}
    for i = 1, n + 1 do values[i] = 0 end
    for i = 1, n do
        for j = i, math.min(n, i + self.max_len - 1) do
            local p = self.patterns[w:sub(i, j)]
            if p then
                for k = 1, #p do
                    local idx = i + k - 1
                    if p[k] > values[idx] then values[idx] = p[k] end
                end
            end
        end
    end
    -- values[idx] is the score before character idx of w ("." counts as 1)
    local out = {}
    for pos = self.left, #lw - self.right do
        -- break after letter `pos` of the word = before char pos + 2 of w
        if values[pos + 2] % 2 == 1 then out[#out + 1] = pos end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Typesetting

local WORD_JOINER = "\u{2060}"
local EM_DASH = "—"

--- Break opportunities inside a token: { {pos, hyphen} } sorted by pos.
local function breaks(token, hyph)
    local out = {}
    -- after an em dash (crengine allows it, even after a word joiner)
    local start = 1
    while true do
        local s, e = token:find(EM_DASH, start, true)
        if not s then break end
        if e < #token then out[#out + 1] = { pos = e, hyphen = false } end
        start = e + 1
    end
    -- after an explicit hyphen
    for pos in token:gmatch("()%-") do
        if pos < #token then out[#out + 1] = { pos = pos, hyphen = false } end
    end
    -- inside each run of plain letters
    if hyph then
        for s, run in token:gmatch("()(%a+)") do
            for _i, p in ipairs(hyph:points(run)) do out[#out + 1] = { pos = s + p - 1, hyphen = true } end
        end
    end
    table.sort(out, function(a, b) return a.pos < b.pos end)
    return out
end

--[[--
Sets paragraphs into lines.
@tparam table o { width, measure(text) -> px, hyph, align ("justify"|"left"),
  indent_px, space_px, min_space_px }
@tparam table para { text, indent (bool) }
@treturn table lines: { words = {text...}, widths = {...}, words_w, last, indent }
]]
local function setParagraph(o, para)
    local tokens = {}
    for tok in para.text:gsub(WORD_JOINER, ""):gmatch("%S+") do tokens[#tokens + 1] = tok end
    local min_space = o.min_space_px or o.space_px
    local lines = {}
    local line = { words = {}, widths = {}, words_w = 0, indent = para.indent and o.indent_px or 0 }
    -- does the line fit with `extra` more px of word and one more space?
    local function fits(extra)
        local gaps = #line.words -- one more word adds one more gap when the line isn't empty
        return line.words_w + extra + gaps * min_space <= o.width - line.indent
    end
    local function add(word, w)
        line.words[#line.words + 1] = word
        line.widths[#line.widths + 1] = w
        line.words_w = line.words_w + w
    end
    local function push(last)
        line.last = last
        lines[#lines + 1] = line
        line = { words = {}, widths = {}, words_w = 0, indent = 0 }
    end
    local i = 1
    while i <= #tokens do
        local tok = tokens[i]
        local tw = o.measure(tok)
        if fits(tw) then
            add(tok, tw)
            i = i + 1
        else
            -- try to break the token: the longest piece that still fits
            local placed = false
            local opts = breaks(tok, o.hyph)
            for k = #opts, 1, -1 do
                local b = opts[k]
                local head = tok:sub(1, b.pos) .. (b.hyphen and "-" or "")
                local hw = o.measure(head)
                if fits(hw) then
                    add(head, hw)
                    tokens[i] = tok:sub(b.pos + 1)
                    placed = true
                    break
                end
            end
            if #line.words == 0 and not placed then
                -- a token wider than the whole line: let it overflow
                add(tok, tw)
                i = i + 1
            end
            push(false)
        end
    end
    if #line.words > 0 then push(true) end
    return lines
end

--[[--
Draws blocks onto a blitbuffer.
@tparam table o {
  bb, x, y, width, height,
  face, heading_face, footer_face, RenderText, color, grey,
  line_px, font_px, align, hyph,
  blocks = { {kind = "h"|"p", text}... }, chapter_opening (bool),
  footer = { left, right, y, h } (optional) }
@treturn table { lines = n, words_per_line = avg, hyphens = n }
]]
function BookPage.render(o)
    local RT = o.RenderText
    local cache = {}
    local function measure(face)
        return function(text)
            local key = text
            local c = cache[face] or {}
            cache[face] = c
            if not c[key] then c[key] = RT:sizeUtf8Text(0, false, face, text, true, false).x end
            return c[key]
        end
    end
    local m = measure(o.face)
    -- KOReader's default word spacing ("medium", {95, 75}): spaces at 95 %,
    -- which crengine may condense to 75 % of that to fit one more word
    local space_px = m(" ") * 0.95
    local opts = { width = o.width, measure = m, hyph = o.hyph, align = o.align, space_px = space_px,
        min_space_px = space_px * 0.75,
        indent_px = math.floor(o.font_px * 1.2 + 0.5) }
    local _h, ascender = o.face.ftsize:getHeightAndAscender()
    local y = o.y
    local bottom = o.y + o.height
    local stats = { lines = 0, hyphens = 0, chars = 0 }
    local after_heading = true

    for _b, block in ipairs(o.blocks) do
        if y + o.line_px > bottom then break end
        if block.kind == "h" then
            -- a chapter opening starts lower on the page, like a printed book
            if o.chapter_opening then y = y + o.line_px * 2 end
            local hm = measure(o.heading_face)
            local hw = hm(block.text)
            local _hh, hasc = o.heading_face.ftsize:getHeightAndAscender()
            RT:renderUtf8Text(o.bb, o.x + math.floor((o.width - hw) / 2), math.floor(y + hasc), o.heading_face,
                block.text, true, false, o.color)
            y = y + math.floor(o.line_px * 3)
            after_heading = true
        else
            local lines = setParagraph(opts, { text = block.text, indent = not after_heading })
            after_heading = false
            for _l, line in ipairs(lines) do
                if y + o.line_px > bottom + 1 then break end
                local baseline = math.floor(y + (o.line_px - o.font_px * 1.36) / 2 + ascender + 0.5)
                local x = o.x + line.indent
                local gap = space_px
                local n = #line.words
                if n > 1 then
                    local fill = (o.width - line.indent - line.words_w) / (n - 1)
                    -- justified lines stretch; any line may use condensed spaces
                    if o.align == "justify" and not line.last then gap = fill else gap = math.min(space_px, fill) end
                end
                local cx = x
                for k, word in ipairs(line.words) do
                    RT:renderUtf8Text(o.bb, math.floor(cx + 0.5), baseline, o.face, word, true, false, o.color)
                    cx = cx + line.widths[k] + gap
                    stats.chars = stats.chars + #word + 1
                end
                if line.words[n] and line.words[n]:sub(-1) == "-" and not line.last then stats.hyphens = stats.hyphens + 1 end
                stats.lines = stats.lines + 1
                y = y + o.line_px
            end
        end
    end
    if o.footer then
        local fm = measure(o.footer_face)
        local _fh, fasc = o.footer_face.ftsize:getHeightAndAscender()
        local fh = o.footer_face.ftsize:getHeightAndAscender()
        local fy = math.floor(o.footer.y + (o.footer.h - fh) / 2 + fasc)
        if o.footer.left then RT:renderUtf8Text(o.bb, o.x, fy, o.footer_face, o.footer.left, true, false, o.grey) end
        if o.footer.right then
            RT:renderUtf8Text(o.bb, o.x + o.width - fm(o.footer.right), fy, o.footer_face, o.footer.right, true, false, o.grey)
        end
    end
    stats.chars_per_line = stats.lines > 0 and math.floor(stats.chars / stats.lines) or 0
    return stats
end

BookPage.setParagraph = setParagraph
BookPage.breaks = breaks
return BookPage
