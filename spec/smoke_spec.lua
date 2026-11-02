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
    for _i = 1, 10 do S.runScheduled() end
    local Service = require("sereno/metrics/service")
    truthy(Service.peek(dir .. "/novel.epub"), "hero counted")
    truthy(home.model.hero.page_total and home.model.hero.page_total > 0, "page count shown after update")
    truthy(home.model.hero.progress_line:find("Page", 1, true), home.model.hero.progress_line)
    eq(home.model.hero.title, "Cien años de prueba: una novela", "title read from the book itself")
end)

test("taps open books and navigate", function()
    local p = Sereno:new{ ui = newUI("filemanager") }
    p:showHome()
    local home = S.shown[#S.shown]
    local tapped = {}
    for _i, n in ipairs(home.nodes) do
        if n.kind == "tap" and not tapped[n.action.type .. (n.action.target or "")] then
            tapped[n.action.type .. (n.action.target or "")] = true
            home:onTap(nil, { pos = { x = n.x + 1, y = n.y + 1 } })
        end
    end
    truthy(#S.opened >= 1, "a book was opened")
    truthy(H.contains(S.fm_calls, "history") and H.contains(S.fm_calls, "search"), "navigation reached the file manager")
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
    menu[2].callback()
    eq(p.settings:readSetting("page_method"), "downloaded")
    menu[1].callback()
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

test("a preset applies to the open book and becomes the default", function()
    local ui = newUI("reader")
    ui.rolling = {}
    ui.typeset = {}
    ui.document.configurable = {}
    local events = {}
    ui.handleEvent = function(_self, e) events[#events + 1] = e end
    local p = Sereno:new{ ui = ui }
    S.global.copt_font_size = 30 -- the user's own default, to be kept aside
    local menu = p:getReadingMenu()
    walk(menu, 0)
    eq(menu[1].text, "Text & page panel…")
    menu[3].callback() -- Paperback
    local names = {}
    for _i, e in ipairs(events) do names[#names + 1] = e.name end
    eq(table.concat(names, ","), "SetFontSize,SetLineSpace,SetPageMargins")
    truthy(S.global.style_tweaks and S.global.style_tweaks.paragraph_indent and S.global.style_tweaks.text_align_most_justify,
        "book typography set as KOReader style tweaks")
    truthy(ui.document.configurable.font_size and ui.document.configurable.h_page_margins, "config dialog values updated")
    eq(#events[3].args[1], 4, "four margins in one event")
    truthy(S.global.copt_font_size ~= 30 and S.global.copt_h_page_margins, "new default saved")
    eq(p.settings:readSetting("reading_layout"), "paperback")
    menu[#menu].callback() -- back to the user's previous defaults
    eq(S.global.copt_font_size, 30, "previous default restored")
    eq(S.global.copt_h_page_margins, nil)
    eq(S.global.style_tweaks.paragraph_indent, nil, "style tweaks restored")
end)

test("the text & page panel changes one thing per tap", function()
    local ui = newUI("reader")
    ui.rolling = {}
    ui.typeset = {}
    ui.document.configurable = {}
    local applied_css = 0
    ui.styletweak = { global_tweaks = { ["footnote-inpage_epub"] = true }, doc_tweaks = { paragraph_indent = false },
        updateCssText = function() applied_css = applied_css + 1 end }
    local events = {}
    ui.handleEvent = function(_self, e) events[#events + 1] = e end
    local p = Sereno:new{ ui = ui }
    local items = {}
    p:addToMainMenu(items)
    eq(items.sereno_page.sorting_hint, "typeset")
    local panel = p:showPagePanel()
    eq(S.shown[#S.shown], panel)
    local bb = S.fakeBB()
    panel:paintTo(bb, 0, 0)
    truthy(#bb.calls > 20, "panel drew its pages")
    local function tapOn(pred)
        for _i, n in ipairs(panel.nodes) do
            if n.kind == "tap" and pred(n.action) then
                panel:onTap(nil, { pos = { x = n.x + 1, y = n.y + 1 } })
                return true
            end
        end
    end
    truthy(tapOn(function(a) return a.type == "set" and a.key == "margins" and a.value == "wide" end), "margins option")
    eq(#events, 1)
    eq(events[1].name, "SetPageMargins")
    eq(p:currentSpec().margins, "wide")
    eq(p.settings:readSetting("reading_layout"), "custom")
    events = {}
    tapOn(function(a) return a.type == "set" and a.key == "align" and a.value == "left" end)
    eq(#events, 0, "alignment is a style tweak, not a re-layout event")
    eq(applied_css, 1)
    truthy(ui.styletweak.global_tweaks.text_align_most_left and not ui.styletweak.global_tweaks.text_align_most_justify, "left")
    eq(ui.styletweak.doc_tweaks.paragraph_indent, nil, "per-book override cleared")
    truthy(ui.styletweak.global_tweaks["footnote-inpage_epub"], "other tweaks kept")
    tapOn(function(a) return a.type == "size" and a.delta > 0 end)
    eq(events[1].name, "SetFontSize")
    tapOn(function(a) return a.type == "preset" and a.id == "airy" end)
    eq(p.settings:readSetting("reading_layout"), "airy")
    local before = #S.closed
    panel:onTap(nil, { pos = { x = 5, y = 5 } }) -- above the sheet
    truthy(#S.closed > before, "tap above the sheet closes it")
end)

test("the panel fits every screen without overlaps", function()
    local Panel = require("sereno/reader/panel")
    local Theme = require("sereno/ui/theme")
    local Layout = require("sereno/home/layout")
    local ReaderLayout = require("sereno/reader/layout")
    for _i, scr in ipairs({ { 600, 800, 167 }, { 758, 1024, 212 }, { 1072, 1448, 300 }, { 1236, 1648, 300 }, { 1860, 2480, 300 }, { 1448, 1072, 300 } }) do
        local screen = { width = scr[1], height = scr[2], dpi = scr[3] }
        local t = Theme.new(screen)
        local nodes, top = Panel.layout(t, ReaderLayout.compute(screen, "paperback"))
        truthy(top > t.height * 0.2, scr[1] .. "x" .. scr[2] .. ": the sheet leaves the book visible (top " .. top .. ")")
        for _j, n in ipairs(nodes) do
            truthy(n.x >= 0 and n.y >= 0 and n.x + n.w <= t.width + 1 and n.y + n.h <= t.height + 1,
                scr[1] .. "x" .. scr[2] .. " " .. tostring(n.id) .. " inside the screen")
        end
        local pages = 0
        for _j, a in ipairs(nodes) do
            if a.kind == "page" then
                pages = pages + 1
                for _k, b in ipairs(nodes) do
                    if b ~= a and b.kind == "page" then
                        truthy(a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y or b.y + b.h <= a.y,
                            a.id .. " overlaps " .. b.id)
                    end
                end
            end
        end
        eq(pages, 10)
        local _ = Layout
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
