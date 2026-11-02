-- Stand-ins for the KOReader modules main.lua and the UI code require, so the
-- plugin can be loaded and its menus walked without a device or emulator.
-- They record what the plugin asked KOReader to do.

local S = {
    events = {}, shown = {}, closed = {}, restarts = 0, dirty = 0, scheduled = {},
    settings_dir = (os.getenv("TMPDIR") or "/tmp") .. "/sereno_spec_" .. tostring(os.time()) .. tostring(math.random(1e6)),
    file_dialog_rows = {},
}
os.execute('mkdir -p "' .. S.settings_dir .. '"')

local function stub(name, value) package.loaded[name] = value end

-- Generic widget: keeps its fields, has a size, can be extended.
local Widget = {}
Widget.__index = Widget
function Widget:extend(o)
    o = o or {}
    o.__index = o
    return setmetatable(o, self)
end
function Widget:new(o)
    o = setmetatable(o or {}, self)
    if o.init then o:init() end
    return o
end
function Widget:getSize() return self.dimen or { w = self.width or 100, h = self.height or 20 } end
function Widget:free() end
function Widget:paintTo() end
function Widget:getLineHeight() return 20 end
function Widget:getWidth() return self.width or 100 end
function Widget:handleEvent() end
function Widget:onCloseWidget() end
function Widget:onShow() end
S.Widget = Widget

local function widgetModule(name)
    stub(name, Widget:extend({ _module = name }))
end

