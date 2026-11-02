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
        truthy(geo.bottom_y - geo.top_h > t.height * 0.5, "page between the bars")
    end)
end

test("search matches every word, in any case", function()
    truthy(Browse.matches("great gatsby", "The Great Gatsby", "Fitzgerald", "/b/x.epub"))
    truthy(Browse.matches("FITZ", "The Great Gatsby", "F. Scott Fitzgerald", "/b/x.epub"))
    truthy(Browse.matches("x.epub", nil, nil, "/b/x.epub"))
    eq(Browse.matches("great dracula", "The Great Gatsby", "", "/b/x.epub"), false)
end)

test("sorting and the reading list", function()
    local src = sources(5, 0)
    local m = Browse.build("library", { sort = "recent" }, src)
    eq(m.items[1].file, "/books/Book number 5.epub")
    eq(Browse.nextSort("title"), "author")
    eq(Browse.nextSort("recent"), "title")
    local h = Browse.build("history", {}, src)
    eq(h.items[1].file, "/books/Book number 1.epub", "the book being read comes first")
end)
