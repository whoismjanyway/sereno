-- Tiered menus: engine, serializer and order-file handling.
local H = require("helper")
local test, eq, list, contains = H.it, H.eq, H.list, H.contains
local Tiers = require("sereno/menu/tiers")
local Serialize = require("sereno/menu/serialize")
local OrderFile = require("sereno/menu/orderfile")
local Defaults = require("sereno/menu/tier_defaults")
local memfs = H.memfs

H.describe("menu tiers")
local S = Tiers.SEPARATOR

-- ---------------------------------------------------------------- tiers
local base = {
    ["KOMenu:menu_buttons"] = { "navi", "setting", "tools", "plus" },
    navi = { "toc", S, "book_map", S, "advanced" },
    setting = { "sereno", "frontlight", S, "device", S },
    device = { "time", "units" },
    tools = { "stats", "more" },
    more = { "terminal" },
    plus = {},
}
local levels = { toc = 1, book_map = 2, advanced = 3, frontlight = 1, time = 3, units = 3, stats = 2, terminal = 3 }

test("tidySeparators trims and collapses", function()
    eq(list(Tiers.tidySeparators({ S, "a", S, S, "b", S })), "a," .. S .. ",b")
end)

test("tier 1 keeps essentials, hides the rest via KOMenu:disabled", function()
    local order, hidden = Tiers.build(base, { levels = levels, tier = 1, pinned = { sereno = true } })
    eq(list(order.navi), "toc")
    eq(list(order.setting), "sereno,frontlight")
    assert(hidden.book_map and hidden.advanced and hidden.device, "expected hidden items")
    assert(contains(order["KOMenu:disabled"], "device"), "hidden container must be disabled too")
    eq(list(order["KOMenu:menu_buttons"]), "navi,setting,tools,plus", "tabs are always kept")
    eq(#order.tools, 0, "tools empty at tier 1")
end)

test("declared-empty containers survive (filled at runtime by KOReader)", function()
    local order = Tiers.build({ ["KOMenu:menu_buttons"] = { "main" }, main = { "x", "plus" }, plus = {} },
        { levels = { x = 3 }, tier = 1 })
    eq(list(order.main), "plus")
end)

test("tier 3 shows everything", function()
    local order, hidden = Tiers.build(base, { levels = levels, tier = 3 })
    eq(next(hidden), nil)
    eq(list(order.navi), list(base.navi))
    eq(#order["KOMenu:disabled"], 0)
end)

test("user overrides beat defaults", function()
    local order = Tiers.build(base, { levels = levels, tier = 1, overrides = { book_map = 1, toc = 3 } })
    eq(list(order.navi), "book_map")
end)

test("container shown when it has visible children", function()
    local order = Tiers.build(base, { levels = levels, tier = 2 })
    eq(list(order.tools), "stats")
    local order3 = Tiers.build(base, { levels = levels, tier = 3 })
    eq(list(order3.tools), "stats,more")
end)

test("explicit container level hides it even with visible children", function()
    local order = Tiers.build(base, { levels = { device = 3, time = 1, units = 1 }, tier = 1 })
    assert(not contains(order.setting, "device"))
end)

test("keep_empty_containers (debug mode) keeps sorting_hint targets", function()
    local order = Tiers.build(base, { levels = levels, tier = 1, keep_empty_containers = true })
    assert(contains(order.setting, "device"))
    assert(contains(order.tools, "more"))
end)

test("pinned ids ignore the tier", function()
    local order = Tiers.build(base, { levels = { sereno = 3 }, tier = 1, pinned = { sereno = true } })
    assert(contains(order.setting, "sereno"))
end)

test("merge replaces per key like MenuSorter", function()
    local m = Tiers.merge(base, { navi = { "advanced", "toc" } })
    eq(list(m.navi), "advanced,toc")
    eq(list(m.setting), list(base.setting))
    m.setting[1] = "changed"
    eq(base.setting[1], "sereno", "defaults must not be mutated")
end)

test("expandLevels marks unlisted leaves inside power containers", function()
    local l = Tiers.expandLevels(base, { units = 1 }, { "device" })
    eq(l.time, 3)
    eq(l.units, 1, "explicit level kept")
end)

test("existing disabled items are preserved", function()
    local b = Tiers.merge(base, { ["KOMenu:disabled"] = { "wallabag" } })
    local order = Tiers.build(b, { levels = levels, tier = 3 })
    assert(contains(order["KOMenu:disabled"], "wallabag"))
end)

H.describe("menu order files")
test("serialize round-trips and is deterministic", function()
    local order = Tiers.build(base, { levels = levels, tier = 2 })
    local s1, s2 = Serialize.order(order), Serialize.order(order)
    eq(s1, s2)
    assert(Serialize.isOurs(s1))
    local back = (loadstring or load)(s1)()
    eq(list(back.navi), list(order.navi))
    eq(list(back["KOMenu:menu_buttons"]), list(order["KOMenu:menu_buttons"]))
end)


test("adopt moves the user's own file aside and returns it", function()
    local files, fs = memfs({ ["/s/reader_menu_order.lua"] = 'return { navi = { "toc" } }' })
    local of = OrderFile.new("/s", fs)
    local user = of:adopt("reader")
    eq(list(user.navi), "toc")
    assert(files["/s/sereno/backup_reader_menu_order.lua"])
    eq(files["/s/reader_menu_order.lua"], nil)
end)

test("apply writes only when content changes", function()
    local files, fs = memfs()
    local of = OrderFile.new("/s", fs)
    local order = Tiers.build(base, { levels = levels, tier = 1 })
    eq(of:apply("reader", order), true)
    eq(of:apply("reader", order), false)
    assert(Serialize.isOurs(files["/s/reader_menu_order.lua"]))
end)

test("adopt does not treat our own file as the user's", function()
    local files, fs = memfs()
    local of = OrderFile.new("/s", fs)
    of:apply("reader", Tiers.build(base, { levels = levels, tier = 1 }))
    local user = of:adopt("reader")
    eq(next(user), nil)
    eq(files["/s/sereno/backup_reader_menu_order.lua"], nil)
end)

test("release restores the user's original file", function()
    local original = 'return { navi = { "toc" } }'
    local files, fs = memfs({ ["/s/reader_menu_order.lua"] = original })
    local of = OrderFile.new("/s", fs)
    of:adopt("reader")
    of:apply("reader", Tiers.build(base, { levels = levels, tier = 1 }))
    of:release("reader")
    eq(files["/s/reader_menu_order.lua"], original)
    eq(files["/s/sereno/backup_reader_menu_order.lua"], nil)
end)

test("release without a user file just removes ours", function()
    local files, fs = memfs()
    local of = OrderFile.new("/s", fs)
    of:apply("reader", Tiers.build(base, { levels = levels, tier = 1 }))
    of:release("reader")
    eq(files["/s/reader_menu_order.lua"], nil)
end)

test("a file the user writes later becomes the new base", function()
    local files, fs = memfs({ ["/s/reader_menu_order.lua"] = 'return { navi = { "a" } }' })
    local of = OrderFile.new("/s", fs)
    of:adopt("reader")
    files["/s/reader_menu_order.lua"] = 'return { navi = { "b" } }'
    eq(list(of:adopt("reader").navi), "b")
end)

local ko = os.getenv("KOREADER_DIR")
if ko then
    H.describe("menu tiers on KOReader's real menus")
    package.loaded["device"] = { -- the order files only ask a few capability questions
        isTouchDevice = function() return true end, hasExitOptions = function() return true end,
        hasKeys = function() return false end, hasDPad = function() return false end,
        isCervantes = function() return false end, canToggleMassStorage = function() return false end,
        hasOTAUpdates = function() return true end, isKobo = function() return false end,
        isAndroid = function() return false end, hasFrontlight = function() return true end,
        canRestart = function() return true end, hasGSensor = function() return false end,
    }
    setmetatable(package.loaded["device"], { __index = function() return function() return false end end })
    for _, prefix in ipairs({ "reader", "filemanager" }) do
        test("real " .. prefix .. " menus at every tier", function()
            local defaults = dofile(ko .. "/frontend/ui/elements/" .. prefix .. "_menu_order.lua")
            local merged = Tiers.merge(defaults, {})
            local lv = Tiers.expandLevels(merged, Defaults.levels, Defaults.all_inside)
            local prev
            for tier = 1, 3 do
                local order = Tiers.build(merged, { levels = lv, tier = tier, pinned = Defaults.pinned })
                local disabled = {}
                for _, id in ipairs(order["KOMenu:disabled"]) do disabled[id] = true end
                for id, l in pairs(order) do
                    if id ~= "KOMenu:disabled" then
                        for _, item in ipairs(l) do
                            assert(not disabled[item], item .. " is both visible and disabled")
                        end
                    end
                end
                local n = Tiers.countVisible(order)
                if prev then assert(n > prev, "tier " .. tier .. " should show more than tier " .. (tier - 1)) end
                prev = n
                print(string.format("      %-11s tier %d: %3d visible options, %3d hidden",
                    prefix, tier, n, #order["KOMenu:disabled"]))
                local back = (loadstring or load)(Serialize.order(order))()
                eq(#back["KOMenu:menu_buttons"], #defaults["KOMenu:menu_buttons"])
            end
        end)
    end
end

