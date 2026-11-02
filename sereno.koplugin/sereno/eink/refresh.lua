--[[--
Refresh coordinator for e-ink ("refresh budget").

Widgets don't call UIManager:setDirty themselves. They declare a policy and
call invalidate(); the coordinator:

* coalesces every invalidation made during the same tick into ONE refresh
  per window, covering the union of the dirty regions;
* drives all periodic widgets (clock, battery...) from one shared timer
  aligned to the minute, so they repaint together instead of one by one;
* pauses periodic work while the device sleeps or nothing periodic is shown;
* decides between a fast "ui" refresh and a cleaning "flashui" one, based on
  how much of the screen changed and how many partial refreshes accumulated
  (ghosting control);
* keeps counters so the cost of a layout can be shown to the user.

KOReader's UIManager already merges overlapping refreshes inside a single
repaint; this module works one level up, across widgets and across time.

Everything external (UIManager, clock, screen size, rect constructor) is
injected, so the logic is testable with plain Lua.
]]

local Refresh = {}
Refresh.__index = Refresh

Refresh.STATIC, Refresh.EVENT, Refresh.PERIODIC = "static", "event", "periodic"

local function union(a, b)
    if not a then return { x = b.x, y = b.y, w = b.w, h = b.h } end
    local x1 = math.min(a.x, b.x)
    local y1 = math.min(a.y, b.y)
    local x2 = math.max(a.x + a.w, b.x + b.w)
    local y2 = math.max(a.y + a.h, b.y + b.h)
    return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
end

--[[--
@tparam table deps
  ui           object with setDirty(widget, mode, region), scheduleIn(sec, fn), unschedule(fn)
  now          function returning seconds (float)
  screen       {w=, h=}
  make_rect    function(r) -> rect object understood by ui.setDirty (default: identity)
  flash_area   fraction of the screen above which a refresh flashes (default 0.5)
  flash_every  partial refreshes before a cleaning flash (default 8; 0 = never)
]]
function Refresh.new(deps)
    local o = setmetatable({}, Refresh)
    o.ui = assert(deps.ui, "ui required")
    o.now = deps.now or os.time
    o.screen = deps.screen or { w = 1, h = 1 }
    o.make_rect = deps.make_rect or function(r) return r end
    o.flash_area = deps.flash_area or 0.5
    o.flash_every = deps.flash_every or 8
    o.entries = {}        -- widget -> entry
    o.pending = {}        -- window -> region (union)
    o.pending_full = {}   -- window -> true when a widget had no region
    o.flush_scheduled = false
    o.paused = false
    o.partials_since_flash = 0
    o.stats = { invalidations = 0, refreshes = 0, flashes = 0, periodic_ticks = 0 }
    o._flush = function() o:flush() end
    o._tick = function() o:tick() end
    return o
end

--[[--
Register a widget.
@tparam table spec
  window     top-level widget to repaint (the one shown with UIManager:show)
  policy     "static" | "event" | "periodic"
  period     seconds between updates for periodic widgets (default 60)
  region     function() -> {x,y,w,h} of the widget on screen (optional)
  visible    function() -> bool (optional, default true)
  update     function() called before a periodic repaint (optional)
]]
function Refresh:register(widget, spec)
    assert(spec and spec.window, "window required")
    local entry = {
        window = spec.window,
        policy = spec.policy or Refresh.EVENT,
        period = spec.period or 60,
        region = spec.region,
        visible = spec.visible,
        update = spec.update,
        last_run = self.now(),
    }
    self.entries[widget] = entry
    if entry.policy == Refresh.PERIODIC then self:_armTimer() end
end

function Refresh:unregister(widget)
    self.entries[widget] = nil
    if not self:_hasVisiblePeriodic() then self:_disarmTimer() end
end

function Refresh:_isVisible(entry)
    return entry.visible == nil or entry.visible()
end

