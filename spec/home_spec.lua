-- Home screen: context rules, wording and layout on several devices.
local H = require("helper")
local test, eq, truthy = H.it, H.eq, H.truthy
local Theme = require("sereno/ui/theme")
local Context = require("sereno/home/context")
local Layout = require("sereno/home/layout")
local Presenter = require("sereno/home/presenter")

local BOOKS = {
    gatsby = { title = "The Great Gatsby", authors = { "F. Scott Fitzgerald" }, percent = 0.38, status = "reading", been_opened = true },
    pride = { title = "Pride and Prejudice", authors = { "Jane Austen" }, percent = 0.12, status = "reading", been_opened = true },
    done = { title = "Done Book", percent = 1, status = "complete", been_opened = true },
    held = { title = "On Hold", percent = 0.4, status = "abandoned", been_opened = true },
    frank = { title = "Frankenstein; or, The Modern Prometheus", authors = { "Mary Shelley" }, percent = 0, status = "new" },
    s1 = { title = "Saga 1", series = "Saga", series_index = 1, percent = 1, status = "complete", been_opened = true },
    s2 = { title = "Saga 2", series = "Saga", series_index = 2, percent = 0, status = "new" },
}
local METRICS = {
    gatsby = { words = 49153, pages = { print = 179, downloaded = 180 }, readability = { label = "fairly_easy" } },
    frank = { words = 78619, pages = { print = 268 } },
}

local function sources(history, new)
    return {
        history = function() return history end,
        book_info = function(f) return BOOKS[f] end,
        new_books = function() return new or {} end,
        metrics = function(f) return METRICS[f] end,
    }
end

local EVENING = { year = 2026, month = 11, day = 2, hour = 22, min = 5, wday = 2 }

H.describe("home context")

