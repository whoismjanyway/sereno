-- Sereno's shell, quick controls and reader bars fit every screen.
local H = require("helper")
local test, eq, truthy = H.it, H.eq, H.truthy
local Theme = require("sereno/ui/theme")
local Layout = require("sereno/home/layout")
local Browse = require("sereno/shell/browse")
local ShellLayout = require("sereno/shell/layout")
local Presenter = require("sereno/home/presenter")
local ControlsLayout = require("sereno/controls/layout")
local ChromeLayout = require("sereno/reader/chrome")

local SCREENS = {
    { "kindle 6\"", 600, 800, 167 }, { "kindle 6\" hd", 758, 1024, 212 }, { "paperwhite 4", 1072, 1448, 300 },
    { "paperwhite 5", 1236, 1648, 300 }, { "oasis", 1264, 1680, 300 }, { "scribe", 1860, 2480, 300 },
    { "landscape", 1448, 1072, 300 },
}

H.describe("shell, controls and bars")

local function fits(name, t, nodes)
    local problems = Layout.check(t, nodes)
    eq(#problems, 0, name .. ": " .. table.concat(problems, "; "))
end

local function sources(n_books, n_dirs)
    local files, dirs = {}, {}
    for i = 1, n_books do files[i] = "/books/Book number " .. i .. ".epub" end
    for i = 1, n_dirs do dirs[i] = { name = "Folder " .. i, path = "/books/f" .. i, count = i } end
    return {
        home_dir = function() return "/books" end,
        list_dir = function() return { dirs = dirs, files = files } end,
        history = function() return { files[1], files[2], files[3] } end,
        collections = function() return { { name = "Favorites", count = 2 }, { name = "Classics", count = 12 } } end,
        collection = function() return { files[1], files[2] } end,
        search = function(q) return q == "none" and {} or { files[4], files[5] } end,
        book_info = function(f)
            local i = tonumber(f:match("(%d+)")) or 0
            return { title = "A rather long title for book " .. i, authors = { "Author " .. (i % 7) },
                percent = i % 3 == 0 and 0.4 or 0, status = i == 1 and "reading" or "new", mtime = i }
        end,
    }
end

for _i, scr in ipairs(SCREENS) do
    local t = Theme.new{ width = scr[2], height = scr[3], dpi = scr[4] }
    test(scr[1] .. ": every tab fits", function()
        local src = sources(40, 5)
        for _j, case in ipairs({
            { "library", {} }, { "library", { page = 2 } }, { "history", {} }, { "collections", {} },
            { "collections", { collection = "Classics" } }, { "search", {} }, { "search", { query = "book" } },
            { "search", { query = "none" } },
        }) do
            local model = Browse.build(case[1], case[2], src)
            local copy = Presenter.browse(model, function(s) return s end, { time = "9:41", battery = 80 })
            local nodes, paging = ShellLayout.browse(t, model, copy, case[2].page)
            fits(case[1], t, nodes)
            if case[1] == "library" then
                truthy(paging.per_page >= (t.landscape and 5 or 6), "at least two rows of three: " .. paging.per_page)
                truthy(paging.pages > 1, "40 books and 5 folders take more than a page")
            end
        end
    end)
    test(scr[1] .. ": quick controls fit and leave the page visible", function()
        local state = { time = "9:41", battery = 80, wifi = true, night = false, has_frontlight = true, light_on = true,
            brightness = 12, brightness_max = 24, has_warmth = true, warmth = 30 }
        local nodes, bottom = ControlsLayout.layout(t, state, { wifi = "Wi-Fi", night = "Night", light = "Light", rotate = "Rotate",
            restart = "Restart", sleep = "Sleep", brightness = "Brightness: %d", warmth = "Warmth: %d",
            koreader_menu = "KOReader menu", files = "File browser" })
        fits("controls", t, nodes)
        truthy(bottom < t.height * 0.85, "sheet bottom " .. bottom .. " of " .. t.height)
        local taps = 0
        for _j, n in ipairs(nodes) do
            if n.kind == "tap" then
                taps = taps + 1
                truthy(n.h >= t.touch * 0.9 or n.action.type == "close", n.id .. " is a real touch target")
            end
        end
        truthy(taps >= 12, "buttons, sliders, menus")
    end)
    test(scr[1] .. ": the reader's bars fit and leave most of the page", function()
        local state = { title = "The Great Gatsby · F. Scott Fitzgerald", chapter = "Chapter III", page_label = "68",
            total_label = "179", percent = 0.38, ticks = { 0, 0.2, 0.5 }, can_prev = true, can_next = true, back_label = "Back to page 12" }
        local nodes, geo = ChromeLayout.layout(t, state, { home = "Home", page_of = "Page %s of %s" })
        fits("bars", t, nodes)
        local colors = {}
        for _j, n in ipairs(nodes) do if n.id == "prev_chapter" or n.id == "next_chapter" then colors[n.id] = n.color end end
        eq(colors.prev_chapter, "text")
        eq(colors.next_chapter, "text")
        local first = ChromeLayout.layout(t, { title = "x", percent = 0, can_prev = false, can_next = true }, { home = "Home" })
        for _j, n in ipairs(first) do
            if n.id == "prev_chapter" then eq(n.color, "secondary", "nothing before the first chapter") end
            if n.id == "next_chapter" then eq(n.color, "text") end
        end
        truthy(geo.bottom_y - geo.top_h > t.height * 0.5, "page between the bars")
    end)
end

test("the sleep screen fits every screen", function()
    local SleepLayout = require("sereno/sleep/layout")
    for _i, scr in ipairs(SCREENS) do
        local w, h = scr[2], scr[3]
        if w > h then w, h = h, w end
        local t = Theme.new{ width = w, height = h, dpi = scr[4] }
        for _j, book in ipairs({ { file = "/b/x.epub", title = "The Great Gatsby", authors = "F. Scott Fitzgerald", percent = 0.38 }, false }) do
            local nodes = SleepLayout.layout(t, book or nil, { progress = "Page 68 of 179 · 38%", date = "Monday, 2 November", logo = "x.svg" })
            local inner = {}
            for _k, n in ipairs(nodes) do if n.id ~= "paper" then inner[#inner + 1] = n end end
            fits(scr[1] .. " sleep", t, inner)
        end
    end
end)

test("the Stats and Import tabs fit every screen", function()
    local Stats = require("sereno/stats/stats")
    local raw = { today = "2026-11-04", days = { ["2026-11-04"] = { secs = 4920, pages = 136 }, ["2026-11-02"] = { secs = 7800, pages = 210 } },
        dates = { "2026-11-04", "2026-11-03", "2026-11-02" }, total = { secs = 1123200, books = 48 },
        book = { title = "The Great Gatsby", pages = 180, read_secs = 31500, read_pages = 140, days = 7, percent = 0.78 } }
    local model = Stats.summarize(raw)
    for _i, scr in ipairs(SCREENS) do
        local t = Theme.new{ width = scr[2], height = scr[3], dpi = scr[4] }
        local copy = Presenter.stats(model, function(s) return s end, { time = "9:41", battery = 80 }, ",", Stats.duration)
        fits(scr[1] .. " stats", t, ShellLayout.stats(t, model, copy))
        fits(scr[1] .. " stats empty", t, ShellLayout.stats(t, { empty = true, week = {} }, copy))
        local items = {
            { id = "wifi_send", icon = "wifi", title = "From a browser, over Wi-Fi", subtitle = "Drag books from your computer or phone into a page on the same Wi-Fi. KOReader stays open." },
            { id = "cable", icon = "appbar.filebrowser", title = "With a cable", subtitle = "Kindle's USB drive works only outside KOReader: Sereno closes it, you copy books into documents, eject, and reopen KOReader." },
            { id = "calibre_connect", icon = "book.opened", title = "Calibre, wirelessly", subtitle = "Send books from calibre on your computer, then tap here." },
            { id = "opds", glyph = "download", title = "Online catalogs (OPDS)", subtitle = "Free libraries and your own catalogs." },
        }
        local nodes = ShellLayout.import(t, items, Presenter.import(function(s) return s end, {}))
        fits(scr[1] .. " import", t, nodes)
        local taps = 0
        for _k, n in ipairs(nodes) do if n.kind == "tap" and n.action.type == "import" then taps = taps + 1 end end
        eq(taps, #items, scr[1] .. ": every way to import is on screen")
    end
end)

test("reading statistics: streak, averages, time left", function()
    local Stats = require("sereno/stats/stats")
    eq(Stats.streak({ "2026-11-04", "2026-11-03", "2026-11-02", "2026-10-30" }, "2026-11-04"), 3)
    eq(Stats.streak({ "2026-11-03", "2026-11-02" }, "2026-11-04"), 2, "today not read yet: the streak still stands")
    eq(Stats.streak({ "2026-11-01" }, "2026-11-04"), 0)
    local m = Stats.summarize({ today = "2026-11-04", days = { ["2026-11-04"] = { secs = 3600, pages = 70 }, ["2026-10-30"] = { secs = 3600, pages = 70 } },
        dates = { "2026-11-04" }, total = { secs = 7200, books = 1 },
        book = { title = "x", pages = 200, read_secs = 6000, read_pages = 100, days = 2, percent = 0.5 } })
    eq(m.today_pages, 70)
    eq(m.pages_per_day, 20, "140 pages over 7 days")
    eq(m.daily_avg_secs, 1029)
    eq(m.book.left_secs, 6000, "60 s a page, 100 pages to go")
    eq(#m.week, 7)
    eq(m.week[7].date, "2026-11-04", "today last")
    eq(Stats.duration(8100), "2 h 15 min")
    eq(Stats.duration(20), "under a minute")
end)

test("the book page: spaced capitals, centred in the margins", function()
    local Folio = require("sereno/reader/folio")
    eq(Folio.head("El hobbit"), "E\u{200A}L\u{200A}\u{2002}\u{200A}H\u{200A}O\u{200A}B\u{200A}B\u{200A}I\u{200A}T")
    local pos = Folio.place(1648, 140, 130, 30, 34)
    truthy(pos.head_y > 0 and pos.head_y + 30 <= 140, "head inside the top margin")
    truthy(pos.folio_y >= 1648 - 130 and pos.folio_y + 34 <= 1648, "page number inside the bottom margin")
    local RL = require("sereno/reader/layout")
    local PW = { width = 1236, height = 1648, dpi = 300 }
    local book = RL.compute(PW, RL.spec({ page = "normal" }))
    local bar = RL.compute(PW, RL.spec({ page = "normal", folio = false }))
    truthy(book.physical.top_mm >= RL.FOLIO_TOP_MM - 0.5 and book.physical.bottom_mm >= RL.FOLIO_BOTTOM_MM - 0.5, "room for head and folio")
    truthy(bar.t_margin < book.t_margin, "the status bar style keeps the plain margins")
end)

test("search matches every word, in any case", function()
    truthy(Browse.matches("great gatsby", "The Great Gatsby", "Fitzgerald", "/b/x.epub"))
    truthy(Browse.matches("FITZ", "The Great Gatsby", "F. Scott Fitzgerald", "/b/x.epub"))
    truthy(Browse.matches("x.epub", nil, nil, "/b/x.epub"))
    eq(Browse.matches("great dracula", "The Great Gatsby", "", "/b/x.epub"), false)
end)

test("sorting and the reading list", function()
    local src = sources(5, 0)
    local m = Browse.build("library", { sort = "recent" }, src)
    eq(m.items[1].kind, "collection", "Collections, as the Library's first tile")
    eq(m.items[1].link, true)
    eq(m.items[2].file, "/books/Book number 5.epub")
    eq(Browse.nextSort("title"), "author")
    eq(Browse.nextSort("recent"), "title")
    local h = Browse.build("history", {}, src)
    eq(h.items[1].file, "/books/Book number 1.epub", "the book being read comes first")
end)
