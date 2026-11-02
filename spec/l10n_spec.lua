-- Translations: every source string is covered and placeholders match.
local H = require("helper")
local test, eq, truthy = H.it, H.eq, H.truthy
package.path = "tools/?.lua;" .. package.path
local Msgids = require("msgids")
local L10n = require("sereno/l10n")

local LANGS = { "es" }

H.describe("translations")

local function placeholders(s)
    local out = {}
    for d in s:gmatch("%%(%d)") do out[#out + 1] = d end
    table.sort(out)
    return table.concat(out, ",")
end

for _i, lang in ipairs(LANGS) do
    local cat = require("sereno/l10n/" .. lang)
    test(lang .. ": every string is translated", function()
        local missing = {}
        for _j, id in ipairs(Msgids.collect()) do
            if not cat[id] then missing[#missing + 1] = id end
        end
        eq(#missing, 0, "missing: " .. table.concat(missing, " | "))
    end)
    test(lang .. ": placeholders are kept", function()
        for id, tr in pairs(cat) do
            if id ~= "thousands_separator" then eq(placeholders(tr), placeholders(id), id) end
        end
    end)
end

test("language selection", function()
    L10n.setLanguage("es_MX")
    eq(L10n.lang, "es")
    eq(L10n("Library"), "Biblioteca")
    L10n.setLanguage("fr")
    eq(L10n.lang, nil)
    eq(L10n("Library"), "Library")
    L10n.setLanguage(nil)
    truthy(L10n("x") == "x")
end)
