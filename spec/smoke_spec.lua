-- Loads main.lua against stubbed KOReader modules and walks every menu
-- entry, to catch runtime errors before trying the plugin on a device.
local H = require("helper")
local test, eq, truthy = H.it, H.eq, H.truthy
local S = require("koreader_stubs")

package.path = "sereno.koplugin/?.lua;" .. package.path
local Sereno = dofile("sereno.koplugin/main.lua")

local function walk(items, depth)
    for _i, item in ipairs(items or {}) do
        if item.text_func then truthy(type(item.text_func()) == "string", "text_func returns a string") end
        if item.checked_func then item.checked_func() end
        if item.enabled_func then item.enabled_func() end
        local sub = item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
        if sub and depth < 4 then walk(sub, depth + 1) end
    end
end

local function newUI(ctx)
    local ui = {
        menu = { registerToMainMenu = function() end },
        registerModule = function() end,
    }
    if ctx == "reader" then
        ui.document = { file = "/books/x.epub" }
    else
        ui.addFileDialogButtons = function(_self, id, fn) S.file_dialog_rows[id] = fn end
    end
    return ui
end

local function findItem(menu, text)
    for _i, it in ipairs(menu) do
        if it.text == text or (it.text_func and it.text_func() == text) then return it end
    end
end

for _i, ctx in ipairs({ "filemanager", "reader" }) do
    H.describe("plugin smoke test: " .. ctx)
    local p
    test("init", function() p = Sereno:new{ ui = newUI(ctx) } end)
    test("adds its menu entry and collects labels", function()
        local items = { table_of_contents = { text = "Table of contents" }, change_font = { text_func = function() return "Font" end } }
        p:addToMainMenu(items)
        truthy(items.sereno and items.sereno.sub_item_table_func)
        eq(p:labelFor("table_of_contents"), "Table of contents")
    end)
    test("enabling tiers writes KOReader's menu order file", function()
        p:setEnabled(true)
        truthy(io.open(S.settings_dir .. "/" .. ctx .. "_menu_order.lua"), "order file written")
    end)
    test("every menu entry can be walked", function()
        walk(p:getMainMenu(), 0)
    end)
    test("dispatcher actions cycle the level", function()
        for _j = 1, 3 do p:onSerenoCycleTier() end
        p:onSerenoSetTier(1)
        eq(p:getTier(), 1)
        local order = dofile(S.settings_dir .. "/reader_menu_order.lua")
        truthy(#order["KOMenu:disabled"] > 0, "Reading level hides options")
    end)
    test("customizing an item stores an override", function()
        local customize = findItem(p:getTiersMenu(), "Customize levels")
        local menus = customize.sub_item_table_func()
        local fake_tm = { updateItems = function() end }
        for _j, m in ipairs(menus) do
            if m.sub_item_table_func then
                local items = m.sub_item_table_func()
                if #items > 0 then items[1].callback(fake_tm) break end
            end
        end
        truthy(next(p:getOverrides()), "override saved")
        menus[1].callback()
    end)
end

H.describe("plugin smoke test: home screen and metrics")

local function setupLibrary()
    local dir = S.settings_dir .. "/books"
    os.execute(string.format('mkdir -p %q && cp spec/fixtures/sample.epub %q/novel.epub && cp spec/fixtures/sample.epub %q/other.epub && cp spec/fixtures/sample.cbz %q/comic.cbz',
        dir, dir, dir, dir))
    S.home_dir = dir
    package.loaded["readhistory"].hist = { { file = dir .. "/novel.epub" } }
    package.loaded["ui/widget/booklist"].getBookInfo = function(file)
        if file:find("novel", 1, true) then return { been_opened = true, status = "reading", percent_finished = 0.4 } end
        return { been_opened = false }
    end
    return dir
end

test("the home screen builds, paints and counts missing books", function()
    local dir = setupLibrary()
    local p = Sereno:new{ ui = newUI("filemanager") }
    -- the home screen now opens at start-up by default
    S.runScheduled()
    eq(S.shown[#S.shown].name, "sereno_home", "home at start-up")
    p:showHome()
    local home = S.shown[#S.shown]
    eq(home.name, "sereno_home")
    eq(home.model.state, "reading")
    eq(home.model.hero.file, dir .. "/novel.epub")
    truthy(#home.model.shelf >= 1, "unopened books on the shelf")
    home:onShow()
    local bb = S.fakeBB()
    home:paintTo(bb, 0, 0)
    truthy(#bb.calls > 5, "drew something")
    -- background counting fills the metrics cache, then the screen updates
    for _i = 1, 40 do S.runScheduled() end
    local Service = require("sereno/metrics/service")
    truthy(Service.peek(dir .. "/novel.epub"), "hero counted")
    truthy(home.model.hero.page_total and home.model.hero.page_total > 0, "page count shown after update")
    truthy(home.model.hero.progress_line:find("Page", 1, true), home.model.hero.progress_line)
    eq(home.model.hero.title, "Cien años de prueba: una novela", "title read from the book itself")
end)

test("taps open books, and the tabs stay in Sereno", function()
    local dir = setupLibrary()
    local p = Sereno:new{ ui = newUI("filemanager") }
    p:showHome()
    local home = S.shown[#S.shown]
    local function tapWhere(pred)
        for _i, n in ipairs(home.nodes) do
            if n.kind == "tap" and pred(n.action) then
                home:onTap(nil, { pos = { x = n.x + 1, y = n.y + 1 } })
                return n
            end
        end
    end
    -- every tab is a Sereno screen: KOReader's file manager is never asked
    for _i, tab in ipairs({ "library", "history", "collections", "search", "home" }) do
        truthy(tapWhere(function(a) return a.type == "nav" and a.target == tab end), "tab " .. tab)
        eq(home.tab, tab)
        eq(S.shown[#S.shown], home, "still the same Sereno window")
        local bb = S.fakeBB()
        home:paintTo(bb, 0, 0)
        truthy(#bb.calls > 2, tab .. " drew something")
    end
    eq(#S.fm_calls, 0, "no detour through KOReader's file manager")
    -- the library lists the books folder, opens books, sorts
    home:showTab("library")
    eq(home.browse.path, dir)
    truthy(#home.browse.items >= 3, "books in the library: " .. #home.browse.items)
    truthy(tapWhere(function(a) return a.type == "sort" end), "sort pill")
    eq(home.states.library.sort, "author")
    truthy(tapWhere(function(a) return a.type == "open" end), "a book")
    truthy(#S.opened >= 1, "a book was opened")
end)

test("the library goes into folders and back, and pages with swipes", function()
    local dir = setupLibrary()
    os.execute(string.format("mkdir -p %q/sub && for i in $(seq 1 30); do cp spec/fixtures/sample.epub %q/sub/b$i.epub; done", dir, dir))
    local p = Sereno:new{ ui = newUI("filemanager") }
    local home = p:showHome("library")
    local folder
    for _i, it in ipairs(home.browse.items) do if it.kind == "folder" then folder = it end end
    truthy(folder and folder.count == 30, "folder tile with its count")
    home:handle({ type = "folder", path = folder.path })
    eq(home.browse.title, "sub")
    truthy(home.browse.back, "a way back up")
    truthy(home.paging.pages > 1, "30 books take more than one page")
    home:onSwipe(nil, { direction = "west", pos = { x = 100, y = 400 } })
    eq(home.paging.page, 2)
    home:onSwipe(nil, { direction = "east", pos = { x = 100, y = 400 } })
    eq(home.paging.page, 1)
    home:handle(home.browse.back)
    eq(home.browse.path, dir)
    os.execute(string.format("rm -rf %q/sub", dir))
end)

test("search finds books by file name", function()
    setupLibrary()
    local p = Sereno:new{ ui = newUI("filemanager") }
    local home = p:showHome("search")
    home:setQuery("novel")
    eq(#home.browse.items, 1)
    home:setQuery("nothing-like-this")
    eq(#home.browse.items, 0)
end)

test("a swipe down from the top opens the quick controls", function()
    local p = Sereno:new{ ui = newUI("filemanager") }
    local home = p:showHome()
    home:onSwipe(nil, { direction = "south", pos = { x = 100, y = 5 } })
    local controls = S.shown[#S.shown]
    eq(controls.name, "sereno_overlay")
    local bb = S.fakeBB()
    controls:paintTo(bb, 0, 0)
    truthy(#bb.calls > 10, "controls drew")
    local ids = {}
    for _i, n in ipairs(controls.nodes) do if n.kind == "tap" then ids[#ids + 1] = n.action.type .. ":" .. tostring(n.action.id) end end
    local all = table.concat(ids, " ")
    truthy(all:find("toggle:night", 1, true) and all:find("toggle:sleep", 1, true), all)
    -- night mode is a KOReader event, broadcast to every window
    for _i, n in ipairs(controls.nodes) do
        if n.kind == "tap" and n.action.id == "night" then controls:onTap(nil, { pos = { x = n.x + 1, y = n.y + 1 } }) end
    end
    truthy(H.contains(S.events, "ToggleNightMode"), "night mode toggled")
    -- a tap below the sheet closes it
    controls:onTap(nil, { pos = { x = 10, y = 1440 } })
    eq(S.closed[#S.closed], controls)
end)

test("long-press and file dialog show the metrics dialog", function()
    local dir = setupLibrary()
    local p = Sereno:new{ ui = newUI("filemanager") }
    local before = #S.shown
    p:showMetrics(dir .. "/novel.epub")
    local page = S.shown[#S.shown]
    truthy(#S.shown > before and page.kv_pairs, "key/value page shown")
    local keys = {}
    for _i, row in ipairs(page.kv_pairs) do keys[#keys + 1] = row[1] end
    local all = table.concat(keys, "|")
    truthy(all:find("Print model", 1, true) and all:find("Words", 1, true) and all:find("Readability", 1, true), all)
    local row = S.file_dialog_rows.sereno_metrics(dir .. "/novel.epub", true)
    eq(row[1].text, "Pages & readability")
    eq(S.file_dialog_rows.sereno_metrics(dir, false), nil)
end)

test("page counts menu walks and switches method", function()
    local p = Sereno:new{ ui = newUI("filemanager") }
    local menu = p:getPagesMenu()
    walk(menu, 0)
    -- first: pages or Kindle-style locations
    menu[2].callback()
    eq(p.settings:readSetting("position"), "locations")
    eq(p:homeOptions().page_method, "locations")
    menu[1].callback()
    eq(p.settings:readSetting("position"), nil)
    menu[4].callback()
    eq(p.settings:readSetting("page_method"), "downloaded")
    menu[3].callback()
    eq(p.settings:readSetting("page_method"), "print")
end)

test("counting a whole folder", function()
    local dir = setupLibrary()
    local ui = newUI("filemanager")
    ui.file_chooser = { path = dir }
    local p = Sereno:new{ ui = ui }
    p:countFolder()
    local msg = S.shown[#S.shown]
    truthy(msg.text and msg.text:find("Counted", 1, true), msg.text)
end)

test("the reader asks for the home screen after closing a book", function()
    local p = Sereno:new{ ui = newUI("reader") }
    p:onCloseDocument()
    local before = #S.shown
    Sereno:new{ ui = newUI("filemanager") }
    S.runScheduled()
    truthy(#S.shown > before and S.shown[#S.shown].name == "sereno_home", "home shown")
end)

H.describe("plugin smoke test: reading layout")

test("reading settings: the panel, two switches, and the way back", function()
    local ui = newUI("reader")
    ui.rolling = {}
    ui.typeset = {}
    ui.document.configurable = {}
    local events = {}
    ui.handleEvent = function(_self, e) events[#events + 1] = e end
    local p = Sereno:new{ ui = ui }
    S.global.copt_font_size = 30 -- the user's own default, to be kept aside
    S.global.cre_font = "My Font"
    local menu = p:getReadingMenu()
    walk(menu, 0)
    eq(menu[1].text, "Font, size and page…")
    eq(#menu, 4, "the panel, justified, book paragraphs, defaults")
    menu[2].callback() -- justified off
    eq(p:currentSpec().align, "left")
    truthy(S.global.style_tweaks and S.global.style_tweaks.text_align_most_left, "left alignment set as a KOReader style tweak")
    truthy(S.global.copt_font_size ~= 30, "Sereno's layout became the default")
    menu[2].callback()
    eq(p:currentSpec().align, "justify")
    menu[#menu].callback() -- back to the user's previous defaults
    eq(S.global.copt_font_size, 30, "previous default restored")
    eq(S.global.copt_h_page_margins, nil)
    eq(S.global.style_tweaks.paragraph_indent, nil, "style tweaks restored")
    eq(S.global.cre_font, "My Font")
end)

test("the text panel: font, size and page, one re-flow per tap", function()
    local ui = newUI("reader")
    ui.rolling = {}
    ui.typeset = {}
    ui.document.configurable = {}
    ui.font = { font_face = "Noto Serif" }
    local events = {}
    ui.handleEvent = function(_self, e) events[#events + 1] = e end
    package.loaded["fontlist"] = { fontinfo = {
        ["/f/NotoSerif-Regular.ttf"] = { { name = "Noto Serif" } },
        ["/f/NotoSerif-Bold.ttf"] = { { name = "Noto Serif", bold = true } },
        ["/f/Literata.ttf"] = { { name = "Literata" } },
        ["/f/FreeSerif.ttf"] = { { name = "FreeSerif" } },
        ["/f/Odd.ttf"] = { { name = "Odd Display" } },
    } }
    local p = Sereno:new{ ui = ui }
    local items = {}
    p:addToMainMenu(items)
    eq(items.sereno_page.sorting_hint, "typeset")
    local fonts = p:fontChoices()
    eq(#fonts, 3, "only fonts worth offering, one entry each")
    eq(fonts[1].name, "Literata")
    local panel = p:showPagePanel()
    eq(S.shown[#S.shown], panel)
    local bb = S.fakeBB()
    panel:paintTo(bb, 0, 0)
    truthy(#bb.calls > 10, "panel drew")
    local kinds = {}
    for _i, n in ipairs(panel.nodes) do if n.kind == "tap" then kinds[n.action.key or n.action.type] = true end end
    truthy(kinds.font and kinds.size and kinds.page and not kinds.align and not kinds.spacing, "only font, size and page")
    local function tapOn(pred)
        for _i, n in ipairs(panel.nodes) do
            if n.kind == "tap" and pred(n.action) then
                panel:onTap(nil, { pos = { x = n.x + 1, y = n.y + 1 } })
                return true
            end
        end
    end
    truthy(tapOn(function(a) return a.key == "page" and a.value == "roomy" end), "page option")
    local names = {}
    for _i, e in ipairs(events) do names[#names + 1] = e.name end
    eq(table.concat(names, ","), "SetLineSpace,SetPageMargins", "margins and spacing together")
    eq(p:currentSpec().page, "roomy")
    events = {}
    truthy(tapOn(function(a) return a.key == "font" and a.value == "Literata" end), "font option")
    eq(events[1].name, "SetFont")
    eq(events[1].args[1], "Literata")
    eq(S.global.cre_font, "Literata", "new books open in it too")
    events = {}
    tapOn(function(a) return a.type == "size" and a.delta > 0 end)
    eq(events[1].name, "SetFontSize")
    local before = #S.closed
    panel:onTap(nil, { pos = { x = 5, y = 5 } }) -- above the sheet
    truthy(#S.closed > before, "tap above the sheet closes it")
    package.loaded["fontlist"] = nil
end)

test("the panel fits every screen without overlaps", function()
    local Panel = require("sereno/reader/panel")
    local Theme = require("sereno/ui/theme")
    local ReaderLayout = require("sereno/reader/layout")
    local fonts = { { name = "Literata" }, { name = "Noto Serif" }, { name = "FreeSerif" }, { name = "Noto Sans" } }
    for _i, scr in ipairs({ { 600, 800, 167 }, { 758, 1024, 212 }, { 1072, 1448, 300 }, { 1236, 1648, 300 }, { 1860, 2480, 300 }, { 1448, 1072, 300 } }) do
        local screen = { width = scr[1], height = scr[2], dpi = scr[3] }
        local t = Theme.new(screen)
        local nodes, top = Panel.layout(t, ReaderLayout.compute(screen, "normal"), nil, fonts)
        truthy(top > t.height * 0.25, scr[1] .. "x" .. scr[2] .. ": the sheet leaves the book visible (top " .. top .. ")")
        local problems = require("sereno/home/layout").check(t, nodes)
        eq(#problems, 0, table.concat(problems, "; "))
        local pages = 0
        for _j, a in ipairs(nodes) do if a.kind == "page" then pages = pages + 1 end end
        eq(pages, 3)
    end
end)

test("the reader can use Sereno's page count as its page numbers", function()
    local dir = S.settings_dir .. "/books"
    local ui = newUI("reader")
    ui.document.file = dir .. "/novel.epub"
    ui.rolling = {}
    local built
    ui.pagemap = { setSyntheticPagesNumber = function(_self, n) built = n end }
    local ds = {}
    ui.doc_settings = { saveSetting = function(_, k, v) ds[k] = v end, readSetting = function(_, k) return ds[k] end }
    local p = Sereno:new{ ui = ui }
    local ok, pages = p:applyPageNumbers(false)
    truthy(ok, tostring(pages))
    eq(built, pages)
    eq(ui.pagemap.use_page_labels, true)
    eq(ds.sereno_page_numbers, pages)
    ui.pagemap.has_pagemap_document_provided = true
    eq(p:applyPageNumbers(false), false, "publisher numbers are kept")
    walk(p:getPagesMenu(), 0)
end)

test("PDFs are left alone", function()
    local ui = newUI("reader")
    ui.document.configurable = {}
    local p = Sereno:new{ ui = ui }
    local values = require("sereno/reader/layout").compute({ width = 1072, height = 1448, dpi = 300 }, "paperback")
    eq(p:applyReadingLayout(values), false)
end)

H.describe("plugin smoke test: reader bars")

local function readerUI()
    local ui = newUI("reader")
    ui.rolling = {}
    local zones
    ui.registerTouchZones = function(_self, z) zones = z end
    local page = 40
    ui.document = {
        file = "/books/x.epub",
        getProps = function() return { title = "The Great Gatsby", authors = "F. Scott Fitzgerald" } end,
        getCurrentPage = function() return page end,
        getPageCount = function() return 200 end,
    }
    ui.toc = {
        getTocTitleByPage = function() return "Chapter III" end,
        getTocTicksFlattened = function() return { 1, 30, 60, 90 } end,
        getPreviousChapter = function(_self, p) return p > 30 and 30 or 1 end,
        getNextChapter = function(_self, p) return p < 60 and 60 or nil end,
        onShowToc = function() S.events[#S.events + 1] = "ShowToc" end,
    }
    ui.link = { addCurrentLocationToStack = function() end, onGoBackLink = function() page = 40 end }
    ui.handleEvent = function(_self, e)
        S.events[#S.events + 1] = e.name
        if e.name == "GotoPage" then page = e.args[1] end
    end
    ui.onClose = function() S.events[#S.events + 1] = "CloseReader" end
    return ui, function() return zones end, function() return page end
end

test("taps at the top or bottom show Sereno's bars instead of KOReader's menus", function()
    local ui, zones, page = readerUI()
    local p = Sereno:new{ ui = ui }
    p.settings:delSetting("position")
    local z = zones()
    truthy(z and #z == 3, "touch zones registered")
    local by_id = {}
    for _i, zone in ipairs(z) do by_id[zone.id] = zone end
    truthy(H.contains(by_id.sereno_top_tap.overrides, "readermenu_tap"), "placed before KOReader's top menu")
    truthy(H.contains(by_id.sereno_bottom_tap.overrides, "readerconfigmenu_tap"), "and its bottom menu")
    truthy(by_id.sereno_top_tap.handler({}), "handled")
    local chrome = S.shown[#S.shown]
    eq(chrome.name, "sereno_overlay")
    local bb = S.fakeBB()
    chrome:paintTo(bb, 0, 0)
    local texts = {}
    for _i, n in ipairs(chrome.nodes) do if n.kind == "text" then texts[#texts + 1] = n.text end end
    local all = table.concat(texts, " | ")
    truthy(all:find("Chapter III", 1, true) and all:find("Page 40 of 200", 1, true), all)
    local function tap(pred)
        for _i, n in ipairs(chrome.nodes) do
            if n.kind == "tap" and pred(n.action) then
                chrome:onTap(nil, { pos = { x = n.x + math.floor(n.w * 0.75), y = n.y + 1 } })
                return n
            end
        end
    end
    -- next chapter, then the way back
    tap(function(a) return a.type == "next_chapter" end)
    eq(page(), 60)
    local back = false
    for _i, n in ipairs(chrome.nodes) do if n.id == "back_label" then back = n.text end end
    eq(back, "Back to page 40")
    tap(function(a) return a.type == "back" end)
    eq(page(), 40)
    -- a tap on the slider at 3/4 goes three quarters into the book
    tap(function(a) return a.type == "seek" end)
    truthy(page() > 140 and page() < 160, "slider jump: " .. page())
    -- tools close the bars and open KOReader's own screens
    tap(function(a) return a.type == "toc" end)
    S.runScheduled()
    truthy(H.contains(S.events, "ShowToc"), "contents")
    -- a swipe down from the top edge: quick controls
    truthy(by_id.sereno_top_swipe.handler({ direction = "south" }), "swipe down")
    eq(S.shown[#S.shown].name, "sereno_overlay")
    eq(by_id.sereno_top_swipe.handler({ direction = "west" }), nil, "other swipes go to KOReader")
    -- with the setting off, KOReader's menus come back
    p.settings:saveSetting("reader_bars", false)
    eq(by_id.sereno_top_tap.handler({}), nil)
    p.settings:saveSetting("reader_bars", true)
end)

test("Home in the bars goes to Sereno's home, never out of KOReader", function()
    local ui, zones = readerUI()
    ui.onHome = function() S.events[#S.events + 1] = "ReaderHome" end
    Sereno:new{ ui = ui }
    zones()[1].handler({})
    local chrome = S.shown[#S.shown]
    for _i, n in ipairs(chrome.nodes) do
        if n.kind == "tap" and n.action.type == "home" then chrome:onTap(nil, { pos = { x = n.x + 1, y = n.y + 1 } }) end
    end
    S.runScheduled()
    truthy(H.contains(S.events, "ReaderHome"), "KOReader's own Home: closes the book and opens the file manager")
    eq(H.contains(S.events, "CloseReader"), false, "never a bare close, which quits KOReader when it started in the book")
end)

test("locations, like a Kindle: one every 128 characters, from the character-based page map", function()
    local ui = readerUI()
    ui.pagemap = {
        chars_per_synthetic_page = 1280,
        wantsPageLabels = function() return true end,
        getCurrentPageLabel = function() return "12", 12, 180 end,
        getLastPageLabel = function() return "180" end,
    }
    local p = Sereno:new{ ui = ui }
    p.settings:saveSetting("position", "locations")
    local pos = p:readerPosition(40, 200)
    eq(pos.kind, "locations")
    eq(pos.now, "111", "page 12 starts at character 14,080: location 111")
    eq(pos.total, "1,800")
    eq(p:chromeCopy().page_of, "Location %s of %s")
    p.settings:delSetting("position")
    pos = p:readerPosition(40, 200)
    eq(pos.kind, "pages")
    eq(pos.now, "12")
    eq(pos.total, "180", "the same numbers whatever the screen page")
end)

test("the home screen redoes its layout when the screen rotates", function()
    local p = Sereno:new{ ui = newUI("filemanager") }
    local home = p:showHome()
    local Device = require("device")
    local gw, gh = Device.screen.getWidth, Device.screen.getHeight
    Device.screen.getWidth, Device.screen.getHeight = gh, gw
    home:onSetDimensions()
    eq(home.theme.width, 1448)
    eq(home.theme.landscape, true)
    Device.screen.getWidth, Device.screen.getHeight = gw, gh
    home:onSetDimensions()
    eq(home.theme.width, 1072)
end)

H.describe("plugin smoke test: settings and sleep screen")

test("one settings screen: Sereno's tab first, then KOReader's own tabs unchanged", function()
    local ui = newUI("filemanager")
    local ko_tabs = { { icon = "appbar.settings", { text = "KOReader item" } }, { icon = "appbar.tools", { text = "Tools" } } }
    ui.menu.tab_item_table = ko_tabs
    local p = Sereno:new{ ui = ui }
    local _touch, tabs = p:showSettings()
    eq(#tabs, 3)
    eq(tabs[2], ko_tabs[1], "KOReader's tab, the same table")
    eq(tabs[3], ko_tabs[2])
    local labels = {}
    for _i, item in ipairs(tabs[1]) do labels[#labels + 1] = item.text end
    local all = table.concat(labels, "|")
    truthy(all:find("Home screen", 1, true) and all:find("Sleep screen", 1, true) and all:find("Reader", 1, true), all)
    walk(tabs[1], 0)
    -- the quick controls and the reader's ⋮ open it
    local home = p:showHome()
    local controls = p:showControls()
    for _i, n in ipairs(controls.nodes) do
        if n.kind == "tap" and n.action.type == "koreader_menu" then controls:onTap(nil, { pos = { x = n.x + 1, y = n.y + 1 } }) end
    end
    local before = #S.touchmenus
    S.runScheduled()
    truthy(#S.touchmenus > before, "settings opened from the quick controls")
    local _ = home
end)

test("Sereno's sleep screen uses KOReader's own, and gives it back", function()
    setupLibrary()
    local p = Sereno:new{ ui = newUI("filemanager") }
    S.global.screensaver_type = "cover"
    S.global.screensaver_dir = "/my/wallpapers"
    S.global.lastfile = S.settings_dir .. "/books/novel.epub"
    local menu = p:getSleepMenu()
    eq(#menu, 2)
    eq(menu[2].sub_item_table[1].text, "Wallpaper", "KOReader's own sleep screen menu, unchanged")
    menu[1].callback()
    truthy(p:isSleepScreenOn())
    eq(S.global.screensaver_type, "random_image")
    eq(S.global.screensaver_dir, p:sleepDir())
    truthy(S.png_written[#S.png_written]:find("sereno%-sleep/sleep%.png$"), "image drawn")
    -- KOReader draws its sleep screen first; Sereno only closes its sheets and redraws for next time
    p:showControls()
    p:onSuspend()
    eq(S.closed[#S.closed].name, "sereno_overlay", "sheets closed before sleeping")
    local n = #S.png_written
    S.runScheduled()
    truthy(#S.png_written > n, "next sleep image prepared")
    p:onResume()
    menu[1].callback()
    eq(p:isSleepScreenOn(), false)
    eq(S.global.screensaver_type, "cover", "the user's choice is back")
    eq(S.global.screensaver_dir, "/my/wallpapers")
end)

test("a user's own sleep screen is left alone", function()
    local p = Sereno:new{ ui = newUI("filemanager") }
    S.global.screensaver_type = "random_image"
    S.global.screensaver_dir = "/my/wallpapers"
    local n = #S.png_written
    p:onSuspend()
    S.runScheduled()
    eq(#S.png_written, n, "nothing drawn")
    eq(S.global.screensaver_dir, "/my/wallpapers")
end)

H.describe("plugin smoke test: undo")
test("the user's own order file survives enable/disable", function()
    local p = Sereno:new{ ui = newUI("filemanager") }
    p:setEnabled(false)
    local mine = 'return { navi = { "table_of_contents" } }'
    local f = io.open(S.settings_dir .. "/reader_menu_order.lua", "w"); f:write(mine); f:close()
    p:setEnabled(true)
    p:setEnabled(false)
    local back = io.open(S.settings_dir .. "/reader_menu_order.lua"):read("*a")
    eq(back, mine, "original restored")
    truthy(S.restarts >= 1, "restart suggested")
end)

S.cleanup()
