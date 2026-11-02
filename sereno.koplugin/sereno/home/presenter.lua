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
What every Sereno screen shows around its content: the date, the clock
and battery, and the tab bar with `active` marked.
]]
function Presenter.frame(_, status, active, d)
    status = status or {}
    d = d or os.date("*t")
    local copy = {
        status_left = fill(_("%1, %2 %3"), _(DAYS[d.wday]), d.day, _(MONTHS[d.month])),
        status_right = status.time or "",
        date = fill(_("%1, %2 %3"), _(DAYS[d.wday]), d.day, _(MONTHS[d.month])),
        -- icons are KOReader's own (resources/icons/mdlight)
        nav = {
            { id = "home", label = _("Home"), icon = "home" },
            { id = "library", label = _("Library"), icon = "appbar.filebrowser" },
            { id = "history", label = _("Reading"), icon = "book.opened" },
            { id = "collections", label = _("Collections"), icon = "star.empty" },
            { id = "search", label = _("Search"), icon = "appbar.search" },
        },
    }
    for _i, item in ipairs(copy.nav) do item.active = item.id == active end
    if status.battery then
        local battery = tostring(status.battery) .. "%" .. (status.charging and " +" or "")
        copy.status_right = copy.status_right ~= "" and (copy.status_right .. " · " .. battery) or battery
    end
    return copy
end

--[[--
The words for a Library / Reading / Collections / Search model
(sereno/shell/browse).
]]
function Presenter.browse(model, _, status, sep)
    sep = sep or ","
    local copy = Presenter.frame(_, status, model.tab)
    local fixed = { Library = true, Reading = true, Collections = true, Search = true }
    copy.title = fixed[model.title] and _(model.title) or model.title
    local parts = {}
    if model.subtitle_folders and model.subtitle_folders > 0 then
        parts[#parts + 1] = fill(_("%1 folders"), thousands(model.subtitle_folders, sep))
    end
    if model.subtitle_count and (model.subtitle_count > 0 or #parts == 0) then
        parts[#parts + 1] = fill(_("%1 books"), thousands(model.subtitle_count, sep))
    end
    if model.subtitle_collections then
        parts[#parts + 1] = fill(_("%1 collections"), thousands(model.subtitle_collections, sep))
    end
    copy.subtitle = table.concat(parts, " · ")
    if model.sortable or (model.searchable and model.query and model.query ~= "") then
        copy.sort_label = _(({ title = "Title", author = "Author", recent = "Recent" })[model.sort] or "Title")
    end
    copy.query = model.query
    copy.search_placeholder = _("Title, author or file name")
    copy.empty = model.empty and _(model.empty) or ""
    copy.finished = _("Finished")
    copy.count_books = _("%d books")
    copy.page_of = _("%d of %d")
    return copy
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
    local copy = Presenter.frame(_, status, "home", d)
    for k, v in pairs({
        greeting = ({ night = _("Good night"), morning = _("Good morning"),
            afternoon = _("Good afternoon"), evening = _("Good evening") })[model.part_of_day or "evening"],
        see_all = _("See all"),
        empty_title = _("Your library is empty"),
        empty_body = _("Copy some books to your reader, then open the Library to find them."),
    }) do copy[k] = v end

    if model.state == "reading" then
        copy.hero_label = _("Continue reading")
    elseif model.state == "finished" then
        copy.hero_label = _("Finished")
    elseif model.state == "start" then
        copy.hero_label = _("Start here")
    end
    copy.shelf_label = (model.state == "reading") and _("On your shelf") or _("Up next")

    if model.stats then
        copy.stats = {
            { value = thousands(model.stats.in_progress or 0, sep), label = _("Reading") },
            { value = thousands(model.stats.unread or 0, sep), label = _("Unread") },
            { value = thousands(model.stats.finished or 0, sep), label = _("Finished") },
        }
    end

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
        -- short facts set as chips under the progress bar
        hero.percent_label = (hero.percent or 0) > 0 and model.state == "reading"
            and fill("%1%", math.floor(hero.percent * 100 + 0.5)) or nil
        hero.chips = {}
        if hero.page_total then
            if model.state == "reading" and hero.page_now then
                hero.chips[#hero.chips + 1] = fill(_("Page %1 of %2"), thousands(hero.page_now, sep), thousands(hero.page_total, sep))
            else
                hero.chips[#hero.chips + 1] = fill(_("%1 pages"), thousands(hero.page_total, sep))
            end
        end
        if model.state == "reading" and hero.minutes_left and (hero.percent or 0) > 0 then
            hero.chips[#hero.chips + 1] = fill(_("%1 left"), Context.formatDuration(hero.minutes_left, duration_words))
        elseif hero.minutes_total then
            hero.chips[#hero.chips + 1] = Context.formatDuration(hero.minutes_total, duration_words)
        end
        if hero.readability and READABILITY[hero.readability] then
            hero.chips[#hero.chips + 1] = _(READABILITY[hero.readability])
        end
        if model.state == "finished" and model.up_next then
            hero.next_line = fill(_("Next: %1"), model.up_next.title)
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
        book.shelf_progress = book.reason == "in_progress" and book.percent or nil
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