function Refresh:invalidate(widget)
    local entry = self.entries[widget]
    if not entry then return false end
    self.stats.invalidations = self.stats.invalidations + 1
    if entry.policy == Refresh.STATIC and entry.painted then
        return false -- static widgets repaint only with their window
    end
    entry.painted = true
    if not self:_isVisible(entry) then return false end
    local r = entry.region and entry.region()
    if r then
        self.pending[entry.window] = union(self.pending[entry.window], r)
    else
        self.pending_full[entry.window] = true
    end
    if not self.flush_scheduled then
        self.flush_scheduled = true
        self.ui.scheduleIn(0, self._flush)
    end
    return true
end

function Refresh:_chooseMode(region)
    local screen_area = math.max(1, self.screen.w * self.screen.h)
    local area = region and (region.w * region.h) or screen_area
    local big = area / screen_area >= self.flash_area
    local tired = self.flash_every > 0 and self.partials_since_flash >= self.flash_every
    if big or tired then
        self.partials_since_flash = 0
        self.stats.flashes = self.stats.flashes + 1
        return "flashui"
    end
    self.partials_since_flash = self.partials_since_flash + 1
    return "ui"
end

function Refresh:flush()
    self.flush_scheduled = false
    local windows = {}
    for w in pairs(self.pending) do windows[w] = true end
    for w in pairs(self.pending_full) do windows[w] = true end
    for window in pairs(windows) do
        local region = not self.pending_full[window] and self.pending[window] or nil
        local mode = self:_chooseMode(region)
        self.ui.setDirty(window, mode, region and self.make_rect(region) or nil)
        self.stats.refreshes = self.stats.refreshes + 1
    end
    self.pending, self.pending_full = {}, {}
end

function Refresh:_hasVisiblePeriodic()
    for _, e in pairs(self.entries) do
        if e.policy == Refresh.PERIODIC and self:_isVisible(e) then return true end
    end
    return false
end

-- Next run at the top of the next minute (or sooner for sub-minute periods),
-- so a clock and a battery gauge always land in the same refresh.
function Refresh:_nextDelay()
    local shortest
    for _, e in pairs(self.entries) do
        if e.policy == Refresh.PERIODIC and (not shortest or e.period < shortest) then
            shortest = e.period
        end
    end
    shortest = shortest or 60
    local t = self.now()
    local step = shortest >= 60 and 60 or shortest
    local delay = step - (t % step)
    if delay < 0.05 then delay = delay + step end
    return delay
end

function Refresh:_armTimer()
    if self.paused or self.timer_armed then return end
    self.timer_armed = true
    self.ui.scheduleIn(self:_nextDelay(), self._tick)
end

function Refresh:_disarmTimer()
    if not self.timer_armed then return end
    self.timer_armed = false
    self.ui.unschedule(self._tick)
end

-- Due when the clock entered a new aligned slot (a new minute for a 60 s
-- widget), so the first tick after registering already shows fresh data.
function Refresh:_due(entry, t)
    local p = math.max(1, entry.period)
    return math.floor(t / p) ~= math.floor(entry.last_run / p)
end

function Refresh:tick()
    self.timer_armed = false
    if self.paused then return end
    self.stats.periodic_ticks = self.stats.periodic_ticks + 1
    local t = self.now()
    for widget, e in pairs(self.entries) do
        if e.policy == Refresh.PERIODIC and self:_isVisible(e) and self:_due(e, t) then
            e.last_run = t
            if e.update then e.update() end
            self:invalidate(widget)
        end
    end
    if self:_hasVisiblePeriodic() then self:_armTimer() end
end

--- Call on device suspend / when the home screen is covered.
function Refresh:pause()
    self.paused = true
    self:_disarmTimer()
end

--- Call on resume / when the home screen is visible again.
function Refresh:resume()
    self.paused = false
    local stale = false
    local t = self.now()
    for widget, e in pairs(self.entries) do
        if e.policy == Refresh.PERIODIC and self:_due(e, t) then
            e.last_run = t
            if e.update then e.update() end
            self:invalidate(widget)
            stale = true
        end
    end
    if self:_hasVisiblePeriodic() then self:_armTimer() end
    return stale
end

--- How many invalidations did not cost a refresh of their own.
function Refresh:saved()
    return math.max(0, self.stats.invalidations - self.stats.refreshes)
end

function Refresh:resetStats()
    self.stats = { invalidations = 0, refreshes = 0, flashes = 0, periodic_ticks = 0 }
end

return Refresh
