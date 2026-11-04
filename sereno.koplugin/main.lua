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
local Folio = require("sereno/reader/folio")
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
            -- Shown from onShow, inside KOReader's own UIManager:show of the file
            -- manager, so the file manager is never painted first. The next tick
            -- is only a fallback, in case Show didn't reach us.
            self.pending_home = true
            UIManager:nextTick(function()
                if self.pending_home then
                    self.pending_home = nil
                    self:showHome()
                end
            end)
        end
    end
end

function Sereno:onShow()
    if self.pending_home and not self.ui.document then
        self.pending_home = nil
        self:showHome()
    end
end

--[[--
The file manager closed: when KOReader exits (KOReader quits once no window
is left), or when a book opens. Sereno's own windows go with it, so Exit
really leaves KOReader for the Kindle's home screen.
]]
function Sereno:onCloseWidget()
    if self.ui.document then return end
    self.pending_home = nil
    for _i, key in ipairs({ "controls", "chrome", "settings" }) do
        if session[key] then
            UIManager:close(session[key])
            session[key] = nil
        end
    end
    if session.home then
        UIManager:close(session.home)
        session.home = nil
    end
end

--- Leaves KOReader, back to the Kindle's (or Kobo's) own home screen.
function Sereno:exitKOReader()
    self:closeHome()
    UIManager:broadcastEvent(Event:new("Exit"))
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
    local method = self:homeOptions().page_method
    local total = metrics and MetricsCache.pageCount(metrics, method)
    if total then book.page_total, book.page_now = total, math.max(1, math.floor(book.percent * total + 0.5)) end
    book.locations = method == "locations"
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
            copy.progress = book.page_total and T(book.locations and _("Location %1 of %2 · %3%") or _("Page %1 of %2 · %3%"),
                book.page_now, book.page_total, pct)
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
                    items[#items + 1] = { text = _("Font, size and page…"),
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
                items[#items + 1] = {
                    text = _("Short selection menu"),
                    help_text = _("When you select text: Highlight, Note, Dictionary and More…, instead of KOReader's full list."),
                    checked_func = function() return self.settings:nilOrTrue("short_selection_menu") end,
                    callback = function()
                        self.settings:saveSetting("short_selection_menu", not self.settings:nilOrTrue("short_selection_menu"))
                        self.settings:flush()
                        if self.ui.document then self:applySelectionMenu() end
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
        page_method = self.settings:readSetting("position") == "locations" and "locations"
            or self.settings:readSetting("page_method", "print"),
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
        reading_stats = function() return self:readingStats() end,
        import_items = function() return self:importItems() end,
    }
end

--- Reading statistics, from KOReader's own statistics database.
function Sereno:readingStats()
    local Stats = require("sereno/stats/stats")
    local Source = require("sereno/stats/source")
    local raw = Source.read(DataStorage:getSettingsDir() .. "/statistics.sqlite3", {
        -- the progress KOReader keeps for the last book, when it's the same one
        book_percent = function(title)
            local last = G_reader_settings:readSetting("lastfile")
            local info = last and Library.bookInfo(last)
            if info and info.title == title then return info.percent end
        end,
    })
    if not raw then return { empty = true, week = {} } end
    return Stats.summarize(raw)
end

--- Ways to bring books in, through KOReader's own plugins.
function Sereno:importItems()
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local fm = FileManager and FileManager.instance
    local host = fm or self.ui
    local has_calibre = host and host.calibre ~= nil
    local has_opds = host and host.opds ~= nil
    return {
        { id = "calibre_connect", icon = "wifi", title = _("Calibre, wirelessly"), available = has_calibre,
          subtitle = has_calibre and _("Send books from calibre on your computer: in calibre, Connect/share → Start wireless device connection, then tap here.")
              or _("Turn on KOReader's calibre plugin (Tools → Plugin management) to use this.") },
        { id = "opds", glyph = "download", title = _("Online catalogs (OPDS)"), available = has_opds,
          subtitle = has_opds and _("Free libraries such as Project Gutenberg and Standard Ebooks, your calibre content server, or any catalog you add.")
              or _("Turn on KOReader's OPDS catalog plugin (Tools → Plugin management) to use this.") },
        { id = "calibre_search", icon = "appbar.search", title = _("Search calibre metadata"), available = has_calibre,
          subtitle = _("Find books you sent from calibre by title, author, series or tag.") },
        { id = "cable", icon = "appbar.filebrowser", title = _("With a cable"), info = true,
          subtitle = T(_("Copy EPUB files into %1 on your reader; they appear in the Library."), Library.homeDir()) },
    }
end

--- An Import row: KOReader's calibre and OPDS plugins do the work.
function Sereno:runImport(id, home)
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local fm = FileManager and FileManager.instance
    local host = fm or self.ui
    local function missing()
        UIManager:show(InfoMessage:new{ text = _("This needs a KOReader plugin that is turned off. Turn it on in Tools → Plugin management."), timeout = 4 })
    end
    if id == "calibre_connect" then
        if not (host and host.calibre) then return missing() end
        UIManager:broadcastEvent(Event:new("StartWirelessConnection"))
    elseif id == "calibre_search" then
        if not (host and host.calibre) then return missing() end
        UIManager:broadcastEvent(Event:new("CalibreSearch"))
    elseif id == "opds" then
        if not (host and host.opds) then return missing() end
        if host.opds.onShowOPDSCatalog then host.opds:onShowOPDSCatalog() end
    end
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
    elseif action.type == "import" then
        return self:runImport(action.id, home)
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
        restart = _("Restart"), sleep = _("Sleep"), exit = _("Exit"),
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
        elseif id == "exit" then
            later(function() self:exitKOReader() end)
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
                self:leaveBook()
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
    local pos = self:readerPosition(page, total)
    state.page_label, state.total_label, state.position_kind = pos.now, pos.total, pos.kind
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
    local locations = self.settings:readSetting("position") == "locations"
    return { home = _("Home"), page_of = locations and _("Location %s of %s") or _("Page %s of %s") }
end

Sereno.LOCATION_BYTES = 128

--[[--
Where you are in the book, in numbers that never change with the font,
size or margins:

* pages: KOReader's synthetic page map, which crengine builds by counting
  characters, tuned to the book's print-like page count (applyPageNumbers);
* locations, like a Kindle: one every 128 characters of text, counted from
  the same character-based page map.

Falls back to the screen page only when neither is available (PDFs).
]]
function Sereno:readerPosition(page, total)
    local ui = self.ui
    local pm = ui.pagemap
    local thousands = _.catalogue.thousands_separator or ","
    local fmt = function(n) return require("sereno/home/presenter").thousands(n, thousands) end
    local has_map = pm and pm.wantsPageLabels and pm:wantsPageLabels()
    if self.settings:readSetting("position") == "locations" then
        local cpp = pm and pm.chars_per_synthetic_page
        if has_map and cpp then
            local _label, idx, count = pm:getCurrentPageLabel(true)
            if idx and count then
                local now = math.floor((idx - 1) * cpp / Sereno.LOCATION_BYTES) + 1
                local all = math.ceil(count * cpp / Sereno.LOCATION_BYTES)
                return { kind = "locations", now = fmt(now), total = fmt(all) }
            end
        end
        local metrics = ui.document and ui.document.file and MetricsService.peek(ui.document.file)
        if metrics and metrics.chars then
            local all = math.max(1, math.ceil(metrics.chars / Sereno.LOCATION_BYTES))
            local now = math.floor(((page - 1) / math.max(1, total - 1)) * (all - 1)) + 1
            return { kind = "locations", now = fmt(now), total = fmt(all) }
        end
    end
    if has_map then
        return { kind = "pages", now = pm:getCurrentPageLabel(true), total = pm:getLastPageLabel(true) }
    end
    return { kind = "screen", now = tostring(page), total = tostring(total) }
end

--[[--
Leaves the book for Sereno's home screen. Closing the reader alone would
quit KOReader (and land on the Kindle's own home) when KOReader was
started straight into a book: there is no file manager underneath then.
KOReader's own Home action closes the reader *and* opens the file
manager, which then shows Sereno's home screen.
]]
function Sereno:leaveBook()
    local ui = self.ui
    session.home_after_reader = true
    if ui.onHome then
        ui:onHome()
    else
        local file = ui.document and ui.document.file
        ui:onClose()
        if ui.showFileManager then ui:showFileManager(file) end
    end
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
        later(function() self:leaveBook() end)
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
            text = _("Font, size and page (Sereno)"),
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
    local doc = self.ui.document
    if not (doc and self.ui.rolling and pm) then return false, "unsupported" end
    if not (pm.setSyntheticPagesNumber or doc.buildSyntheticPageMap) then return false, "unsupported" end
    if pm.has_pagemap_document_provided and not force then return false, "publisher" end
    local metrics, err = MetricsService.get(doc.file)
    if not metrics then return false, err or "no_count" end
    local method = self.settings:readSetting("page_method", "print")
    local pages = MetricsCache.pageCount(metrics, method)
    if not pages or pages < 1 then return false, "no_count" end
    self:setSyntheticPages(pm, pages)
    if not pm.use_page_labels then
        pm.use_page_labels = true
        pm.page_labels_cache = nil
        self.ui.doc_settings:saveSetting("pagemap_use_page_labels", true)
    end
    UIManager:broadcastEvent(Event:new("UsePageLabelsUpdated"))
    self.ui.doc_settings:saveSetting("sereno_page_numbers", pages)
    self.ui.doc_settings:saveSetting("sereno_page_method", method)
    return true, pages
end

--[[--
Builds KOReader's synthetic page map with exactly `pages` pages. KOReader's
development version has `setSyntheticPagesNumber`; its releases only have
"characters per page", so the same search is done here: crengine cuts the
text every N characters, and N is searched until the book has `pages`
pages (crengine accepts 500-3000).
]]
function Sereno:setSyntheticPages(pm, pages)
    if pm.setSyntheticPagesNumber then return pm:setSyntheticPagesNumber(pages) end
    local doc = self.ui.document
    if not pm.has_pagemap then
        pm.has_pagemap = true
        if pm.resetLayout then pm:resetLayout() end
        if self.ui.view and self.ui.view.registerViewModule then self.ui.view:registerViewModule("pagemap", pm) end
    end
    local function count(cpp)
        doc:buildSyntheticPageMap(cpp)
        return select(3, pm:getCurrentPageLabel()) or 0
    end
    local lo, hi = 500, 3000
    local best, best_diff = 1500, math.huge
    for _i = 1, 14 do
        if lo > hi then break end
        local mid = math.floor((lo + hi) / 2)
        local n = count(mid)
        if math.abs(n - pages) < best_diff then best, best_diff = mid, math.abs(n - pages) end
        if n == pages then break
        elseif n < pages then hi = mid - 1 -- fewer pages than wanted: fewer characters per page
        else lo = mid + 1 end
    end
    count(best)
    pm.chars_per_synthetic_page = best
    pm.page_labels_cache = nil
    if pm.updateVisibleLabels then pm:updateVisibleLabels() end
    self.ui.doc_settings:saveSetting("pagemap_chars_per_synthetic_page", best)
    self.ui.doc_settings:saveSetting("pagemap_doc_pages", select(3, pm:getCurrentPageLabel()))
    UIManager:setDirty(self.ui.view and self.ui.view.dialog or "all", "partial")
end

--- The text selection menu

-- what stays in the short menu (KOReader's own buttons)
Sereno.SELECTION_KEEP = { ["02_highlight"] = true, ["04_add_note"] = true, ["06_dictionary"] = true }

--[[--
A short selection menu, like the Kindle's: Highlight, Note, Dictionary and
"More…", which shows every other button (copy, search, Wikipedia,
translate, and whatever other plugins added). Done through KOReader's
public addToHighlightDialog / removeFromHighlightDialog, and undone the
same way when the setting is turned off.
]]
function Sereno:applySelectionMenu()
    local hl = self.ui.highlight
    if not (hl and hl.addToHighlightDialog and hl.removeFromHighlightDialog) then return false end
    if self.settings:nilOrTrue("short_selection_menu") then
        if self.removed_buttons then return true end
        self.removed_buttons = {}
        local ids = {}
        for id in pairs(hl._highlight_buttons or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        for _i, id in ipairs(ids) do
            if not Sereno.SELECTION_KEEP[id] then
                local fn = hl:removeFromHighlightDialog(id)
                if fn then self.removed_buttons[#self.removed_buttons + 1] = { id = id, fn = fn } end
            end
        end
        hl:addToHighlightDialog("99_sereno_more", function(this, index)
            return {
                text = _("More…"),
                callback = function()
                    if this.highlight_dialog then UIManager:close(this.highlight_dialog) end
                    self:showMoreSelection(this, index)
                end,
            }
        end)
    elseif self.removed_buttons then
        hl:removeFromHighlightDialog("99_sereno_more")
        for _i, b in ipairs(self.removed_buttons) do hl:addToHighlightDialog(b.id, b.fn) end
        self.removed_buttons = nil
    end
    return true
end

--- The rest of KOReader's selection buttons, two to a row as KOReader shows them.
function Sereno:showMoreSelection(hl, index)
    local ButtonDialog = require("ui/widget/buttondialog")
    local rows, row = {}, {}
    for _i, b in ipairs(self.removed_buttons or {}) do
        local button = b.fn(hl, index)
        if button and (not button.show_in_highlight_dialog_func or button.show_in_highlight_dialog_func()) then
            row[#row + 1] = button
            if #row == 2 then rows[#rows + 1], row = row, {} end
        end
    end
    if #row > 0 then rows[#rows + 1] = row end
    local dialog = ButtonDialog:new{
        buttons = rows,
        tap_close_callback = function() if hl.hold_pos then hl:clear() end end,
    }
    -- KOReader's buttons close "the highlight dialog" when done: this one
    hl.highlight_dialog = dialog
    UIManager:show(dialog)
    return dialog
end

--- The book page (running head and page number), see sereno/reader/folio.lua.
function Sereno:folioOn()
    return self.ui.rolling and self:currentSpec().folio and self.settings:readSetting("reading_layout") ~= nil
end

function Sereno:folioInfo()
    local ui = self.ui
    local doc = ui.document
    if not doc then return nil end
    local props = doc.getProps and doc:getProps() or {}
    local title = props.title ~= "" and props.title or (doc.file or ""):match("([^/]+)%.[^.]+$")
    local label
    local pm = ui.pagemap
    if pm and pm.wantsPageLabels and pm:wantsPageLabels() then label = pm:getCurrentPageLabel(true)
    elseif doc.getCurrentPage then label = doc:getCurrentPage() end
    local cfg = doc.configurable or {}
    local font_file
    local okf, FontList = pcall(require, "fontlist")
    local face = ui.font and ui.font.font_face
    if okf and FontList and face then
        for path, fi in pairs(FontList.fontinfo or {}) do
            if fi[1] and fi[1].name == face and not fi[1].bold and not fi[1].italic then font_file = path break end
        end
    end
    return {
        title = title, page_label = label, font_file = font_file, font_size = cfg.font_size,
        top_px = Screen:scaleBySize(cfg.t_page_margin or 0), bottom_px = Screen:scaleBySize(cfg.b_page_margin or 0),
    }
end

--- KOReader's status bar is hidden while the book page shows, and given back after.
function Sereno:applyFolio()
    local ui = self.ui
    if ui.view and ui.view.registerViewModule and not (ui.view.view_modules or {}).sereno_folio then
        ui.view:registerViewModule("sereno_folio", Folio.new{
            enabled = function() return self:folioOn() end,
            info = function() return self:folioInfo() end,
        })
    end
    local footer = ui.view and ui.view.footer
    if not (footer and footer.applyFooterMode and footer.mode_list) then return end
    if self:folioOn() then
        if footer.mode ~= footer.mode_list.off then
            self.settings:saveSetting("footer_mode_backup", footer.mode)
            footer:applyFooterMode(footer.mode_list.off)
            G_reader_settings:saveSetting("reader_footer_mode", footer.mode_list.off)
        end
    else
        local backup = self.settings:readSetting("footer_mode_backup")
        if backup and footer.mode == footer.mode_list.off then
            footer:applyFooterMode(backup)
            G_reader_settings:saveSetting("reader_footer_mode", backup)
            self.settings:delSetting("footer_mode_backup")
        end
    end
    UIManager:setDirty(ui.view.dialog or "all", "partial")
end

function Sereno:onReaderReady()
    pcall(self.applySelectionMenu, self)
    pcall(self.applyFolio, self)
    if self:isSleepScreenOn() then
        UIManager:scheduleIn(3, function() if self.ui.document then self:renderSleepImage() end end)
    end
    if not self.settings:nilOrTrue("reader_page_numbers") then return end
    local ds = self.ui.doc_settings
    if ds and ds:readSetting("sereno_page_numbers")
        and ds:readSetting("sereno_page_method") == self.settings:readSetting("page_method", "print") then return end
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

--- The page description in use: the last one chosen, or Normal.
function Sereno:currentSpec()
    return ReaderLayout.spec(self.settings:readSetting("reading_spec") or "normal")
end

--[[--
Applies a layout to the open book, through the same events as KOReader's
own bottom menu. `changed` names the one thing that changed (font, pt,
page, align, book_style), so a tap in the panel re-flows the book once;
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
    if (all or changed == "font") and values.font then
        self.ui:handleEvent(Event:new("SetFont", values.font))
    end
    if all or changed == "pt" then
        self.ui:handleEvent(Event:new("SetFontSize", values.font_size))
    end
    if (all and (values.weight or 0) ~= 0) or changed == "weight" then
        cfg.font_base_weight = values.weight or 0
        self.ui:handleEvent(Event:new("SetFontBaseWeight", values.weight or 0))
    end
    if all or changed == "page" then
        self.ui:handleEvent(Event:new("SetLineSpace", values.line_spacing))
    end
    -- the margins follow the text size too, through the line-length cap
    if all or changed == "pt" or changed == "page" or changed == "folio" then
        -- all four margins in one re-layout; ReaderTypeset keeps the unscaled
        -- values it later edits one side at a time from
        local margins = { values.h_margins[1], values.t_margin, values.h_margins[2], values.b_margin }
        if self.ui.typeset then self.ui.typeset.unscaled_margins = { margins[1], margins[2], margins[3], margins[4] } end
        self.ui:handleEvent(Event:new("SetPageMargins", margins))
    end
    if all or changed == "align" or changed == "book_style" then
        self:applyTypography(values.spec, true)
    end
    if all or changed == "folio" then
        UIManager:nextTick(function() pcall(self.applyFolio, self) end)
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
        if values.font then
            local backup = self.settings:readSetting("copt_backup") or {}
            if backup.cre_font == nil then
                backup.cre_font = G_reader_settings:readSetting("cre_font") or false
                self.settings:saveSetting("copt_backup", backup)
            end
            G_reader_settings:saveSetting("cre_font", values.font)
        end
        self:applyTypography(values.spec, false)
        self.settings:saveSetting("reading_layout", values.preset or "custom")
        self.settings:saveSetting("reading_spec", values.spec)
    else
        local backup = self.settings:readSetting("copt_backup") or {}
        for _i, key in ipairs(keys) do
            if backup[key] then G_reader_settings:saveSetting(key, backup[key]) else G_reader_settings:delSetting(key) end
        end
        if backup.cre_font ~= nil then
            if backup.cre_font then G_reader_settings:saveSetting("cre_font", backup.cre_font)
            else G_reader_settings:delSetting("cre_font") end
        end
        self:restoreTypography()
        if self.ui.document then UIManager:nextTick(function() pcall(self.applyFolio, self) end) end
        self.settings:delSetting("copt_backup")
        self.settings:delSetting("reading_layout")
    end
    self.settings:flush()
end

--- One tap in the panel: the new spec, applied to the book and saved.
function Sereno:onPanelAction(action, panel)
    local spec = self:currentSpec()
    local changed
    if action.type == "size" then
        spec = ReaderLayout.with(spec, "pt", spec.pt + action.delta)
        changed = "pt"
    elseif action.type == "level" then
        -- the Bold and Size bars: a box tapped (value) or − / + (delta)
        local levels = action.key == "weight" and ReaderLayout.WEIGHTS or ReaderLayout.SIZE_LEVELS
        local now = action.key == "weight" and ReaderLayout.weightLevel(spec.weight) or ReaderLayout.sizeLevel(spec.pt)
        -- the Bold bar's boxes are levels 2..6 (level 1 = regular, no box filled)
        local idx = action.value and (action.key == "weight" and action.value + 1 or action.value) or (now + action.delta)
        if action.key == "weight" and action.value and idx == now then idx = idx - 1 end -- tapping the last box clears it
        idx = math.max(1, math.min(#levels, idx))
        if idx == now then return nil end
        spec = ReaderLayout.with(spec, action.key, levels[idx])
        changed = action.key
    elseif action.type == "set" then
        spec = ReaderLayout.with(spec, action.key, action.value)
        changed = action.key
    elseif action.type == "theme" then
        local theme = self:findTheme(action.id)
        if not theme then return nil end
        for k, v in pairs(theme.spec) do spec[k] = v end
        spec = ReaderLayout.spec(spec)
        changed = nil
    elseif action.type == "theme_save" then
        self:saveThemeDialog(panel)
        return nil
    elseif action.type == "theme_delete" then
        self:deleteThemeDialog(action.id, panel)
        return nil
    else
        return nil
    end
    local values = ReaderLayout.compute(self:readerScreen(), spec)
    if self.ui.document then self:applyReadingLayout(values, changed) end
    self:setDefaultReadingLayout(values)
    values.font = values.font or (self.ui.font and self.ui.font.font_face)
    return values
end

--- Themes: the built-in ones, then the ones you saved.
function Sereno:themes()
    local list = {}
    for _i, th in ipairs(ReaderLayout.THEMES) do
        list[#list + 1] = { id = th.id, name = th.name, spec = th.spec, builtin = true }
    end
    for _i, th in ipairs(self.settings:readSetting("themes") or {}) do
        list[#list + 1] = { id = th.id, name = th.name, spec = th.spec }
    end
    local spec = self:currentSpec()
    -- one "current" at most: your own themes are more specific, so they win
    for i = #list, 1, -1 do
        if ReaderLayout.themeMatches(list[i], spec) then list[i].current = true break end
    end
    return list
end

function Sereno:findTheme(id)
    for _i, th in ipairs(self:themes()) do if th.id == id then return th end end
end

function Sereno:saveThemeDialog(panel)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Save current settings"),
        input_hint = _("Theme name"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local name = dialog:getInputText()
                UIManager:close(dialog)
                if name and name:match("%S") then
                    self:saveTheme(name)
                    if panel then panel:redraw() end
                end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Saves the current font, size, bold, page and alignment as a theme.
function Sereno:saveTheme(name)
    local spec = self:currentSpec()
    spec.font = spec.font or (self.ui.font and self.ui.font.font_face)
    local themes = self.settings:readSetting("themes") or {}
    local id = "user_" .. os.time() .. "_" .. #themes
    themes[#themes + 1] = { id = id, name = name, spec = spec }
    self.settings:saveSetting("themes", themes)
    self.settings:flush()
    return id
end

function Sereno:deleteThemeDialog(id, panel)
    local theme = self:findTheme(id)
    if not theme or theme.builtin then return end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete the theme \"%1\"?"), theme.name),
        ok_text = _("Delete"),
        ok_callback = function()
            self:deleteTheme(id)
            if panel then panel:redraw() end
        end,
    })
end

function Sereno:deleteTheme(id)
    local themes = {}
    for _i, th in ipairs(self.settings:readSetting("themes") or {}) do
        if th.id ~= id then themes[#themes + 1] = th end
    end
    self.settings:saveSetting("themes", themes)
    self.settings:flush()
end

-- Fonts worth offering first, when KOReader has them (system fonts on a
-- Kindle included); the font in use is always one of the choices.
Sereno.PREFERRED_FONTS = { "Bookerly", "Literata", "Noto Serif", "Gentium Book Plus", "Charis SIL", "Caecilia",
    "Georgia", "FreeSerif", "Noto Sans", "Open Sans" }

--- Every font KOReader has, { name, file }, the usual book fonts first.
function Sereno:fontChoices()
    local ok, FontList = pcall(require, "fontlist")
    if not ok or not FontList then return {} end
    if FontList.getFontList and not next(FontList.fontinfo or {}) then pcall(FontList.getFontList, FontList) end
    local files = {}
    for path, info in pairs(FontList.fontinfo or {}) do
        local fi = info[1]
        if fi and fi.name and not fi.bold and not fi.italic and not files[fi.name] then files[fi.name] = path end
    end
    local function rank(n)
        for i, v in ipairs(Sereno.PREFERRED_FONTS) do if v == n then return i end end
        return #Sereno.PREFERRED_FONTS + 1
    end
    local out = {}
    for name, path in pairs(files) do out[#out + 1] = { name = name, file = path } end
    table.sort(out, function(a, b)
        local ra, rb = rank(a.name), rank(b.name)
        if ra ~= rb then return ra < rb end
        return a.name:lower() < b.name:lower()
    end)
    local current = self.ui.font and self.ui.font.font_face or self:currentSpec().font
    return out, current, files[current or ""]
end

--- The "Text" panel, like the Kindle's "Aa" panel: Themes, Font, Layout.
function Sereno:showPagePanel()
    if not (self.ui.document and self.ui.rolling) then
        UIManager:show(InfoMessage:new{ text = _("Reading layouts apply to reflowable books (EPUB, FB2, MOBI…), not to PDF or comics.") })
        return
    end
    local fonts, current = self:fontChoices()
    local values = ReaderLayout.compute(self:readerScreen(), self:currentSpec())
    values.font = values.font or current
    local panel = PanelWidget:new{
        values = values,
        tab = self.settings:readSetting("panel_tab", "font"),
        translate = _,
        opts = function()
            local file
            local now = self.ui.font and self.ui.font.font_face or current
            for _i, f in ipairs(fonts) do if f.name == now then file = f.file end end
            return { fonts = fonts, font_file = file, themes = self:themes() }
        end,
        on_tab = function(tab) self.settings:saveSetting("panel_tab", tab) end,
        on_action = function(action, p) return self:onPanelAction(action, p) end,
    }
    UIManager:show(panel)
    return panel
end

function Sereno:onSerenoShowPagePanel()
    self:showPagePanel()
    return true
end

--- Reading settings: the panel, two typography switches, and the way back.
function Sereno:getReadingMenu()
    local screen = self:readerScreen()
    local function toggle(key, label, help)
        return {
            text = label, help_text = help,
            checked_func = function()
                local spec = self:currentSpec()
                if key == "align" then return spec.align == "justify" end
                return spec.book_style ~= false
            end,
            callback = function()
                local spec = self:currentSpec()
                local value
                if key == "align" then value = spec.align == "justify" and "left" or "justify"
                else value = not (spec.book_style ~= false) end
                spec = ReaderLayout.with(spec, key, value)
                local values = ReaderLayout.compute(screen, spec)
                if self.ui.document and self.ui.rolling then self:applyReadingLayout(values, key) end
                self:setDefaultReadingLayout(values)
            end,
        }
    end
    local menu = {}
    if self.ui.document then
        menu[#menu + 1] = {
            text = _("Font, size and page…"),
            callback = function(touchmenu_instance)
                if touchmenu_instance then touchmenu_instance:closeMenu() end
                self:showPagePanel()
            end,
        }
    end
    menu[#menu + 1] = toggle("align", _("Justified text"), _("Even right edges, as in printed books. Off: ragged right."))
    menu[#menu + 1] = toggle("book_style", _("Book-style paragraphs"),
        _("Indented first lines, no blank lines between paragraphs, centred headings, no widows or orphans."))
    menu[#menu].separator = true
    menu[#menu + 1] = {
        text = _("Back to KOReader's defaults"),
        help_text = self:layoutSummary({ physical = ReaderLayout.describe(screen, {
            font_size = 22, h_margin = 10, t_margin = 10, b_margin = 10, line_spacing = 100 }) }),
        enabled_func = function() return self.settings:readSetting("reading_layout") ~= nil end,
        callback = function() self:setDefaultReadingLayout(nil) end,
    }
    return menu
end

function Sereno:positionItems()
    local function set(v)
        self.settings:saveSetting("position", v)
        self.settings:flush()
        if session.home then session.home.options = self:homeOptions(); session.home:update() end
    end
    return {
        {
            text = _("Show pages (like the printed book)"),
            help_text = _("Page 68 of 179: the same numbers whatever font, size or margins you choose."),
            radio = true,
            checked_func = function() return self.settings:readSetting("position") ~= "locations" end,
            callback = function() set(nil) end,
        },
        {
            text = _("Show locations (like a Kindle)"),
            help_text = _("Location 452 of 3,400: one location every 128 characters of text, so they never change with your font settings either, and are finer than pages."),
            radio = true,
            checked_func = function() return self.settings:readSetting("position") == "locations" end,
            callback = function() set("locations") end,
            separator = true,
        },
    }
end

function Sereno:getPagesMenu()
    -- KISS: how the position is shown, how pages are counted (one submenu),
    -- reading speed, and this book's numbers. Stable page numbers in the
    -- reader are always on; they are applied when a book opens.
    local menu = self:positionItems()
    menu[#menu + 1] = {
        text_func = function()
            return T(_("Count pages: %1"), _(MetricsDialog.METHOD_LABELS[self.settings:readSetting("page_method", "print")]))
        end,
        sub_item_table_func = function()
            local items = {}
            for _i, method in ipairs(MetricsDialog.METHODS) do
                items[#items + 1] = {
                    text = _(MetricsDialog.METHOD_LABELS[method]),
                    help_text = method == "print" and _("Typesets each book on a reference printed page, so the count matches a paperback and never changes with your font settings.") or nil,
                    radio = true,
                    checked_func = function() return self.settings:readSetting("page_method", "print") == method end,
                    callback = function()
                        self.settings:saveSetting("page_method", method)
                        self.settings:flush()
                        if session.home then session.home.options = self:homeOptions(); session.home:update() end
                        if self.ui.document then self:applyPageNumbers(false) end
                    end,
                }
            end
            return items
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
