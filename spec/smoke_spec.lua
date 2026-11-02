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
        local customize = findItem(p:getMainMenu(), "Customize levels")
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