test("reading: the last book is the hero, with stable print pages and time left", function()
    local m = Context.build(sources({ "gatsby", "pride", "done", "held" }, { "frank" }), { now = EVENING })
    eq(m.state, "reading")
    eq(m.hero.file, "gatsby")
    eq(m.hero.page_total, 179)
    eq(m.hero.page_now, 68)
    eq(m.hero.minutes_left, math.ceil(49153 * 0.62 / 230))
    eq(m.shelf[1].file, "pride", "other books in progress come first")
    eq(m.shelf[1].reason, "in_progress")
    eq(m.shelf[2].file, "frank")
    eq(#m.shelf, 2, "finished and on-hold books stay off the shelf")
    eq(m.is_night, true)
    eq(m.part_of_day, "evening")
end)

test("the page method setting picks the downloaded count", function()
    local m = Context.build(sources({ "gatsby" }), { now = EVENING, page_method = "downloaded" })
    eq(m.hero.page_total, 180)
    eq(m.hero.page_method, "downloaded")
end)

test("finished: the next book in the series is up next", function()
    local m = Context.build(sources({ "s1" }, { "frank", "s2" }), { now = EVENING })
    eq(m.state, "finished")
    eq(m.shelf[1].file, "s2")
    eq(m.shelf[1].reason, "series")
    eq(m.up_next.file, "s2")
end)

test("start and empty", function()
    local m = Context.build(sources({}, { "frank" }), { now = EVENING })
    eq(m.state, "start")
    eq(m.hero.file, "frank")
    eq(Context.build(sources({}, {}), { now = EVENING }).state, "empty")
end)

test("missing files in history are skipped", function()
    local m = Context.build(sources({ "deleted.epub", "gatsby" }), { now = EVENING })
    eq(m.hero.file, "gatsby")
end)

test("durations", function()
    eq(Context.formatDuration(0), "under a minute")
    eq(Context.formatDuration(45), "45 min")
    eq(Context.formatDuration(133), "2 h 13 min")
    eq(Context.formatDuration(600), "10 h")
end)

H.describe("home wording")

local function identity(s) return s end

test("reading copy", function()
    local m = Context.build(sources({ "gatsby", "pride" }, { "frank" }), { now = EVENING })
    local copy = Presenter.present(m, identity, { time = "22:05", battery = 81 })
    eq(copy.status_left, "Monday, 2 November")
    eq(copy.status_right, "22:05 · 81%")
    eq(copy.hero_label, "Continue reading")
    eq(m.hero.progress_line, "Page 68 of 179 · 38%")
    eq(m.hero.time_line, "About 2 h 13 min left")
    eq(m.hero.detail_line, "Fairly easy read · 49,153 words")
    eq(m.shelf[1].shelf_meta, "12%")
    eq(m.shelf[2].shelf_meta, "268 pages")
    eq(m.shelf[2].short_title, "Frankenstein")
end)

test("finished copy points at the next book", function()
    local m = Context.build(sources({ "s1" }, { "s2" }), { now = EVENING })
    Presenter.present(m, identity, {})
    eq(m.hero.time_line, "Next: Saga 2")
    eq(m.shelf[1].shelf_meta, "Next in series")
end)

test("translations and separators are applied", function()
    local es = { ["Continue reading"] = "Seguir leyendo", ["Page %1 of %2 · %3%"] = "Página %1 de %2 · %3 %",
        Monday = "lunes", November = "noviembre", ["%1, %2 %3"] = "%1, %2 de %3" }
    METRICS.gatsby.pages.print = 1790
    local m = Context.build(sources({ "gatsby" }), { now = EVENING })
    local copy = Presenter.present(m, function(s) return es[s] or s end, {}, ".")
    METRICS.gatsby.pages.print = 179
    eq(copy.hero_label, "Seguir leyendo")
    eq(copy.status_left, "lunes, 2 de noviembre")
    eq(m.hero.progress_line, "Página 680 de 1.790 · 38 %")
end)

test("thousands separator", function()
    eq(Presenter.thousands(1234567, ","), "1,234,567")
    eq(Presenter.thousands(999, ","), "999")
end)

H.describe("home layout")

local DEVICES = {
    { width = 600, height = 800, dpi = 167 },
    { width = 758, height = 1024, dpi = 212 },
    { width = 1072, height = 1448, dpi = 300 },
    { width = 1236, height = 1648, dpi = 300 },
    { width = 1860, height = 2480, dpi = 300 },
    { width = 1648, height = 1236, dpi = 300 },
    { width = 800, height = 600, dpi = 167 },
}

local CASES = {
    reading = { { "gatsby", "pride" }, { "frank", "s2" } },
    finished = { { "done" }, { "frank", "s2" } },
    start = { {}, { "frank", "s2" } },
    empty = { {}, {} },
}

local Dashboard = require("sereno/home/dashboard")
local Weather = require("sereno/weather/weather")

local function dashboard(t, history, new, dash)
    local m = Context.build(sources(history, new), { now = EVENING })
    local status = { time = "1:15", battery = 81 }
    Presenter.present(m, identity, status)
    dash = dash or {}
    local copy = Presenter.dashboard(identity, status, EVENING, dash)
    return Dashboard.layout(t, Dashboard.view(m, dash, status), copy), copy
end

local WEEK = { {}, {}, {}, { secs = 2400 }, {}, {}, { secs = 0, today = true } }
local DASH_CASES = {
    { "empty tiles", {} },
    { "full tiles", { tasks = { { text = "Return the library books before Friday afternoon" }, { text = "Buy a reading lamp" },
        { text = "Call Ana" }, { text = "Ticked", done = true } }, week = WEEK, week_secs = 2400, wifi = true,
        weather = { place = "Waddesdon", temp = "11°", glyph = "rain", text = "Light rain" } } },
    { "weather waiting", { weather = { place = "Monterrey" }, wifi = false } },
}

for _i, d in ipairs(DEVICES) do
    for state, case in pairs(CASES) do
        for _k, dc in ipairs(DASH_CASES) do
            test(string.format("%dx%d @%d %s, %s: the tiles fit, nothing overlaps", d.width, d.height, d.dpi, state, dc[1]), function()
                local t = Theme.new(d)
                local nodes = dashboard(t, case[1], case[2], dc[2])
                local problems = Layout.check(t, nodes)
                eq(#problems, 0, table.concat(problems, "; "))
                local ids = {}
                for _j, n in ipairs(nodes) do ids[n.id or ""] = n end
                for _j, id in ipairs({ "hero_tile", "library_tile", "apps_tile", "next_tile", "tasks_tile", "weather_tile", "week_tile",
                    "date", "status_right", "btn_settings", "btn_apps", "btn_add" }) do
                    truthy(ids[id], id .. " shown")
                end
                if state == "reading" then truthy(ids.hero_cover and ids.hero_title, "the book") end
            end)
        end
    end
end

test("every tap target on the home tiles has an action and is touch-sized", function()
    local t = Theme.new(DEVICES[1])
    local nodes = dashboard(t, { "gatsby", "pride" }, { "frank" }, DASH_CASES[2][2])
    local taps, targets = 0, {}
    for _j, n in ipairs(nodes) do
        if n.kind == "tap" then
            taps = taps + 1
            truthy(n.action and n.action.type, "action")
            truthy(n.h >= t.touch * 0.99 and n.w >= t.touch * 0.99, n.id .. " size")
            targets[n.action.target or n.action.type] = true
        end
    end
    for _j, k in ipairs({ "open", "library", "apps", "tasks", "weather", "stats", "settings", "import", "search", "controls", "wifi", "refresh" }) do
        truthy(targets[k], k .. " reachable")
    end
end)

test("the tiles say what's there", function()
    local t = Theme.new(DEVICES[3])
    local nodes, copy = dashboard(t, { "gatsby" }, { "frank" }, DASH_CASES[2][2])
    local texts = {}
    for _j, n in ipairs(nodes) do if n.kind == "text" then texts[n.id] = n.text end end
    eq(copy.date, "Monday 2 November 2026")
    eq(texts.hero_title, "The Great Gatsby")
    eq(texts.hero_percent, "38%")
    eq(texts.next_title, "Frankenstein; or, The Modern Prometheus")
    eq(texts.task_1, "Return the library books before Friday afternoon", "open tasks only")
    eq(texts.weather_temp, "11°")
    eq(texts.weather_heading, "Waddesdon")
    eq(texts.week_total, "40 min reading")
    local empty = dashboard(t, {}, {}, {})
    local e = {}
    for _j, n in ipairs(empty) do if n.kind == "text" then e[n.id] = n.text end end
    eq(e.hero_heading, "No books yet")
    eq(e.tasks_empty, "No tasks")
    eq(e.week_total, "0 min reading")
end)

test("weather: places, readings, symbols and when to ask again", function()
    local place = Weather.parsePlace({ results = { { name = "Monterrey", latitude = 25.6866, longitude = -100.3161, country = "Mexico" } } })
    eq(place.name, "Monterrey")
    eq(select(2, Weather.parsePlace({})), "not_found")
    truthy(Weather.searchUrl("San Pedro Garza García", "es"):find("name=San%20Pedro%20Garza%20Garc%C3%ADa", 1, true))
    place.unit = "F"
    local url = Weather.forecastUrl(place)
    truthy(url:find("latitude=25.6866&longitude=-100.3161", 1, true) and url:find("temperature_unit=fahrenheit", 1, true), url)
    eq(Weather.parseCurrent({ current = { temperature_2m = 10.6, weather_code = 61 } }).temp, 10.6)
    eq(Weather.parseCurrent({ error = true }), nil)
    eq(select(1, Weather.describe(61)), "rain")
    eq(select(2, Weather.describe(2)), "Partly cloudy")
    eq(select(1, Weather.describe(96)), "storm")
    local now = 1800000000
    local saved = { name = "Monterrey", lat = 25.7, lon = -100.3 }
    eq(Weather.display(nil, now), nil, "no town: the tile asks for one")
    eq(Weather.display(saved, now).temp, nil, "no reading yet")
    truthy(Weather.due(saved, now))
    local calls = {}
    local ok = Weather.refresh(saved, now, function(u) calls[#calls + 1] = u return '{"current":{"temperature_2m":23.5,"weather_code":3}}' end,
        function(body) return { current = { temperature_2m = 23.5, weather_code = 3 } } end)
    truthy(ok)
    local shown = Weather.display(saved, now + 60)
    eq(shown.temp, "24°")
    eq(shown.glyph, "cloud")
    eq(Weather.due(saved, now + 60), false, "not again for half an hour")
    eq(Weather.due(saved, now + Weather.REFRESH_SECS), true)
    eq(Weather.display(saved, now + Weather.STALE_SECS + 1).temp, nil, "an old reading isn't shown as today's")
    local failed = { name = "x", lat = 1, lon = 1 }
    eq(Weather.refresh(failed, now, function() return nil, "timeout" end, function() end), false)
    eq(Weather.due(failed, now + 60), false, "a failed try waits too, so a bad network doesn't stall the home screen")
end)

test("wrapping shortens instead of overflowing", function()
    local style = { size = 20, font = "NotoSans" }
    local lines = Layout.wrap("Alice’s Adventures in Wonderland", style, 110, 2)
    eq(#lines, 2)
    truthy(lines[2]:find("…$"), lines[2])
    eq(Layout.wrap("Supercalifragilistic", style, 60, 2)[1]:find("…$") ~= nil, true)
end)

test("a measuring function from the device replaces the estimate", function()
    local t = Theme.new(DEVICES[4])
    t.measure = function() return 7 end
    eq(Layout.estimateLines(t, "x", "body", 100, 3), 3)
end)
