-- E-ink refresh coordinator.
local H = require("helper")
local test, eq, list = H.it, H.eq, H.list
local Refresh = require("sereno/eink/refresh")

H.describe("refresh coordinator")
local function fakeUI()
    local ui = { dirty = {}, scheduled = {} }
    ui.setDirty = function(w, mode, region) ui.dirty[#ui.dirty + 1] = { w = w, mode = mode, region = region } end
    ui.scheduleIn = function(s, fn) ui.scheduled[#ui.scheduled + 1] = { s = s, fn = fn } end
    ui.unschedule = function(fn)
        for i = #ui.scheduled, 1, -1 do if ui.scheduled[i].fn == fn then table.remove(ui.scheduled, i) end end
    end
    ui.run = function()
        local q = ui.scheduled
        ui.scheduled = {}
        for _, job in ipairs(q) do job.fn() end
        return q
    end
    return ui
end

test("two invalidations in one tick cost one refresh over the union", function()
    local ui = fakeUI()
    local r = Refresh.new{ ui = ui, screen = { w = 1000, h = 1000 } }
    local win = {}
    r:register("clock", { window = win, region = function() return { x = 0, y = 0, w = 100, h = 50 } end })
    r:register("battery", { window = win, region = function() return { x = 300, y = 10, w = 50, h = 20 } end })
    r:invalidate("clock"); r:invalidate("battery")
    ui.run()
    eq(#ui.dirty, 1)
    eq(ui.dirty[1].mode, "ui")
    local g = ui.dirty[1].region
    eq(g.x .. "," .. g.y .. "," .. g.w .. "," .. g.h, "0,0,350,50")
    eq(r:saved(), 1)
end)

test("large changes flash, small ones don't", function()
    local ui = fakeUI()
    local r = Refresh.new{ ui = ui, screen = { w = 100, h = 100 } }
    r:register("big", { window = {}, region = function() return { x = 0, y = 0, w = 100, h = 60 } end })
    r:invalidate("big"); ui.run()
    eq(ui.dirty[1].mode, "flashui")
end)

test("widgets without a region refresh the whole window and flash", function()
    local ui = fakeUI()
    local r = Refresh.new{ ui = ui, screen = { w = 100, h = 100 } }
    r:register("w", { window = {} })
    r:invalidate("w"); ui.run()
    eq(ui.dirty[1].region, nil)
    eq(ui.dirty[1].mode, "flashui")
end)

test("a cleaning flash comes after N partial refreshes", function()
    local ui = fakeUI()
    local r = Refresh.new{ ui = ui, screen = { w = 100, h = 100 }, flash_every = 3 }
    r:register("w", { window = {}, region = function() return { x = 0, y = 0, w = 1, h = 1 } end })
    local modes = {}
    for i = 1, 4 do r:invalidate("w"); ui.run(); modes[i] = ui.dirty[i].mode end
    eq(list(modes), "ui,ui,ui,flashui")
end)

test("static widgets paint once", function()
    local ui = fakeUI()
    local r = Refresh.new{ ui = ui }
    r:register("logo", { window = {}, policy = "static", region = function() return { x = 0, y = 0, w = 1, h = 1 } end })
    eq(r:invalidate("logo"), true)
    eq(r:invalidate("logo"), false)
end)

test("invisible widgets cost nothing", function()
    local ui = fakeUI()
    local r = Refresh.new{ ui = ui }
    r:register("w", { window = {}, visible = function() return false end })
    eq(r:invalidate("w"), false)
    eq(#ui.scheduled, 0)
end)

test("periodic widgets share one timer aligned to the minute", function()
    local ui = fakeUI()
    local now = 125 -- 2:05
    local r = Refresh.new{ ui = ui, now = function() return now end, screen = { w = 100, h = 100 } }
    local updates = 0
    local win = {}
    r:register("clock", { window = win, policy = "periodic", period = 60, update = function() updates = updates + 1 end,
        region = function() return { x = 0, y = 0, w = 10, h = 10 } end })
    r:register("battery", { window = win, policy = "periodic", period = 60,
        region = function() return { x = 20, y = 0, w = 10, h = 10 } end })
    eq(#ui.scheduled, 1, "one shared timer")
    eq(ui.scheduled[1].s, 55, "fires at the top of the next minute")
    now = 180
    ui.run()          -- tick -> invalidates both + schedules flush + re-arms timer
    ui.run()          -- flush
    eq(updates, 1)
    eq(#ui.dirty, 1, "clock and battery share a refresh")
end)

test("pause stops the timer, resume catches up once", function()
    local ui = fakeUI()
    local now = 0
    local r = Refresh.new{ ui = ui, now = function() return now end }
    r:register("clock", { window = {}, policy = "periodic", period = 60 })
    r:pause()
    eq(#ui.scheduled, 0)
    now = 600
    eq(r:resume(), true)
    ui.run()
    eq(#ui.dirty, 1)
end)

test("unregistering the last periodic widget disarms the timer", function()
    local ui = fakeUI()
    local r = Refresh.new{ ui = ui, now = function() return 0 end }
    r:register("clock", { window = {}, policy = "periodic" })
    r:unregister("clock")
    eq(#ui.scheduled, 0)
end)