stub("gettext", setmetatable({}, { __call = function(_, s) return s end }))
stub("device", setmetatable({
    screen = {
        getWidth = function() return 1072 end, getHeight = function() return 1448 end,
        getDPI = function() return 300 end, scaleBySize = function(_, n) return n end,
        getSize = function() return { w = 1072, h = 1448 } end,
    },
    isTouchDevice = function() return true end, hasExitOptions = function() return true end,
    canRestart = function() return true end, hasFrontlight = function() return true end,
    hasKeys = function() return false end, model = "stub", hasBattery = function() return true end,
    getPowerDevice = function() return { getCapacity = function() return 77 end, isCharging = function() return false end } end,
}, { __index = function() return function() return false end end }))
stub("datastorage", {
    getSettingsDir = function() return S.settings_dir end,
    getDataDir = function() return S.settings_dir end,
})
stub("dbg", { is_on = false })
stub("logger", { warn = function(...) end, dbg = function() end, info = function() end, err = function(...) print("ERR", ...) end })
stub("ui/event", { new = function(_, name, ...) return { name = name, args = { ... } } end })
stub("ui/geometry", { new = function(_, r) return r end })
stub("ui/time", { realtime = function() return os.time() end, to_s = function(t) return t end, now = function() return os.time() end })
stub("ffi/util", {
    template = function(s, ...)
        local a = { ... }
        return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
    end,
    basename = function(p) return p:match("([^/]+)$") end,
})
stub("dispatcher", { registerAction = function() end })
stub("ui/uimanager", {
    show = function(_, w) S.shown[#S.shown + 1] = w end,
    close = function(_, w) S.closed[#S.closed + 1] = w end,
    broadcastEvent = function(_, e) S.events[#S.events + 1] = e.name end,
    sendEvent = function(_, e) S.events[#S.events + 1] = e.name end,
    askForRestart = function() S.restarts = S.restarts + 1 end,
    setDirty = function() S.dirty = S.dirty + 1 end,
    scheduleIn = function(_, s, fn) S.scheduled[#S.scheduled + 1] = fn end,
    nextTick = function(_, fn) S.scheduled[#S.scheduled + 1] = fn end,
    unschedule = function() end,
    getTopmostVisibleWidget = function() return nil end,
    forceRePaint = function() end,
})
stub("ui/widget/container/widgetcontainer", Widget:extend({}))
stub("ui/widget/container/inputcontainer", Widget:extend({}))
for _, name in ipairs({
    "ui/widget/infomessage", "ui/widget/confirmbox", "ui/widget/textwidget", "ui/widget/textboxwidget",
    "ui/widget/container/framecontainer", "ui/widget/container/centercontainer", "ui/widget/container/leftcontainer",
    "ui/widget/container/rightcontainer", "ui/widget/container/topcontainer", "ui/widget/container/bottomcontainer",
    "ui/widget/verticalgroup", "ui/widget/horizontalgroup", "ui/widget/overlapgroup", "ui/widget/verticalspan",
    "ui/widget/horizontalspan", "ui/widget/linewidget", "ui/widget/imagewidget", "ui/widget/progresswidget",
    "ui/widget/keyvaluepage", "ui/widget/iconwidget", "ui/widget/buttondialog", "ui/widget/button", "ui/widget/container/underlinecontainer",
}) do widgetModule(name) end
stub("ui/font", { getFace = function(_, name, size) return { name = name, size = size, orig_size = size } end })
stub("ui/size", { border = { thin = 1, default = 2 }, padding = { default = 5, small = 2 }, margin = { default = 5 }, span = { horizontal_default = 10 } })
stub("ffi/blitbuffer", { COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_GRAY = "gray",
    COLOR_DARK_GRAY = "darkgray", COLOR_LIGHT_GRAY = "lightgray", COLOR_GRAY_4 = "gray4" })
stub("ui/gesturerange", { new = function(_, o) return o end })
stub("libs/libkoreader-lfs", {
    attributes = function(p, key)
        local a
        local probe = io.popen(string.format('test -d %q && echo d', p))
        local is_dir = probe:read("*l") == "d"
        probe:close()
        if is_dir then
            a = { mode = "directory", size = 0, modification = 1 }
        else
            local f = io.open(p, "rb")
            if not f then return nil end
            local size = f:seek("end")
            f:close()
            a = { size = size, modification = 1, mode = "file" }
        end
        if key then return a[key] end
        return a
    end,
    dir = function(p)
        local h = io.popen(string.format("ls -a %q", p))
        local names = {}
        for line in h:lines() do names[#names + 1] = line end
        h:close()
        local i = 0
        return function() i = i + 1 return names[i] end
    end,
    mkdir = function(p) return os.execute('mkdir -p "' .. p .. '"') end,
})
stub("readhistory", { hist = {}, reload = function() end })
stub("docsettings", {
    hasSidecarFile = function() return false end,
    open = function() return { readSetting = function() return nil end } end,
})
stub("ui/widget/booklist", { getBookInfo = function() return { been_opened = false } end })
stub("ui/network/manager", { runWhenOnline = function(_, cb) cb() end, isOnline = function() return true end })
stub("ui/trapper", {
    wrap = function(_, fn) return fn() end,
    info = function() return true end,
    dismissableRunInSubprocess = function(_, fn) return true, fn() end,
    clear = function() end,
})
stub("json", { decode = function() return {} end, encode = function() return "{}" end })
stub("datetime", { secondsToHour = function(t) return os.date("%H:%M", t) end })
stub("document/documentregistry", {
    hasProvider = function(_, p) return p:match("%.epub$") or p:match("%.pdf$") or p:match("%.cbz$") end,
    openDocument = function() return { getPageCount = function() return 42 end, close = function() end } end,
})
stub("ffi/archiver", { Reader = {
    new = function(self) return setmetatable({}, { __index = self }) end,
    open = function(self, path) self.path = path return io.open(path, "rb") ~= nil end,
    extractToMemory = function(self, name)
        local p = io.popen(string.format("unzip -p %q %q 2>/dev/null", self.path, name), "r")
        local d = p:read("*a"); p:close()
        return d ~= "" and d or nil
    end,
    close = function() end,
} })
S.opened = {}
stub("apps/reader/readerui", { showReader = function(_, file) S.opened[#S.opened + 1] = file end })
S.fm_calls = {}
stub("apps/filemanager/filemanager", { instance = {
    history = { onShowHist = function() S.fm_calls[#S.fm_calls + 1] = "history" end },
    collections = { onShowColl = function() S.fm_calls[#S.fm_calls + 1] = "collections" end },
    filesearcher = { onShowFileSearch = function() S.fm_calls[#S.fm_calls + 1] = "search" end },
} })
S.global = {}
G_reader_settings = G_reader_settings or {
    readSetting = function(_, k) if k == "home_dir" then return S.home_dir end return S.global[k] end,
    saveSetting = function(_, k, v) S.global[k] = v end,
    delSetting = function(_, k) S.global[k] = nil end,
    isTrue = function() return false end,
    nilOrTrue = function() return true end,
}

--- A blitbuffer that records drawing calls.
function S.fakeBB()
    local calls = {}
    return setmetatable({ calls = calls }, { __index = function(_, name)
        return function(_self, ...) calls[#calls + 1] = { name, ... } end
    end })
end

-- Real LuaSettings needs KOReader's dump helpers; a tiny in-memory one is enough here.
local settings_by_path = {}
stub("luasettings", { open = function(_, path)
    local data = settings_by_path[path] or {}
    settings_by_path[path] = data
    return {
        data = data,
        readSetting = function(self, k, d) if data[k] == nil then return d end return data[k] end,
        saveSetting = function(self, k, v) data[k] = v end,
        delSetting = function(self, k) data[k] = nil end,
        isTrue = function(self, k) return data[k] == true end,
        nilOrTrue = function(self, k) return data[k] == nil or data[k] == true end,
        flush = function() end,
    }
end })

-- The default menu order files, from a KOReader checkout when available.
local ko = os.getenv("KOREADER_DIR")
for _, prefix in ipairs({ "reader", "filemanager" }) do
    local mod = "ui/elements/" .. prefix .. "_menu_order"
    package.preload[mod] = function()
        if ko then return dofile(ko .. "/frontend/ui/elements/" .. prefix .. "_menu_order.lua") end
        return {
            ["KOMenu:menu_buttons"] = { "navi", "setting", "tools", "main" },
            navi = { "table_of_contents", "book_map" }, setting = { "frontlight", "device" },
            device = { "time" }, tools = { "statistics", "more_tools" }, more_tools = { "terminal" },
            main = { "history", "exit_menu" }, exit_menu = { "exit" },
        }
    end
end

function S.cleanup()
    os.execute('rm -rf "' .. S.settings_dir .. '"')
end

function S.runScheduled()
    local q = S.scheduled
    S.scheduled = {}
    for _i, fn in ipairs(q) do fn() end
end

return S
