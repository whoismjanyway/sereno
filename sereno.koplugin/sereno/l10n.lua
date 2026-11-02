--[[--
Tiny localisation layer.

Source strings are English. KOReader's gettext only knows KOReader's own
catalogue, so plugin translations live in sereno/l10n/<lang>.lua as plain
tables (msgid -> translation). Adding a language = adding one file.

Usage:
    local _ = require("sereno/l10n")
    _("Reading")
]]

local ok_gettext, gettext = pcall(require, "gettext")

local L10n = {
    available = { es = true },
    catalogue = {},
    lang = nil,
}

--- Picks the catalogue for a KOReader language code such as "es" or "pt_BR".
function L10n.setLanguage(code)
    L10n.lang = nil
    L10n.catalogue = {}
    if type(code) ~= "string" then return end
    local candidates = { code, code:match("^(%a%a)") }
    for _i, c in ipairs(candidates) do
        if c and L10n.available[c] then
            local ok, cat = pcall(require, "sereno/l10n/" .. c)
            if ok and type(cat) == "table" then
                L10n.lang = c
                L10n.catalogue = cat
                return
            end
        end
    end
end

local function detectLanguage()
    if G_reader_settings and G_reader_settings.readSetting then
        return G_reader_settings:readSetting("language")
    end
    return os.getenv("LANGUAGE") or os.getenv("LANG")
end

L10n.setLanguage(detectLanguage())

local function translate(msgid)
    local t = L10n.catalogue[msgid]
    if t then return t end
    if ok_gettext then return gettext(msgid) end
    return msgid
end

return setmetatable(L10n, {
    __call = function(_self, msgid) return translate(msgid) end,
})
