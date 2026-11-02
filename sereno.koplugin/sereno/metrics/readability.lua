--[[--
Readability statistics, like Calibre's Count Pages plugin, but language
aware: each language gets the formula that was designed for it.

* English: Flesch Reading Ease, Flesch–Kincaid Grade, Gunning Fog
* Spanish: Szigriszt-Pazos Perspicuity, read on the INFLESZ scale
           (Flesch's formula over-rates Spanish, whose words are longer)
* German:  Amstad's adaptation of Flesch (as in Count Pages)
* other:   Flesch Reading Ease, flagged as approximate

Syllables are counted with rule-based heuristics per language (no
dictionaries: too big for an e-reader). They are accurate enough for
book-level averages, which is all these formulas need.
]]

local Text = require("sereno/metrics/text")

local Readability = {}

-- Lower-case ASCII + the Latin-1 letters we care about, as single "letters".
local LOWER = {
    ["Á"] = "á", ["É"] = "é", ["Í"] = "í", ["Ó"] = "ó", ["Ú"] = "ú", ["Ü"] = "ü", ["Ñ"] = "ñ",
    ["Ä"] = "ä", ["Ö"] = "ö",
}

local function lower(word)
    word = word:lower()
    return (word:gsub("\195[\128-\159]", function(c) return LOWER[c] or c end))
end

-- Turns a word into a list of letters, mapping vowels to classes:
-- "s" strong vowel, "w" weak vowel, "W" accented weak vowel, "c" consonant.
local ES_CLASS = {
    a = "s", e = "s", o = "s", ["á"] = "s", ["é"] = "s", ["ó"] = "s",
    i = "w", u = "w", ["ü"] = "w", y = "y",
    ["í"] = "W", ["ú"] = "W",
}

local function letters(word)
    local out = {}
    for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
    return out
end

--- Spanish: one syllable per vowel nucleus. Strong+strong is a hiatus (two
-- syllables); weak+any is a diphthong unless the weak one is accented.
function Readability.syllablesEs(word)
    local ls = letters(lower(word))
    local count, prev = 0, nil
    for i, ch in ipairs(ls) do
        local c = ES_CLASS[ch]
        if c == "y" then
            -- "y" is a vowel only at the end of a word ("hoy", "muy", "y")
            c = (ls[i + 1] == nil) and "w" or nil
        end
        -- "qu"/"gu" + e/i: the u is silent
        if c == "w" and ch == "u" and (ls[i - 1] == "q" or ls[i - 1] == "g") then
            local nxt = ls[i + 1]
            if nxt == "e" or nxt == "i" or nxt == "é" or nxt == "í" then c = nil end
        end
        if c then
            if not prev then
                count = count + 1
            elseif prev == "s" and c == "s" then
                count = count + 1 -- hiatus: le-er
            elseif prev == "W" or c == "W" then
                count = count + 1 -- accented weak vowel breaks the diphthong: dí-a
            end
            prev = c
        else
            prev = nil
        end
    end
    return math.max(1, count)
end

--- English: vowel groups, minus silent endings.
function Readability.syllablesEn(word)
    local w = lower(word):gsub("[^a-z]", "")
    if #w == 0 then return 1 end
    if #w <= 3 then return 1 end
    w = w:gsub("e$", "")             -- silent final e (make, tale)...
    w = w:gsub("([^aeiouy])l$", "%1le") -- ...but keep "-ble", "-tle" (table)
    w = w:gsub("([^aeiouylst])ed$", "%1d") -- "-ed" is silent except after t/d (jumped vs. wanted)
    w = w:gsub("([^aeiouycsxzgh])es$", "%1s") -- "-es" silent except after sibilants
    local _, groups = w:gsub("[aeiouy]+", "")
    -- common splits: "ia" (piano), "io" (ratio), "ua" (actual), not after q (quality)
    local _, splits = w:gsub("[^q][iu][ao]", "")
    return math.max(1, groups + splits)
end

--- German: vowel groups, with the usual diphthongs as one sound.
function Readability.syllablesDe(word)
    local w = lower(word)
    w = w:gsub("ä", "a"):gsub("ö", "o"):gsub("ü", "u")
    w = w:gsub("ie", "i"):gsub("ei", "i"):gsub("eu", "i"):gsub("au", "a"):gsub("[^a-zy]", "")
    local _, groups = w:gsub("[aeiouy]+", "")
    return math.max(1, groups)
end

--- Generic fallback for other Latin-script languages.
function Readability.syllablesGeneric(word)
    local w = lower(word):gsub("\195[\160-\191]", "a"):gsub("[^a-z]", "")
    local _, groups = w:gsub("[aeiouy]+", "")
    return math.max(1, groups)
end

local SYLLABLES = {
    en = Readability.syllablesEn,
    es = Readability.syllablesEs,
    de = Readability.syllablesDe,
}

--- Normalises "en-US", "spa", "es_MX" to a two-letter code.
function Readability.language(code)
    if not code then return nil end
    code = code:lower():gsub("_", "-")
    local three = { eng = "en", spa = "es", deu = "de", ger = "de", fre = "fr", fra = "fr" }
    return three[code:match("^(%a%a%a)$") or ""] or code:match("^(%a%a)")
end

--[[--
Counts sentences, words, syllables and complex words in a text.
@tparam string text
@tparam string lang two-letter language code
@tparam number max_words stop after this many words (sampling, default 60000)
]]
function Readability.analyze(text, lang, max_words)
    max_words = max_words or 60000
    local count_syllables = SYLLABLES[lang] or Readability.syllablesGeneric
    local stats = { words = 0, sentences = 0, syllables = 0, complex = 0, letters = 0 }
    -- sentence ends: . ! ? … followed by space/quote/end; split by lines too (headings, verse)
    for line in text:gmatch("[^\n]+") do
        local in_sentence = false
        for token, sep in line:gmatch("(%S+)(%s*)") do
            local clean = token:gsub("\226\128\153", "'"):gsub("^[%p\194-\226][\128-\191]*", "")
            local word = clean:match("^[%a\195][%a\128-\191'%-]*") or clean:match("^%d[%d.,]*")
            if word and #word > 0 then
                stats.words = stats.words + 1
                stats.letters = stats.letters + Text.length(word)
                if not word:match("^%d") then
                    local syl = count_syllables(word)
                    stats.syllables = stats.syllables + syl
                    -- Gunning: 3+ syllables, not counting proper nouns or hyphenated compounds
                    if syl >= 3 and not word:find("-", 1, true) and not (in_sentence and word:match("^%u")) then
                        stats.complex = stats.complex + 1
                    end
                else
                    stats.syllables = stats.syllables + 1
                end
                in_sentence = true
            end
            if token:find("[%.!?]['\"”’»%)]*$") or token:find("\226\128\166$") then
                if in_sentence then stats.sentences = stats.sentences + 1 end
                in_sentence = false
            end
            if stats.words >= max_words then break end
        end
        if in_sentence then stats.sentences = stats.sentences + 1 end
        if stats.words >= max_words then break end
    end
    return stats
end

local function round1(x) return math.floor(x * 10 + 0.5) / 10 end

--[[--
Scores from analyze() stats.
@treturn table { ease, ease_formula, grade, fog, label, approximate }
  ease: 0 (very hard) .. 100 (very easy) on the language's own scale
  label: "very_easy" | "easy" | "fairly_easy" | "standard" | "fairly_difficult" | "difficult" | "very_difficult"
]]
function Readability.scores(stats, lang)
    if stats.words < 100 or stats.sentences == 0 then return nil end
    local asl = stats.words / stats.sentences       -- words per sentence
    local asw = stats.syllables / stats.words       -- syllables per word
    local out = { words_per_sentence = round1(asl), syllables_per_word = round1(asw * 10) / 10 }

    if lang == "es" then
        out.ease = 206.835 - 62.3 * asw - asl
        out.ease_formula = "szigriszt_pazos"
        -- INFLESZ bands (Barrio-Cantalejo et al., 2008)
        local e = out.ease
        out.label = e < 40 and "very_difficult" or e < 55 and "fairly_difficult" or e < 65 and "standard"
            or e < 80 and "fairly_easy" or "very_easy"
    else
        if lang == "de" then
            out.ease = 180 - asl - 58.5 * asw
            out.ease_formula = "amstad"
        else
            out.ease = 206.835 - 1.015 * asl - 84.6 * asw
            out.ease_formula = "flesch"
            out.approximate = lang ~= "en" or nil
        end
        local e = out.ease
        out.label = e < 30 and "very_difficult" or e < 50 and "difficult" or e < 60 and "fairly_difficult"
            or e < 70 and "standard" or e < 80 and "fairly_easy" or e < 90 and "easy" or "very_easy"
    end
    if lang == "en" or lang == nil then
        out.grade = round1(0.39 * asl + 11.8 * asw - 15.59)
        out.fog = round1(0.4 * (asl + 100 * stats.complex / stats.words))
    end
    out.ease = round1(math.max(0, math.min(121, out.ease)))
    return out
end

return Readability
