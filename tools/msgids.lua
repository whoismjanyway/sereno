-- Lists every translatable string in the plugin (source msgids).
-- Usage: luajit tools/msgids.lua            -> one msgid per line
-- Used by spec/l10n_spec.lua to check that translations are complete.
local function files()
    local p = io.popen("find sereno.koplugin -name '*.lua' -not -path '*/l10n/*'")
    local out = {}
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end

local Msgids = {}

function Msgids.collect()
    local seen, list = {}, {}
    local function add(s)
        if not seen[s] then seen[s] = true; list[#list + 1] = s end
    end
    for _, path in ipairs(files()) do
        local f = io.open(path, "rb")
        local src = f:read("*a")
        f:close()
        for q, body in src:gmatch('_%(%s*(["\'])(.-[^\\])%1%s*%)') do
            add((loadstring or load)("return " .. q .. body .. q)())
        end
        for body in src:gmatch('_%(%s*%[%[(.-)%]%]%s*%)') do add(body) end
    end
    -- strings translated through tables
    package.path = "sereno.koplugin/?.lua;" .. package.path
    for _, s in ipairs({ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
        "January", "February", "March", "April", "May", "June", "July", "August", "September",
        "October", "November", "December" }) do add(s) end
    for _, v in pairs(require("sereno/home/presenter").READABILITY) do add(v) end
    local labels = {
        "Print model (Sereno)", "Printed edition (Open Library)", "Calibre APNX estimate",
        "Adobe Digital Editions", "Characters per page" }
    for _, v in ipairs(labels) do add(v) end
    local RL = require("sereno/reader/layout")
    for _, group in ipairs({ RL.PAGES, RL.SPACING, RL.MARGINS, RL.ALIGNMENTS, RL.THEMES }) do
        for _, p in ipairs(group) do add(p.name) end
    end
    add("Book"); add("Publisher"); add("Status bar")
    -- the tabs' titles, empty states and sort orders (sereno/shell/browse)
    for _, v in ipairs({ "Library", "Reading", "Collections", "Search", "Favorites", "Title", "Author", "Recent",
        "No books in this folder", "Books you open appear here", "This collection is empty",
        "Long-press a book in KOReader's file browser to add it to a collection", "No books match",
        "Search your library by title, author or file name" }) do add(v) end
    table.sort(list)
    return list
end

if arg and arg[0] and arg[0]:find("msgids") then
    for _, s in ipairs(Msgids.collect()) do print(s) end
end
return Msgids
