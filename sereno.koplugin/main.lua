--[[--
Sereno: a calmer KOReader, without patching KOReader.

Phase 1:
  * Menus by level (Reading / Everyday / Everything), built on KOReader's own
    per-user menu order file and its "KOMenu:disabled" list. No widget is
    monkey-patched, so Sereno can coexist with other UI plugins and survive
    KOReader updates. The file is regenerated from KOReader's current
    defaults at every start, so new menu entries are never lost.
  * A refresh coordinator for e-ink (sereno/refresh.lua), exposed as
    Sereno.refresh for widgets (the home screen arrives in phase 2).

@module koplugin.Sereno
]]

-- NOTE: plugin-local requires must happen here, at load time: KOReader only
-- adds this plugin's folder to package.path while main.lua is being loaded.
local Tiers = require("sereno/menu/tiers")
local TierDefaults = require("sereno/menu/tier_defaults")
local OrderFile = require("sereno/menu/orderfile")
local Refresh = require("sereno/eink/refresh")

local DataStorage = require("datastorage")
local Dbg = require("dbg")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local _ = require("sereno/l10n")
local T = require("ffi/util").template

local Screen = Device.screen
local PREFIXES = { "reader", "filemanager" }
local TIER_NAMES = {
    [Tiers.READING] = _("Reading"),
    [Tiers.EVERYDAY] = _("Everyday"),
    [Tiers.ALL] = _("Everything"),
}
local TIER_HELP = {
    [Tiers.READING] = _("Only what you use while reading: contents, font, light, dictionary, history."),
    [Tiers.EVERYDAY] = _("Everyday options, without the advanced ones."),
    [Tiers.ALL] = _("All of KOReader's menus, as usual."),
}

-- Shared across ReaderUI and FileManager instances of the plugin.
local labels = {}      -- menu id -> visible text, collected from menu_items
local shared_refresh   -- one coordinator for the whole app

local function getRefresh()
    if not shared_refresh then
        shared_refresh = Refresh.new{
            ui = {
                setDirty = function(w, mode, region) UIManager:setDirty(w, mode, region) end,
                scheduleIn = function(s, fn) UIManager:scheduleIn(s, fn) end,
                unschedule = function(fn) UIManager:unschedule(fn) end,
            },
            now = function() return time.to_s(time.realtime()) end,
            screen = { w = Screen:getWidth(), h = Screen:getHeight() },
            make_rect = function(r) return Geom:new(r) end,
        }
    end
    return shared_refresh
end

local Sereno = WidgetContainer:extend{
    name = "sereno",
    is_doc_only = false,
}

-- Widgets of other plugins (phase 2 home screen, third-party modules) use this.
Sereno.getRefresh = getRefresh

function Sereno:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/sereno.lua")
    self.order_file = OrderFile.new(DataStorage:getSettingsDir())
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    if self:isEnabled() then
        -- Menus are built lazily on first open, so writing now is in time.
        self:applyTiers(false)
    end
end

function Sereno:isEnabled()
    return self.settings:isTrue("enabled")
end

function Sereno:getTier()
    return self.settings:readSetting("tier", Tiers.EVERYDAY)
end

function Sereno:getOverrides()
    return self.settings:readSetting("overrides", {})
end

