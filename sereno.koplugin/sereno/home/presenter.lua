--[[--
Turns the home model (sereno/home/context) into the words shown on
screen. Kept apart from the layout so translations never move pixels
around, and pure so it can be tested.
]]

local Context = require("sereno/home/context")

local Presenter = {}

local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December" }

local function thousands(n, sep)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
    return (out:gsub("^" .. sep:gsub("%p", "%%%0"), ""))
end
Presenter.thousands = thousands

-- English source strings for the readability bands of sereno/metrics/readability
local READABILITY = {
    very_easy = "Very easy read", easy = "Easy read", fairly_easy = "Fairly easy read",
    standard = "Standard read", fairly_difficult = "Fairly demanding read",
    difficult = "Demanding read", very_difficult = "Very demanding read",
}
Presenter.READABILITY = READABILITY

--- "Frankenstein; or, The Modern Prometheus" -> "Frankenstein" (for small captions)
function Presenter.shortTitle(title)
    if not title then return nil end
    local short = title:gsub("%s*[:;].*$", ""):gsub("%s*%(.*%)%s*$", "")
    return short ~= "" and short or title
end

local function fill(template, ...)
    local args = { ... }
    return (template:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
end

--[[--
@tparam table model  Context.build() result (modified in place)
@tparam function _   translation function
@tparam table status { time = "07:48", battery = 82 (optional), charging = bool }
@string sep thousands separator ("," by default)
@treturn table copy for Layout.home
]]
function Presenter.present(model, _, status, sep)
    status = status or {}
    sep = sep or ","
    local duration_words = { h = _("h"), min = _("min"), less = _("under a minute") }

    local d = model.date or os.date("*t")
    local copy = {
        status_left = fill(_("%1, %2 %3"), _(DAYS[d.wday]), d.day, _(MONTHS[d.month])),
        status_right = status.time or "",
        nav = {
            { id = "library", label = _("Library") },
            { id = "history", label = _("History") },
            { id = "collections", label = _("Collections") },
            { id = "search", label = _("Search") },
        },
        empty_title = _("Your library is empty"),
        empty_body = _("Copy some books to your reader, then open the Library to find them."),
    }
    if status.battery then
        local battery = tostring(status.battery) .. "%" .. (status.charging and " +" or "")
        copy.status_right = copy.status_right ~= "" and (copy.status_right .. " · " .. battery) or battery
    end

    if model.state == "reading" then
        copy.hero_label = _("Continue reading")
    elseif model.state == "finished" then
        copy.hero_label = _("Finished")
    elseif model.state == "start" then
        copy.hero_label = _("Start here")
    end
    copy.shelf_label = (model.state == "reading") and _("On your shelf") or _("Up next")

    local hero = model.hero
    if hero then
        if type(hero.authors) == "table" then hero.authors = table.concat(hero.authors, ", ") end
        local short = Presenter.shortTitle(hero.title)
        hero.short_title = short ~= hero.title and short or nil
        if model.state == "finished" then
            local parts = {}
            if hero.page_total then parts[#parts + 1] = fill(_("%1 pages"), thousands(hero.page_total, sep)) end
            if hero.minutes_total then
                parts[#parts + 1] = fill(_("%1 of reading"), Context.formatDuration(hero.minutes_total, duration_words))
            end
            hero.progress_line = #parts > 0 and table.concat(parts, " · ") or nil
            if model.up_next then
                hero.time_line = fill(_("Next: %1"), model.up_next.title)
            end
        else
            local pct = math.floor((hero.percent or 0) * 100 + 0.5)
            if hero.page_total and hero.percent and hero.percent > 0 then
                hero.progress_line = fill(_("Page %1 of %2 · %3%"), thousands(hero.page_now, sep),
                    thousands(hero.page_total, sep), pct)
            elseif hero.page_total then
                hero.progress_line = fill(_("%1 pages"), thousands(hero.page_total, sep))
            elseif hero.percent and hero.percent > 0 then
                hero.progress_line = fill(_("%1% read"), pct)
            end
            if hero.minutes_left and (hero.percent or 0) > 0 then
                hero.time_line = fill(_("About %1 left"), Context.formatDuration(hero.minutes_left, duration_words))
            elseif hero.minutes_total then
                hero.time_line = fill(_("About %1 to read"), Context.formatDuration(hero.minutes_total, duration_words))
            end
        end
        local details = {}
        if hero.readability and READABILITY[hero.readability] then details[#details + 1] = _(READABILITY[hero.readability]) end
        if hero.words then details[#details + 1] = fill(_("%1 words"), thousands(hero.words, sep)) end
        if #details > 0 then
            hero.detail_line = table.concat(details, " · ")
        end
    end

    for _i, book in ipairs(model.shelf or {}) do
        if type(book.authors) == "table" then book.authors = table.concat(book.authors, ", ") end
        book.short_title = Presenter.shortTitle(book.title)
        if book.reason == "series" then
            book.shelf_meta = _("Next in series")
        elseif book.reason == "in_progress" then
            book.shelf_meta = fill("%1%", math.floor(book.percent * 100 + 0.5))
        elseif book.page_total then
            book.shelf_meta = fill(_("%1 pages"), thousands(book.page_total, sep))
        else
            book.shelf_meta = _("New")
        end
    end
    return copy
end

return Presenter
