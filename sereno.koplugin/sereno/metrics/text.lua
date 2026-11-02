--[[--
UTF-8 helpers for counting characters, display columns and words, written
for LuaJIT/Lua 5.1 (no utf8 library).
]]

local Text = {}

--- Iterates code points of a UTF-8 string. Invalid bytes yield U+FFFD.
function Text.codepoints(s)
    local i, n = 1, #s
    return function()
        if i > n then return nil end
        local c = s:byte(i)
        local cp, len
        if c < 0x80 then
            cp, len = c, 1
        elseif c >= 0xF0 and i + 3 <= n then
            local c2, c3, c4 = s:byte(i + 1, i + 3)
            cp, len = (c - 0xF0) * 262144 + (c2 - 0x80) * 4096 + (c3 - 0x80) * 64 + (c4 - 0x80), 4
        elseif c >= 0xE0 and i + 2 <= n then
            local c2, c3 = s:byte(i + 1, i + 2)
            cp, len = (c - 0xE0) * 4096 + (c2 - 0x80) * 64 + (c3 - 0x80), 3
        elseif c >= 0xC0 and i + 1 <= n then
            cp, len = (c - 0xC0) * 64 + (s:byte(i + 1) - 0x80), 2
        else
            cp, len = 0xFFFD, 1
        end
        local start = i
        i = i + len
        return cp, start, len
    end
end

--- Number of code points (fast path: count non-continuation bytes).
function Text.length(s)
    local _, cont = s:gsub("[\128-\191]", "")
    return #s - cont
end

--- East Asian wide characters take two columns on a printed line.
function Text.isWide(cp)
    return (cp >= 0x1100 and cp <= 0x115F)
        or (cp >= 0x2E80 and cp <= 0xA4CF)
        or (cp >= 0xAC00 and cp <= 0xD7A3)
        or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0xFE30 and cp <= 0xFE4F)
        or (cp >= 0xFF00 and cp <= 0xFF60)
        or (cp >= 0xFFE0 and cp <= 0xFFE6)
        or (cp >= 0x20000 and cp <= 0x3FFFD)
end

--- Ideographic scripts are written without spaces: every glyph is a "word".
function Text.isIdeographic(cp)
    return (cp >= 0x3040 and cp <= 0x30FF) -- kana
        or (cp >= 0x3400 and cp <= 0x9FFF) -- CJK
        or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0x20000 and cp <= 0x3FFFD)
end

--- Display width in columns.
function Text.columns(s)
    if not s:find("[\128-\255]") then return #s end
    local w = 0
    for cp in Text.codepoints(s) do
        w = w + (Text.isWide(cp) and 2 or 1)
    end
    return w
end

--- True if the string has East Asian characters (slow path needed).
function Text.hasWide(s)
    if not s:find("[\225-\240]") then return false end
    for cp in Text.codepoints(s) do
        if Text.isWide(cp) then return true end
    end
    return false
end

--[[--
Counts words. A word is a run of letters/digits (any non-ASCII byte counts
as a letter, apostrophes and hyphens inside words are kept); every
ideographic glyph counts as one word, like Calibre's ICU word counter.
]]
function Text.countWords(s)
    local n = 0
    if not s:find("[\227-\240]") then
        -- U+2019 is an apostrophe; the rest of General Punctuation (dashes,
        -- quotes, ellipsis, spaces) and Latin-1 symbols (¡ ¿ « » nbsp) separate words.
        s = s:gsub("\226\128\153", "'"):gsub("\226[\128\129][\128-\191]", " "):gsub("\194[\160-\191]", " ")
        for _ in s:gmatch("[%w\128-\255][%w\128-\255'’%-]*") do n = n + 1 end
        return n
    end
    local in_word = false
    for cp in Text.codepoints(s) do
        if Text.isIdeographic(cp) then
            n = n + 1
            in_word = false
        elseif (cp >= 48 and cp <= 57) or (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122)
            or (cp > 127 and cp ~= 0x3000 and not (cp >= 0x2000 and cp <= 0x206F) and not (cp >= 0x3000 and cp <= 0x303F)) then
            if not in_word then n = n + 1 end
            in_word = true
        elseif cp == 39 or cp == 45 or cp == 0x2019 then
            -- apostrophe/hyphen continue a word but don't start one
            in_word = in_word
        else
            in_word = false
        end
    end
    return n
end

--- Encodes a code point as UTF-8.
function Text.char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    if cp < 0x110000 then
        return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
            0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return "\239\191\189"
end

return Text