--- Merge KOReader defaults with the user's own order for one prefix.
function Sereno:getBase(prefix)
    local defaults = OrderFile.loadDefaults(prefix)
    if not defaults then return nil, "no defaults for " .. prefix end
    local user, err = self.order_file:adopt(prefix)
    if not user then return nil, err end
    local base = Tiers.merge(defaults, user)
    -- Our entry goes first in Settings, so it can never be lost.
    if base.setting then
        local list = { "sereno" }
        for _i, id in ipairs(base.setting) do
            if id ~= "sereno" then list[#list + 1] = id end
        end
        base.setting = list
    end
    return base
end

function Sereno:buildOrder(prefix)
    local base, err = self:getBase(prefix)
    if not base then return nil, err end
    local levels = Tiers.expandLevels(base, TierDefaults.levels, TierDefaults.all_inside)
    return Tiers.build(base, {
        levels = levels,
        overrides = self:getOverrides(),
        tier = self:getTier(),
        pinned = TierDefaults.pinned,
        keep_empty_containers = Dbg.is_on == true,
    }), base
end

function Sereno:applyTiers(rebuild)
    for _i, prefix in ipairs(PREFIXES) do
        local order, err = self:buildOrder(prefix)
        if order then
            local _changed, werr = self.order_file:apply(prefix, order)
            if werr then logger.warn("Sereno: could not write menu order", prefix, werr) end
        else
            logger.warn("Sereno: skipping", prefix, err)
        end
    end
    if rebuild then
        UIManager:broadcastEvent(Event:new("RebuildMenu"))
    end
end

function Sereno:setEnabled(enabled)
    self.settings:saveSetting("enabled", enabled)
    self.settings:flush()
    if enabled then
        self:applyTiers(true)
    else
        for _i, prefix in ipairs(PREFIXES) do
            self.order_file:release(prefix)
        end
        -- KOReader caches the merged order until restart.
        UIManager:askForRestart(_("Tiered menus are off. Restart KOReader to get all the original menus back."))
    end
end

function Sereno:setTier(tier)
    if tier < Tiers.READING or tier > Tiers.ALL then return end
    self.settings:saveSetting("tier", tier)
    self.settings:flush()
    if self:isEnabled() then
        self:applyTiers(true)
    end
end

--- Dispatcher (gestures, profiles, quick menu)

function Sereno:onDispatcherRegisterActions()
    Dispatcher:registerAction("sereno_cycle_tier", {
        category = "none", event = "SerenoCycleTier", title = _("Sereno: cycle menu level"), general = true,
    })
    Dispatcher:registerAction("sereno_tier_reading", {
        category = "none", event = "SerenoSetTier", arg = Tiers.READING, title = _("Sereno: Reading menus"), general = true,
    })
    Dispatcher:registerAction("sereno_tier_all", {
        category = "none", event = "SerenoSetTier", arg = Tiers.ALL, title = _("Sereno: Everything menus"), general = true,
    })
end

function Sereno:onSerenoCycleTier()
    if not self:isEnabled() then return true end
    local next_tier = self:getTier() % Tiers.ALL + 1
    self:setTier(next_tier)
    UIManager:show(InfoMessage:new{
        text = T(_("Menus: %1"), TIER_NAMES[next_tier]),
        timeout = 2,
    })
    return true
end

function Sereno:onSerenoSetTier(tier)
    if self:isEnabled() then self:setTier(tier) end
    return true
end

--- Suspend handling for the refresh coordinator

function Sereno:onSuspend()
    if shared_refresh then shared_refresh:pause() end
end

function Sereno:onResume()
    if shared_refresh then shared_refresh:resume() end
end

--- Menu

local function textOf(item)
    if item.text then return item.text end
    if item.text_func then
        local ok, t = pcall(item.text_func)
        if ok and type(t) == "string" then return t end
    end
end

function Sereno:collectLabels(menu_items)
    for id, item in pairs(menu_items) do
        if type(item) == "table" and labels[id] == nil then
            labels[id] = textOf(item)
        end
    end
end

function Sereno:labelFor(id)
    local text = labels[id]
    if text and text ~= "" then return text end
    return id -- plugin items not seen yet: show the raw id
end

function Sereno:addToMainMenu(menu_items)
    self:collectLabels(menu_items)
    menu_items.sereno = {
        text = _("Sereno"),
        sorting_hint = "setting",
        sub_item_table_func = function() return self:getMainMenu() end,
    }
end

function Sereno:getMainMenu()
    local menu = {
        {
            text = _("Tiered menus"),
            help_text = _("Hides options according to the chosen level. Uses KOReader's own menu order file: KOReader itself is not modified and everything can be undone."),
            checked_func = function() return self:isEnabled() end,
            callback = function() self:setEnabled(not self:isEnabled()) end,
            separator = true,
        },
    }
    for tier = Tiers.READING, Tiers.ALL do
        menu[#menu + 1] = {
            text = TIER_NAMES[tier],
            help_text = TIER_HELP[tier],
            radio = true,
            enabled_func = function() return self:isEnabled() end,
            checked_func = function() return self:getTier() == tier end,
            callback = function() self:setTier(tier) end,
            separator = tier == Tiers.ALL,
        }
    end
    menu[#menu + 1] = {
        text = _("Search menus…"),
        help_text = _("Find any option by name. Only visible options are searched: switch to Everything if you can't find one."),
        callback = function(touchmenu_instance)
            touchmenu_instance:onShowMenuSearch()
        end,
    }
    menu[#menu + 1] = {
        text = _("Customize levels"),
        enabled_func = function() return self:isEnabled() end,
        sub_item_table_func = function() return self:getCustomizeMenu() end,
    }
    menu[#menu + 1] = {
        text = _("Reset customization"),
        enabled_func = function() return next(self:getOverrides()) ~= nil end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self.settings:delSetting("overrides")
            self.settings:flush()
            self:applyTiers(true)
        end,
        separator = true,
    }
    menu[#menu + 1] = {
        text = _("Refresh budget"),
        keep_menu_open = true,
        callback = function() self:showRefreshStats() end,
    }
    return menu
end

-- Lists every submenu of the current context, then its items.
function Sereno:getCustomizeMenu()
    local prefix = self.ui.document and "reader" or "filemanager"
    local base = self:getBase(prefix)
    if not base then return {} end
    local menus = {}
    local ids = {}
    for id, list in pairs(base) do
        if type(list) == "table" and id ~= Tiers.BUTTONS and id ~= Tiers.DISABLED then
            local leaves = 0
            for _i, item in ipairs(list) do
                if item ~= Tiers.SEPARATOR and type(base[item]) ~= "table" then leaves = leaves + 1 end
            end
            if leaves > 0 then ids[#ids + 1] = id end
        end
    end
    table.sort(ids, function(a, b) return self:labelFor(a) < self:labelFor(b) end)
    for _i, id in ipairs(ids) do
        menus[#menus + 1] = {
            text = self:labelFor(id),
            sub_item_table_func = function() return self:getItemsMenu(base, id) end,
        }
    end
    table.insert(menus, 1, {
        text = _("Apply changes"),
        help_text = _("Level changes are saved right away and applied to the menus when you tap here."),
        callback = function() self:applyTiers(true) end,
        separator = true,
    })
    return menus
end

function Sereno:getItemsMenu(base, menu_id)
    local levels = Tiers.expandLevels(base, TierDefaults.levels, TierDefaults.all_inside)
    local items = {}
    for _i, id in ipairs(base[menu_id]) do
        if id ~= Tiers.SEPARATOR and type(base[id]) ~= "table" and not TierDefaults.pinned[id] then
            items[#items + 1] = {
                text_func = function()
                    local lvl = Tiers.levelOf(id, levels, self:getOverrides())
                    return T("%1 · %2", self:labelFor(id), TIER_NAMES[lvl])
                end,
                help_text = _("Tap to change the level at which this option appears."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local overrides = self:getOverrides()
                    local lvl = Tiers.levelOf(id, levels, overrides)
                    overrides[id] = lvl % Tiers.ALL + 1
                    self.settings:saveSetting("overrides", overrides)
                    self.settings:flush()
                    touchmenu_instance:updateItems()
                end,
            }
        end
    end
    return items
end

function Sereno:showRefreshStats()
    local r = getRefresh()
    local s = r.stats
    UIManager:show(InfoMessage:new{
        text = T(_("Since start-up:\n• Repaint requests: %1\n• Actual refreshes: %2 (flashing: %3)\n• Refreshes saved by grouping: %4\n• Shared clock ticks: %5"),
            s.invalidations, s.refreshes, s.flashes, r:saved(), s.periodic_ticks),
    })
end

return Sereno
