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
local ReaderLayout = require("sereno/reader/layout")
local PanelWidget = require("sereno/reader/panelwidget")
local Browse = require("sereno/shell/browse")
local ChromeLayout = require("sereno/reader/chrome")
local ControlsLayout = require("sereno/controls/layout")
local Overlay = require("sereno/ui/overlay")
local SleepLayout = require("sereno/sleep/layout")
local MetricsCache = require("sereno/metrics/cache")

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
-- the plugin's own folder (for its icons), whatever KOReader's install path
local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*)/main%.lua$") or "plugins/sereno.koplugin"
local VERSION = (function()
    local ok, meta = pcall(dofile, PLUGIN_DIR .. "/_meta.lua")
    return ok and meta and meta.version or "?"
end)()
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
    pcall(self.installLogo, self)
    if self:isEnabled() then
        -- Menus are built lazily on first open, so writing now is in time.
        self:applyTiers(false)
    end
    if self.ui.document then
        self:registerReaderZones()
    else
        self:addFileDialogButtons()
        -- Home at start-up, or after closing a book
        local at_boot = not session.home_shown_at_boot and self.settings:nilOrTrue("home_at_start")
        local after_reader = session.home_after_reader and self.settings:nilOrTrue("home_after_reader")
            and not session.skip_home_once
        session.skip_home_once = nil
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
    Dispatcher:registerAction("sereno_settings", {
        category = "none", event = "SerenoShowSettings", title = _("Sereno: settings"), general = true,
    })
    Dispatcher:registerAction("sereno_controls", {
        category = "none", event = "SerenoShowControls", title = _("Sereno: quick controls"), general = true,
    })
    Dispatcher:registerAction("sereno_page_panel", {
        category = "none", event = "SerenoShowPagePanel", title = _("Sereno: text & page panel"), reader = true,
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

--[[--
Sleep and wake. KOReader draws its sleep screen *before* it tells plugins
the device is going to sleep, so Sereno never draws over it: it only stops
its clock, closes its sheets (so they don't greet you on wake), and
prepares its own sleep image for the next time. On wake, the screen
under the sleep screen is redrawn in full, without ghosting.
]]
function Sereno:onSuspend()
    if shared_refresh then shared_refresh:pause() end
    for _i, key in ipairs({ "controls", "chrome" }) do
        if session[key] then
            UIManager:close(session[key])
            session[key] = nil
        end
    end
    if self:isSleepScreenOn() then UIManager:nextTick(function() self:renderSleepImage() end) end
end

function Sereno:onResume()
    if shared_refresh then shared_refresh:resume() end
    if session.home and not self.ui.document then
        session.home:build()
        UIManager:setDirty(session.home, "full")
    end
end

--- Sleep screen

function Sereno:sleepDir()
    return DataStorage:getSettingsDir() .. "/sereno-sleep"
end

--- Sereno's sleep screen is on when KOReader shows random images from Sereno's folder.
function Sereno:isSleepScreenOn()
    return G_reader_settings:readSetting("screensaver_type") == "random_image"
        and G_reader_settings:readSetting("screensaver_dir") == self:sleepDir()
end

function Sereno:setSleepScreen(on)
    if on then
        if not self:isSleepScreenOn() then
            self.settings:saveSetting("screensaver_backup", {
                type = G_reader_settings:readSetting("screensaver_type") or false,
                dir = G_reader_settings:readSetting("screensaver_dir") or false,
            })
        end
        os.execute(string.format("mkdir -p %q", self:sleepDir()))
        self:renderSleepImage()
        G_reader_settings:saveSetting("screensaver_type", "random_image")
        G_reader_settings:saveSetting("screensaver_dir", self:sleepDir())
    else
        local backup = self.settings:readSetting("screensaver_backup") or {}
        if backup.type then G_reader_settings:saveSetting("screensaver_type", backup.type)
        else G_reader_settings:saveSetting("screensaver_type", "disable") end
        if backup.dir then G_reader_settings:saveSetting("screensaver_dir", backup.dir)
        else G_reader_settings:delSetting("screensaver_dir") end
        self.settings:delSetting("screensaver_backup")
    end
    self.settings:flush()
end

--- The book for the sleep screen: the last one opened, unless it's gone.
function Sereno:sleepBook()
    local file = self.ui.document and self.ui.document.file or G_reader_settings:readSetting("lastfile")
    local metrics = file and MetricsService.peek(file)
    local info = file and Library.bookInfo(file, metrics)
    if not info then return nil end
    local book = { file = file, title = info.title or file:match("([^/]+)%.[^.]+$"), percent = info.percent or 0 }
    if self.ui.document and self.ui.document.getCurrentPage and self.ui.rolling then
        local total = self.ui.document:getPageCount()
        if total and total > 1 then book.percent = (self.ui.document:getCurrentPage() - 1) / (total - 1) end
    end
    book.authors = type(info.authors) == "table" and table.concat(info.authors, ", ") or info.authors
    local total = metrics and MetricsCache.pageCount(metrics, self.settings:readSetting("page_method", "print"))
    if total then book.page_total, book.page_now = total, math.max(1, math.floor(book.percent * total + 0.5)) end
    return book
end

--[[--
Draws Sereno's sleep screen into <settings>/sereno-sleep/sleep.png, in
portrait (KOReader shows sleep screens in portrait). Returns the path.
]]
function Sereno:renderSleepImage()
    local ok, err = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local Painter = require("sereno/ui/painter")
        local Theme = require("sereno/ui/theme")
        local w, h = Screen:getWidth(), Screen:getHeight()
        if w > h then w, h = h, w end
        local theme = Theme.new{ width = w, height = h, dpi = Screen:getDPI(),
            scale_by_size = function(n) return Screen:scaleBySize(n) end }
        local book = self:sleepBook()
        local copy = { logo = PLUGIN_DIR .. "/icons/sereno.logo.svg", date = os.date("%Y-%m-%d") }
        local d = os.date("*t")
        local frame = require("sereno/home/presenter").frame(_, {}, "home", d)
        copy.date = frame.date
        if book then
            local pct = math.floor(book.percent * 100 + 0.5)
            copy.progress = book.page_total and T(_("Page %1 of %2 · %3%"), book.page_now, book.page_total, pct)
                or T(_("%1% read"), pct)
        end
        local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
        bb:fill(Blitbuffer.COLOR_WHITE)
        local painter = Painter.new(theme, function(file) return Library.cover(file, MetricsService.peek(file)) end)
        painter:paint(bb, SleepLayout.layout(theme, book, copy))
        painter:free()
        os.execute(string.format("mkdir -p %q", self:sleepDir()))
        bb:writePNG(self:sleepDir() .. "/sleep.png")
        bb:free()
    end)
    if not ok then logger.warn("Sereno: sleep screen image failed", err) end
    return ok and (self:sleepDir() .. "/sleep.png") or nil
end

function Sereno:getSleepMenu()
    local ok, koreader_menu = pcall(require, "ui/elements/screensaver_menu")
    local menu = {
        {
            text = _("Sereno: cover and progress"),
            help_text = _("While the device sleeps, show the book you're reading: its cover, title and how far you are. Uses KOReader's own sleep screen (random image from Sereno's folder), so turning it off restores your previous choice."),
            checked_func = function() return self:isSleepScreenOn() end,
            callback = function() self:setSleepScreen(not self:isSleepScreenOn()) end,
            separator = true,
        },
    }
    if ok and koreader_menu then
        menu[#menu + 1] = {
            text = _("KOReader's sleep screen options"),
            help_text = _("Covers, your own images and folders, messages, reading progress: all of KOReader's sleep screen settings, unchanged."),
            sub_item_table = koreader_menu,
        }
    end
    return menu
end

--- Unified settings (Sereno's own tab, then KOReader's tabs)

--- KOReader looks up tab icons by name, in its user icons folder too: Sereno's
-- mark is put there once. Until KOReader restarts, a stock icon stands in.
function Sereno:installLogo()
    local dir = DataStorage:getDataDir() .. "/icons"
    local dst = dir .. "/sereno.logo.svg"
    local src = PLUGIN_DIR .. "/icons/sereno.logo.svg"
    local f = io.open(dst, "r")
    if f then f:close() return end
    os.execute(string.format("mkdir -p %q && cp %q %q", dir, src, dst))
end

function Sereno:logoIcon()
    local ok, IconWidget = pcall(require, "ui/widget/iconwidget")
    if ok and IconWidget then
        local okw, w = pcall(IconWidget.new, IconWidget, { icon = "sereno.logo", width = 8, height = 8 })
        if okw and w and w.file and w.file:find("sereno", 1, true) then return "sereno.logo" end
    end
    return "home"
end

function Sereno:getSettingsTab()
    local tab = {
        icon = self:logoIcon(),
        remember = false,
        {
            text = _("Home screen"),
            sub_item_table_func = function()
                return {
                    { text = _("Open the home screen"), callback = function(tm) if tm then tm:closeMenu() end self:showHome() end },
                    {
                        text = _("Start with the home screen"),
                        checked_func = function() return self.settings:nilOrTrue("home_at_start") end,
                        callback = function()
                            self.settings:saveSetting("home_at_start", not self.settings:nilOrTrue("home_at_start"))
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
                    },
                }
            end,
        },
        {
            text = _("Reader"),
            sub_item_table_func = function()
                local items = {}
                if self.ui.document then
                    items[#items + 1] = { text = _("Text & page panel…"),
                        callback = function(tm) if tm then tm:closeMenu() end self:showPagePanel() end }
                end
                items[#items + 1] = { text = _("Reading layout"), sub_item_table_func = function() return self:getReadingMenu() end }
                items[#items + 1] = {
                    text = _("Sereno's bars in books"),
                    checked_func = function() return self.settings:nilOrTrue("reader_bars") end,
                    callback = function()
                        self.settings:saveSetting("reader_bars", not self.settings:nilOrTrue("reader_bars"))
                        self.settings:flush()
                    end,
                }
                items[#items + 1] = { text = _("Page counts"), sub_item_table_func = function() return self:getPagesMenu() end }
                return items
            end,
        },
        {
            text = _("Sleep screen"),
            sub_item_table_func = function() return self:getSleepMenu() end,
        },
        {
            text = _("Tiered menus"),
            sub_item_table_func = function() return self:getTiersMenu() end,
        },
        {
            text = _("Refresh budget"),
            keep_menu_open = true,
            callback = function() self:showRefreshStats() end,
            separator = true,
        },
        {
            text = _("About Sereno"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = T(_("Sereno %1\nA calmer KOReader: home screen, library, quick controls, reading layouts and print-like page counts, without patching KOReader.\n\ngithub.com/whoismjanyway/sereno"), VERSION),
                })
            end,
        },
    }
    return tab
end

--[[--
Sereno's settings next to KOReader's, like one settings app: the first
tab (Sereno's mark) holds Sereno's options, the following tabs are
KOReader's own menu, unchanged, so every KOReader setting still works from
here and nothing Sereno does is mixed into KOReader's pages.
]]
function Sereno:showSettings(tab_index)
    local menu = self.ui.menu
    local tabs = { self:getSettingsTab() }
    if menu then
        if menu.tab_item_table == nil and menu.setUpdateItemTable then menu:setUpdateItemTable() end
        for _i, t in ipairs(menu.tab_item_table or {}) do tabs[#tabs + 1] = t end
    end
    local CenterContainer = require("ui/widget/container/centercontainer")
    local TouchMenu = require("ui/widget/touchmenu")
    local container = CenterContainer:new{ ignore = "height", dimen = Screen:getSize() }
    local touch = TouchMenu:new{
        width = Screen:getWidth(),
        last_index = tab_index or 1,
        tab_item_table = tabs,
        show_parent = container,
        close_callback = function()
            UIManager:close(container)
            session.settings = nil
        end,
    }
    container[1] = touch
    session.settings = container
    UIManager:show(container)
    return touch, tabs
end

function Sereno:onSerenoShowSettings()
    self:showSettings()
    return true
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
        book_info = function(file)
            local info = Library.bookInfo(file, peek(file))
            if info then info.mtime = Library.mtime(file) end
            return info
        end,
        new_books = Library.newBooks,
        metrics = peek,
        stats = Library.stats,
        cover = function(file) return Library.cover(file, peek(file)) end,
        home_dir = Library.homeDir,
        list_dir = Library.listDir,
        collections = Library.collections,
        collection = Library.collection,
        search = function(query) return Library.search(query, Browse.matches) end,
    }
end

--- The Sereno shell, on `tab` (home by default).
function Sereno:showHome(tab)
    if session.home then UIManager:close(session.home) end
    Library.invalidate()
    local home
    home = HomeScreen:new{
        tab = tab or "home",
        sources = self:homeSources(),
        options = self:homeOptions(),
        refresh = getRefresh(),
        on_action = function(action) self:onHomeAction(action, home) end,
        on_hold = function(file) self:showMetrics(file, home) end,
        on_controls = function() self:showControls() end,
    }
    session.home = home
    UIManager:show(home)
    self:countMissing(home)
    if self:isSleepScreenOn() then UIManager:scheduleIn(2, function() self:renderSleepImage() end) end
    return home
end

--[[--
Counts, one book per tick, the books on the home screen that have no
metrics yet, then redraws once. Runs while the user looks at the screen,
so opening a book is never slowed down.
]]
function Sereno:countMissing(home)
    local queue, missing = {}, {}
    local model = home.model or {}
    local function want(file)
        if file and not MetricsService.peek(file) then
            queue[#queue + 1] = file
            missing[#missing + 1] = file
        end
    end
    if model.hero then want(model.hero.file) end
    for _i, b in ipairs(model.shelf or {}) do want(b.file) end
    local function step()
        if session.home ~= home then return end
        local file = table.remove(queue, 1)
        if not file then
            -- redraw once if any of them got counted (here, or by a cover lookup meanwhile)
            for _i, f in ipairs(missing) do
                if MetricsService.peek(f) then home:update() return end
            end
            return
        end
        if not MetricsService.peek(file) then MetricsService.get(file) end
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

function Sereno:openBook(file)
    self:closeHome()
    if self.ui.document then
        if file ~= self.ui.document.file then self.ui:switchDocument(file) end
    else
        require("apps/reader/readerui"):showReader(file)
    end
end

function Sereno:onHomeAction(action, home)
    if not action then return end
    if action.type == "open" then
        return self:openBook(action.file)
    elseif action.type == "search_input" then
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new{
            title = _("Search your library"),
            input = home and home.states.search.query or "",
            input_hint = _("Title, author or file name"),
            buttons = { {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Search"), is_enter_default = true, callback = function()
                    local q = dialog:getInputText()
                    UIManager:close(dialog)
                    if home then home:setQuery(q) end
                end },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end
end

function Sereno:onCloseDocument()
    -- the sleep screen shows where you stopped
    if self.ui.document and self:isSleepScreenOn() then self:renderSleepImage() end
    -- the file manager instance created next will show the home screen
    if self.ui.document then session.home_after_reader = true end
end

function Sereno:onSerenoShowHome()
    self:showHome()
    return true
end

--- Quick controls (pulled down from the top edge)

function Sereno:controlsState()
    local state = {}
    local ok_dt, datetime = pcall(require, "datetime")
    state.time = ok_dt and datetime.secondsToHour and datetime.secondsToHour(os.time(), G_reader_settings:isTrue("twelve_hour_clock"))
        or os.date("%H:%M")
    local powerd = Device:getPowerDevice()
    if Device:hasBattery() then
        state.battery, state.charging = powerd:getCapacity(), powerd:isCharging()
    end
    if Device:hasWifiToggle() then
        local ok, NetworkMgr = pcall(require, "ui/network/manager")
        state.wifi = ok and NetworkMgr:isWifiOn() or false
    end
    state.night = G_reader_settings:isTrue("night_mode")
    state.has_frontlight = Device:hasFrontlight()
    if state.has_frontlight then
        state.light_on = powerd:isFrontlightOn()
        state.brightness = powerd:frontlightIntensity()
        state.brightness_min, state.brightness_max = powerd.fl_min or 0, powerd.fl_max or 100
        state.has_warmth = Device:hasNaturalLight()
        if state.has_warmth then
            state.warmth, state.warmth_max = powerd:frontlightWarmth(), 100
        end
    end
    state.can_restart = Device:canRestart()
    state.can_sleep = Device:canSuspend()
    return state
end

function Sereno:controlsCopy()
    return {
        wifi = _("Wi-Fi"), night = _("Night"), light = _("Light"), rotate = _("Rotate"),
        restart = _("Restart"), sleep = _("Sleep"),
        wifi_on = _("Wi-Fi on"), wifi_off = _("Wi-Fi off"),
        brightness = _("Brightness: %d"), warmth = _("Warmth: %d"),
        koreader_menu = _("Settings"), files = _("File browser"),
    }
end

--- Runs a quick control; returns true when the sheet should be redrawn.
function Sereno:onControlsAction(action, ges, overlay)
    local powerd = Device:getPowerDevice()
    local function later(fn)
        overlay:onClose()
        UIManager:nextTick(fn)
    end
    if action.type == "toggle" then
        local id = action.id
        if id == "wifi" then
            UIManager:broadcastEvent(Event:new("ToggleWifi"))
            -- the network state settles a moment later
            UIManager:scheduleIn(2, function()
                if session.controls == overlay then overlay:rebuild() overlay:refresh() end
            end)
            return true
        elseif id == "night" then
            UIManager:broadcastEvent(Event:new("ToggleNightMode"))
            return true
        elseif id == "light" then
            powerd:toggleFrontlight()
            return true
        elseif id == "rotate" then
            later(function() UIManager:broadcastEvent(Event:new("IterateRotation")) end)
        elseif id == "restart" then
            later(function() UIManager:broadcastEvent(Event:new("Restart")) end)
        elseif id == "sleep" then
            later(function() UIManager:broadcastEvent(Event:new("RequestSuspend")) end)
        end
        return false
    elseif action.type == "seek" or action.type == "step" then
        local value
        if action.type == "seek" then
            value = ControlsLayout.seekValue(action, ges.pos.x)
        else
            local cur = action.id == "warmth" and powerd:frontlightWarmth() or powerd:frontlightIntensity()
            local max = action.id == "warmth" and 100 or (powerd.fl_max or 100)
            value = cur + action.delta * math.max(1, math.floor(max / 20))
            -- holding minus isn't a tap; a tap on minus at the bottom goes to zero
            value = math.max(action.id == "warmth" and 0 or (powerd.fl_min or 0), math.min(max, value))
        end
        if action.id == "warmth" then powerd:setWarmth(value) else powerd:setIntensity(value) end
        return true
    elseif action.type == "koreader_menu" then
        later(function() self:showSettings() end)
    elseif action.type == "files" then
        -- KOReader's own file browser, without Sereno's home on top
        later(function()
            self:closeHome()
            if self.ui.document then
                session.skip_home_once = true
                self.ui:onClose()
            end
        end)
    end
    return false
end

function Sereno:showControls()
    if session.controls then return session.controls end
    local overlay
    overlay = Overlay:new{
        build_nodes = function(theme)
            local nodes, bottom = ControlsLayout.layout(theme, self:controlsState(), self:controlsCopy())
            return nodes, { { x = 0, y = 0, w = theme.width, h = bottom } }
        end,
        on_action = function(action, ges, ov) return self:onControlsAction(action, ges, ov) end,
        on_close = function() session.controls = nil end,
        close_on_swipe = "north",
    }
    session.controls = overlay
    UIManager:show(overlay)
    return overlay
end

function Sereno:onSerenoShowControls()
    self:showControls()
    return true
end

--- The reader's bars (instead of KOReader's top and bottom menus)

--[[--
Taps at the top or bottom of a page show Sereno's bars, and a swipe down
from the top edge the quick controls. These are touch zones registered on
the reader with KOReader's public `registerTouchZones`, placed before
KOReader's own menu zones through `overrides`: nothing is patched, and
with the setting off KOReader's menus come back as they were.
]]
function Sereno:registerReaderZones()
    if not (Device:isTouchDevice() and self.ui.registerTouchZones) then return end
    local function enabled() return self.settings:nilOrTrue("reader_bars") end
    self.ui:registerTouchZones({
        {
            id = "sereno_top_tap", ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 / 8 },
            overrides = { "readermenu_tap", "readermenu_ext_tap", "tap_forward", "tap_backward" },
            handler = function() if enabled() then self:showChrome() return true end end,
        },
        {
            id = "sereno_bottom_tap", ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 7 / 8, ratio_w = 1, ratio_h = 1 / 8 },
            overrides = { "readerconfigmenu_tap", "readerconfigmenu_ext_tap", "tap_forward", "tap_backward" },
            handler = function() if enabled() then self:showChrome() return true end end,
        },
        {
            id = "sereno_top_swipe", ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 / 8 },
            overrides = { "readermenu_swipe", "readermenu_ext_swipe", "rolling_swipe", "paging_swipe" },
            handler = function(ges)
                if enabled() and ges.direction == "south" then self:showControls() return true end
            end,
        },
    })
end

function Sereno:chromeState()
    local ui = self.ui
    local doc = ui.document
    local state = {}
    local props = doc.getProps and doc:getProps() or {}
    state.title = (props.title and props.title ~= "" and props.title) or doc.file:match("([^/]+)%.[^.]+$")
    if props.authors and props.authors ~= "" then state.title = state.title .. " · " .. props.authors:gsub("\n", ", ") end
    local page = ui.rolling and doc:getCurrentPage() or (ui.view and ui.view.state and ui.view.state.page) or 1
    local total = doc:getPageCount() or 1
    state.percent = total > 1 and (page - 1) / (total - 1) or 0
    if ui.pagemap and ui.pagemap.wantsPageLabels and ui.pagemap:wantsPageLabels() then
        state.page_label, state.total_label = ui.pagemap:getCurrentPageLabel(true), ui.pagemap:getLastPageLabel(true)
    else
        state.page_label, state.total_label = tostring(page), tostring(total)
    end
    if ui.toc then
        state.chapter = ui.toc:getTocTitleByPage(page)
        local ticks = ui.toc.getTocTicksFlattened and ui.toc:getTocTicksFlattened(true) or {}
        state.ticks = {}
        for _i, p in ipairs(ticks) do state.ticks[#state.ticks + 1] = total > 1 and (p - 1) / (total - 1) or 0 end
        state.can_prev = ui.toc:getPreviousChapter(page) ~= nil or page > 1
        state.can_next = ui.toc:getNextChapter(page) ~= nil
    end
    if session.back_page then state.back_label = T(_("Back to page %1"), session.back_label or session.back_page) end
    state.page = page
    return state
end

function Sereno:chromeCopy()
    return { home = _("Home"), page_of = _("Page %s of %s") }
end

function Sereno:gotoPage(page)
    if self.ui.link and self.ui.link.addCurrentLocationToStack then self.ui.link:addCurrentLocationToStack() end
    self.ui:handleEvent(Event:new("GotoPage", page))
end

--- One tap in the reader's bars; returns true when they should be redrawn.
function Sereno:onChromeAction(action, ges, overlay)
    local ui = self.ui
    local function later(fn)
        overlay:onClose()
        UIManager:nextTick(fn)
    end
    local t = action.type
    if t == "home" then
        later(function() ui:onClose() end)
    elseif t == "panel" then
        later(function() self:showPagePanel() end)
    elseif t == "toc" then
        later(function() if ui.toc then ui.toc:onShowToc() end end)
    elseif t == "bookmarks" then
        later(function() if ui.bookmark then ui.bookmark:onShowBookmark() end end)
    elseif t == "search" then
        later(function() if ui.search then ui.search:onShowFulltextSearchInput() end end)
    elseif t == "menu" then
        later(function() self:showSettings() end)
    elseif t == "controls" then
        later(function() self:showControls() end)
    elseif t == "prev_chapter" or t == "next_chapter" or t == "seek" then
        local state = self:chromeState()
        local target
        if t == "seek" then
            local total = ui.document:getPageCount()
            target = math.max(1, math.min(total, math.floor(ChromeLayout.seekFraction(action, ges.pos.x) * (total - 1) + 1.5)))
        elseif t == "prev_chapter" and ui.toc then
            target = ui.toc:getPreviousChapter(state.page) or 1
        elseif ui.toc then
            target = ui.toc:getNextChapter(state.page)
        end
        if target and target ~= state.page then
            if not session.back_page then
                session.back_page, session.back_label = state.page, state.page_label
            end
            self:gotoPage(target)
            return true
        end
    elseif t == "back" then
        if ui.link and ui.link.onGoBackLink then ui.link:onGoBackLink() else self.ui:handleEvent(Event:new("GotoPage", session.back_page)) end
        session.back_page, session.back_label = nil, nil
        return true
    end
    return false
end

function Sereno:showChrome()
    if not self.ui.document then return end
    session.back_page, session.back_label = nil, nil
    local overlay
    overlay = Overlay:new{
        build_nodes = function(theme)
            local nodes, geo = ChromeLayout.layout(theme, self:chromeState(), self:chromeCopy())
            return nodes, {
                { x = 0, y = 0, w = theme.width, h = geo.top_h },
                { x = 0, y = geo.bottom_y - theme.touch * 2, w = theme.width, h = theme.height - geo.bottom_y + theme.touch * 2 },
            }
        end,
        on_action = function(action, ges, ov) return self:onChromeAction(action, ges, ov) end,
        on_close = function() session.chrome = nil end,
        close_on_swipe = "north",
    }
    session.chrome = overlay
    UIManager:show(overlay)
    return overlay
end

function Sereno:onSerenoShowChrome()
    self:showChrome()
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
    if self.ui.document then
        -- next to KOReader's own font and margin settings, in the typeset tab
        menu_items.sereno_page = {
            text = _("Text & page (Sereno)"),
            sorting_hint = "typeset",
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                self:showPagePanel()
            end,
        }
    end
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
            checked_func = function() return self.settings:nilOrTrue("home_at_start") end,
            callback = function()
                self.settings:saveSetting("home_at_start", not self.settings:nilOrTrue("home_at_start"))
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
            text = _("Settings (Sereno and KOReader)"),
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                self:showSettings()
            end,
        },
        {
            text = _("Sleep screen"),
            sub_item_table_func = function() return self:getSleepMenu() end,
        },
        {
            text = _("Sereno's bars in books"),
            help_text = _("A tap at the top or bottom of a page shows Sereno's bars, and a swipe down from the top the quick controls, instead of KOReader's menus. KOReader's menu stays one tap away (⋮)."),
            checked_func = function() return self.settings:nilOrTrue("reader_bars") end,
            callback = function()
                self.settings:saveSetting("reader_bars", not self.settings:nilOrTrue("reader_bars"))
                self.settings:flush()
            end,
            separator = true,
        },
        {
            text = _("Reading layout"),
            help_text = _("Font size, margins and line spacing for the page you read, set in points and millimetres so they look the same on every screen."),
            sub_item_table_func = function() return self:getReadingMenu() end,
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

--- Print page numbers in the reader

--[[--
Makes the reader show Sereno's page count: KOReader's own "stable page
numbers" (a synthetic page map built by crengine) are tuned so the book
has exactly as many pages as Sereno counted, and turned on. The footer,
"Go to page" and the page list then use the same numbers as the home
screen. Publisher page numbers, when the book has them, are kept unless
`force` is set.
]]
function Sereno:applyPageNumbers(force)
    local pm = self.ui.pagemap
    if not (self.ui.document and self.ui.rolling and pm and pm.setSyntheticPagesNumber) then return false, "unsupported" end
    if pm.has_pagemap_document_provided and not force then return false, "publisher" end
    local metrics = MetricsService.get(self.ui.document.file)
    local pages = metrics and MetricsCache.pageCount(metrics, self.settings:readSetting("page_method", "print"))
    if not pages or pages < 1 then return false, "no_count" end
    pm:setSyntheticPagesNumber(pages)
    if not pm.use_page_labels then
        pm.use_page_labels = true
        pm.page_labels_cache = nil
        self.ui.doc_settings:saveSetting("pagemap_use_page_labels", true)
        UIManager:broadcastEvent(Event:new("UsePageLabelsUpdated"))
    end
    self.ui.doc_settings:saveSetting("sereno_page_numbers", pages)
    return true, pages
end

function Sereno:onReaderReady()
    if self:isSleepScreenOn() then
        UIManager:scheduleIn(3, function() if self.ui.document then self:renderSleepImage() end end)
    end
    if not self.settings:isTrue("reader_page_numbers") then return end
    if self.ui.doc_settings and self.ui.doc_settings:readSetting("sereno_page_numbers") then return end
    -- after the first page is on screen, so opening the book isn't slowed down
    UIManager:scheduleIn(1, function()
        if self.ui.document then self:applyPageNumbers(false) end
    end)
end

--- Reading layout

function Sereno:readerScreen()
    return {
        width = Screen:getWidth(), height = Screen:getHeight(), dpi = Screen:getDPI(),
        scale_by_size = function(n) return Screen:scaleBySize(n) end,
    }
end

function Sereno:layoutSummary(values)
    local ph = values.physical
    return T(_("%1 pt · %2 mm margins · about %3 characters a line, %4 lines a page"),
        string.format("%.1f", ph.font_pt), string.format("%.0f", ph.side_mm), ph.chars_per_line, ph.lines_per_page)
end

--- The page description in use: the last one chosen, or Paperback.
function Sereno:currentSpec()
    return ReaderLayout.spec(self.settings:readSetting("reading_spec") or "paperback")
end

--[[--
Applies a layout to the open book, through the same events as KOReader's
own bottom menu. `changed` names the one axis that changed (pt, spacing,
margins, align, book_style), so a tap in the panel re-flows the book once;
nil applies everything.
]]
function Sereno:applyReadingLayout(values, changed)
    local doc = self.ui.document
    if not (doc and self.ui.rolling and doc.configurable) then
        UIManager:show(InfoMessage:new{ text = _("Reading layouts apply to reflowable books (EPUB, FB2, MOBI…), not to PDF or comics.") })
        return false
    end
    local all = changed == nil
    local cfg = doc.configurable
    -- keep KOReader's own config dialog in sync, so its sliders show the new values
    cfg.font_size = values.font_size
    cfg.h_page_margins = { values.h_margins[1], values.h_margins[2] }
    cfg.t_page_margin = values.t_margin
    cfg.b_page_margin = values.b_margin
    cfg.line_spacing = values.line_spacing
    if all or changed == "pt" then
        self.ui:handleEvent(Event:new("SetFontSize", values.font_size))
    end
    if all or changed == "spacing" then
        self.ui:handleEvent(Event:new("SetLineSpace", values.line_spacing))
    end
    -- the margins follow the text size too, through the line-length cap
    if all or changed == "pt" or changed == "margins" then
        -- all four margins in one re-layout; ReaderTypeset keeps the unscaled
        -- values it later edits one side at a time from
        local margins = { values.h_margins[1], values.t_margin, values.h_margins[2], values.b_margin }
        if self.ui.typeset then self.ui.typeset.unscaled_margins = { margins[1], margins[2], margins[3], margins[4] } end
        self.ui:handleEvent(Event:new("SetPageMargins", margins))
    end
    if all or changed == "align" or changed == "book_style" then
        self:applyTypography(values.spec, true)
    end
    return true
end

--[[--
Book typography through KOReader's own style tweaks, set as defaults for
every book (what "Use on all books" does in KOReader's style tweaks menu):
justified or left-aligned text, and, for the book style, first-line
indents, no blank lines between paragraphs, centred headings, no widows
or orphans and hyphenation everywhere. The user's previous choices for
these tweaks are kept aside and restored with "KOReader's defaults".
]]
function Sereno:applyTypography(spec, apply_now)
    local st = self.ui.styletweak
    local current = (st and st.global_tweaks) or G_reader_settings:readSetting("style_tweaks")
    local global = {}
    if current then
        for id, v in pairs(current) do global[id] = v end
    else
        local ok, CssTweaks = pcall(require, "ui/data/css_tweaks")
        for id, v in pairs(ok and CssTweaks.DEFAULT_GLOBAL_STYLE_TWEAKS or {}) do global[id] = v end
    end
    if not self.settings:readSetting("tweaks_backup") then
        local backup = {}
        for _i, id in ipairs(ReaderLayout.allTweaks()) do backup[id] = global[id] or false end
        self.settings:saveSetting("tweaks_backup", backup)
    end
    local on, off = ReaderLayout.tweaks(spec)
    for _i, id in ipairs(on) do global[id] = true end
    for _i, id in ipairs(off) do global[id] = nil end
    G_reader_settings:saveSetting("style_tweaks", global)
    if st and st.global_tweaks then
        st.global_tweaks = global
        -- a per-book choice for one of these would hide the new default
        if st.doc_tweaks then
            for _i, id in ipairs(ReaderLayout.allTweaks()) do st.doc_tweaks[id] = nil end
        end
        if apply_now and st.updateCssText then st:updateCssText(true) end
    end
end

function Sereno:restoreTypography()
    local backup = self.settings:readSetting("tweaks_backup")
    if not backup then return end
    local st = self.ui.styletweak
    local global = (st and st.global_tweaks) or G_reader_settings:readSetting("style_tweaks") or {}
    for id, v in pairs(backup) do global[id] = v or nil end
    G_reader_settings:saveSetting("style_tweaks", global)
    if st and st.global_tweaks then
        st.global_tweaks = global
        if self.ui.document and st.updateCssText then st:updateCssText(true) end
    end
    self.settings:delSetting("tweaks_backup")
end

--- Sets (or, with nil, removes) Sereno's layout as the default for new books.
-- The user's own previous defaults are kept aside and put back on removal.
function Sereno:setDefaultReadingLayout(values)
    local keys = ReaderLayout.SETTING_KEYS
    if values then
        if not self.settings:readSetting("reading_layout") then
            local backup = {}
            for _i, key in ipairs(keys) do backup[key] = G_reader_settings:readSetting(key) or false end
            self.settings:saveSetting("copt_backup", backup)
        end
        for key, v in pairs(ReaderLayout.defaultSettings(values)) do
            G_reader_settings:saveSetting(key, v)
        end
        self:applyTypography(values.spec, false)
        self.settings:saveSetting("reading_layout", values.preset or "custom")
        self.settings:saveSetting("reading_spec", values.spec)
    else
        local backup = self.settings:readSetting("copt_backup") or {}
        for _i, key in ipairs(keys) do
            if backup[key] then G_reader_settings:saveSetting(key, backup[key]) else G_reader_settings:delSetting(key) end
        end
        self:restoreTypography()
        self.settings:delSetting("copt_backup")
        self.settings:delSetting("reading_layout")
    end
    self.settings:flush()
end

--- One tap in the panel: the new spec, applied to the book and saved.
function Sereno:onPanelAction(action)
    local spec = self:currentSpec()
    local changed
    if action.type == "preset" then
        spec = ReaderLayout.spec(action.id)
    elseif action.type == "size" then
        spec = ReaderLayout.with(spec, "pt", spec.pt + action.delta)
        changed = "pt"
    elseif action.type == "set" then
        spec = ReaderLayout.with(spec, action.key, action.value)
        changed = action.key
    end
    local values = ReaderLayout.compute(self:readerScreen(), spec)
    if self.ui.document then self:applyReadingLayout(values, changed) end
    self:setDefaultReadingLayout(values)
    return values
end

--- The "Text & page" panel, like the Kindle's "Aa" panel.
function Sereno:showPagePanel()
    if not (self.ui.document and self.ui.rolling) then
        UIManager:show(InfoMessage:new{ text = _("Reading layouts apply to reflowable books (EPUB, FB2, MOBI…), not to PDF or comics.") })
        return
    end
    local panel = PanelWidget:new{
        values = ReaderLayout.compute(self:readerScreen(), self:currentSpec()),
        translate = _,
        on_action = function(action) return self:onPanelAction(action) end,
    }
    UIManager:show(panel)
    return panel
end

function Sereno:onSerenoShowPagePanel()
    self:showPagePanel()
    return true
end

function Sereno:getReadingMenu()
    local screen = self:readerScreen()
    local menu = {}
    if self.ui.document then
        menu[#menu + 1] = {
            text = _("Text & page panel…"),
            separator = true,
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                self:showPagePanel()
            end,
        }
    end
    for _i, preset in ipairs(ReaderLayout.PRESETS) do
        local values = ReaderLayout.compute(screen, preset.id)
        menu[#menu + 1] = {
            text = _(preset.name),
            help_text = self:layoutSummary(values),
            radio = true,
            checked_func = function() return self.settings:readSetting("reading_layout") == preset.id end,
            callback = function()
                local applied = self.ui.document and self:applyReadingLayout(values)
                self:setDefaultReadingLayout(values)
                UIManager:show(InfoMessage:new{
                    text = T(applied and _("%1 applied to this book and to new books.\n%2") or _("New books will open with %1.\n%2"),
                        _(preset.name), self:layoutSummary(values)),
                    timeout = 4,
                })
            end,
        }
    end
    if self.settings:readSetting("reading_layout") == "custom" then
        menu[#menu + 1] = {
            text = _("Custom"),
            help_text = self:layoutSummary(ReaderLayout.compute(screen, self:currentSpec())),
            radio = true,
            checked_func = function() return true end,
            callback = function() end,
        }
    end
    menu[#menu].separator = true
    menu[#menu + 1] = {
        text = _("KOReader's defaults"),
        help_text = self:layoutSummary({ physical = ReaderLayout.describe(screen, {
            font_size = 22, h_margin = 10, t_margin = 10, b_margin = 10, line_spacing = 100 }) }),
        radio = true,
        checked_func = function() return self.settings:readSetting("reading_layout") == nil end,
        callback = function() self:setDefaultReadingLayout(nil) end,
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
    menu[#menu].separator = true
    menu[#menu + 1] = {
        text = _("Use these page numbers in the reader"),
        help_text = _("Tunes KOReader's stable page numbers so each book has exactly the pages shown here. The status bar and Go to page then match the home screen, whatever your font settings. Books with publisher page numbers keep them."),
        checked_func = function() return self.settings:isTrue("reader_page_numbers") end,
        callback = function()
            self.settings:saveSetting("reader_page_numbers", not self.settings:isTrue("reader_page_numbers"))
            self.settings:flush()
            if self.settings:isTrue("reader_page_numbers") and self.ui.document then self:applyPageNumbers(false) end
        end,
    }
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
            text = _("This book: use these page numbers now"),
            callback = function()
                local ok, info = self:applyPageNumbers(true)
                UIManager:show(InfoMessage:new{
                    text = ok and T(_("This book now has %1 pages, as on the home screen."), info)
                        or _("Page numbers can only be set for reflowable books (EPUB, FB2, MOBI…)."),
                    timeout = 3,
                })
            end,
        }
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
