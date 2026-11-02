--[[--
Sereno: a calmer KOReader, without patching KOReader.

* Tiered menus (Reading / Everyday / Everything), built on KOReader's own
  per-user menu order file and its "KOMenu:disabled" list. No widget is
  monkey-patched, so Sereno can coexist with other UI plugins and survive
  KOReader updates.
* A contextual home screen designed from physical sizes (sereno/home).
* Print-like page counts, word counts and readability for every book,
  computed without opening it (sereno/metrics).
* A refresh coordinator for e-ink (sereno/eink/refresh), shared by all
  of Sereno's widgets and available to other plugins via getRefresh().

@module koplugin.Sereno
]]

-- NOTE: plugin-local requires must happen here, at load time: KOReader only
-- adds this plugin's folder to package.path while main.lua is being loaded.
local Tiers = require("sereno/menu/tiers")
local TierDefaults = require("sereno/menu/tier_defaults")
local OrderFile = require("sereno/menu/orderfile")
local Refresh = require("sereno/eink/refresh")
local HomeScreen = require("sereno/home/homescreen")
local Library = require("sereno/library")
local MetricsDialog = require("sereno/metrics/dialog")
local MetricsService = require("sereno/metrics/service")

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
local session = {      -- survives switching between the file manager and the reader
    home_shown_at_boot = false,
    home_after_reader = false,
    home = nil,        -- the HomeScreen currently shown
}

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
    if not self.ui.document then
        self:addFileDialogButtons()
        -- Home at start-up, or after closing a book
        local at_boot = not session.home_shown_at_boot and self.settings:isTrue("home_at_start")
        local after_reader = session.home_after_reader and self.settings:nilOrTrue("home_after_reader")
        session.home_shown_at_boot = true
        session.home_after_reader = false
        if at_boot or after_reader then
            UIManager:nextTick(function() self:showHome() end)
        end
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
    Dispatcher:registerAction("sereno_show_home", {
        category = "none", event = "SerenoShowHome", title = _("Sereno: home screen"), general = true,
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

--- Home screen

function Sereno:homeOptions()
    return {
        page_method = self.settings:readSetting("page_method", "print"),
        wpm = self.settings:readSetting("wpm", 230),
        translate = _,
        thousands = _.catalogue.thousands_separator,
    }
end

function Sereno:homeSources()
    local peek = MetricsService.peek
    return {
        history = Library.history,
        book_info = function(file) return Library.bookInfo(file, peek(file)) end,
        new_books = Library.newBooks,
        metrics = peek,
        stats = Library.stats,
        cover = function(file) return Library.cover(file, peek(file)) end,
    }
end

function Sereno:showHome()
    if session.home then UIManager:close(session.home) end
    Library.invalidate()
    local home
    home = HomeScreen:new{
        sources = self:homeSources(),
        options = self:homeOptions(),
        refresh = getRefresh(),
        on_action = function(action) self:onHomeAction(action, home) end,
        on_hold = function(file) self:showMetrics(file, home) end,
    }
    session.home = home
    UIManager:show(home)
    self:countMissing(home)
end

--[[--
Counts, one book per tick, the books on the home screen that have no
metrics yet, then redraws once. Runs while the user looks at the screen,
so opening a book is never slowed down.
]]
function Sereno:countMissing(home)
    local queue = {}
    local model = home.model or {}
    if model.hero then queue[#queue + 1] = model.hero.file end
    for _i, b in ipairs(model.shelf or {}) do queue[#queue + 1] = b.file end
    local changed = false
    local function step()
        if session.home ~= home then return end
        local file = table.remove(queue, 1)
        if not file then
            if changed then home:update() end
            return
        end
        if not MetricsService.peek(file) then
            if MetricsService.get(file) then changed = true end
        end
        UIManager:scheduleIn(0.05, step)
    end
    UIManager:scheduleIn(0.5, step)
end

function Sereno:closeHome()
    if session.home then
        UIManager:close(session.home)
        session.home = nil
    end
end

function Sereno:onHomeAction(action, home)
    if not action then return end
    if action.type == "open" then
        self:closeHome()
        if self.ui.document then
            if action.file ~= self.ui.document.file then self.ui:switchDocument(action.file) end
        else
            require("apps/reader/readerui"):showReader(action.file)
        end
        return
    end
    local target = action.target
    if target == "home" then
        -- already here: just refresh the data
        if home then home:update() end
        return
    end
    -- navigation targets live in the file manager
    self:closeHome()
    local function go()
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        if not fm then return end
        if target == "history" and fm.history then fm.history:onShowHist()
        elseif target == "collections" and fm.collections then fm.collections:onShowColl()
        elseif target == "search" and fm.filesearcher then fm.filesearcher:onShowFileSearch() end
    end
    if self.ui.document then
        -- leave the book first; the file manager comes back by itself
        session.home_after_reader = false
        self.ui:onClose()
        UIManager:nextTick(go)
    else
        go()
    end
end

function Sereno:onCloseDocument()
    -- the file manager instance created next will show the home screen
    if self.ui.document then session.home_after_reader = true end
end

function Sereno:onSerenoShowHome()
    self:showHome()
    return true
end

--- Book metrics

function Sereno:showMetrics(file)
    local opts = self:homeOptions()
    opts.on_change = function()
        if session.home then session.home:update() end
    end
    MetricsDialog.show(file, opts)
end

function Sereno:addFileDialogButtons()
    if not self.ui.addFileDialogButtons then return end
    self.ui:addFileDialogButtons("sereno_metrics", function(file, is_file)
        if not is_file then return nil end
        return {
            {
                text = _("Pages & readability"),
                callback = function()
                    local chooser = self.ui.file_chooser
                    if chooser and chooser.file_dialog then UIManager:close(chooser.file_dialog) end
                    self:showMetrics(file)
                end,
            },
        }
    end)
end

function Sereno:countFolder()
    local chooser = self.ui.file_chooser
    local dir = chooser and chooser.path
    if not dir then return end
    local files = Library.booksIn(dir, true)
    if #files == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books in this folder.") })
        return
    end
    local counted, failed, skipped = MetricsService.countAll(files, {
        progress = function(i, total, name) return T(_("Counting pages… %1 / %2\n%3\n\nTap to stop."), i, total, name) end,
    })
    UIManager:show(InfoMessage:new{
        text = T(_("Counted %1 books. %2 were already counted, %3 could not be read."), counted, skipped, failed),
    })
end

function Sereno:onFileRename(old, new)
    if old and new then pcall(MetricsService.fileRenamed, old, new) end
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
            text = _("Home screen"),
            callback = function(touchmenu_instance)
                touchmenu_instance:closeMenu()
                self:showHome()
            end,
        },
        {
            text = _("Start with the home screen"),
            checked_func = function() return self.settings:isTrue("home_at_start") end,
            callback = function()
                self.settings:saveSetting("home_at_start", not self.settings:isTrue("home_at_start"))
                self.settings:flush()
            end,
        },
        {
            text = _("Home screen after closing a book"),
            checked_func = function() return self.settings:nilOrTrue("home_after_reader") end,
            callback = function()
                self.settings:saveSetting("home_after_reader", not self.settings:nilOrTrue("home_after_reader"))
                self.settings:flush()
            end,
            separator = true,
        },
        {
            text = _("Page counts"),
            sub_item_table_func = function() return self:getPagesMenu() end,
        },
        {
            text = _("Tiered menus"),
            sub_item_table_func = function() return self:getTiersMenu() end,
            separator = true,
        },
        {
            text = _("Refresh budget"),
            keep_menu_open = true,
            callback = function() self:showRefreshStats() end,
        },
    }
    return menu
end

function Sereno:getPagesMenu()
    local menu = {}
    for _i, method in ipairs(MetricsDialog.METHODS) do
        menu[#menu + 1] = {
            text = _(MetricsDialog.METHOD_LABELS[method]),
            help_text = method == "print" and _("Typesets each book on a reference printed page, so the count matches a paperback and never changes with your font settings.") or nil,
            radio = true,
            checked_func = function() return self.settings:readSetting("page_method", "print") == method end,
            callback = function()
                self.settings:saveSetting("page_method", method)
                self.settings:flush()
                if session.home then session.home.options = self:homeOptions(); session.home:update() end
            end,
            separator = method == "chars",
        }
    end
    local speeds = { 180, 230, 280, 330 }
    menu[#menu + 1] = {
        text_func = function() return T(_("Reading speed: %1 words per minute"), self.settings:readSetting("wpm", 230)) end,
        sub_item_table_func = function()
            local items = {}
            for _j, wpm in ipairs(speeds) do
                items[#items + 1] = {
                    text = T(_("%1 words per minute"), wpm),
                    radio = true,
                    checked_func = function() return self.settings:readSetting("wpm", 230) == wpm end,
                    callback = function()
                        self.settings:saveSetting("wpm", wpm)
                        self.settings:flush()
                    end,
                }
            end
            return items
        end,
    }
    if self.ui.document then
        menu[#menu + 1] = {
            text = _("This book: pages & readability"),
            callback = function(touchmenu_instance)
                touchmenu_instance:closeMenu()
                self:showMetrics(self.ui.document.file)
            end,
        }
    else
        menu[#menu + 1] = {
            text = _("Count all books in this folder"),
            help_text = _("Counts pages, words and readability for every book in the current folder and its subfolders. Already counted books are skipped."),
            callback = function(touchmenu_instance)
                touchmenu_instance:closeMenu()
                self:countFolder()
            end,
        }
    end
    return menu
end

function Sereno:getTiersMenu()
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
        callback = function()
            self.settings:delSetting("overrides")
            self.settings:flush()
            self:applyTiers(true)
        end,
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
