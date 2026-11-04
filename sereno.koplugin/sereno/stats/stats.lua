--[[--
Reading statistics, from what KOReader's Reading statistics plugin records
(sereno/stats/source.lua reads its database). Pure Lua: the raw numbers
come in, the figures the Stats tab shows come out.

raw {
  today = "2026-11-04",                 -- local date
  days = { ["2026-11-04"] = { secs, pages }, ... },  -- the last 7 days
  dates = { "2026-11-04", "2026-11-03", ... },       -- every day with reading, newest first
  total = { secs, books },
  book = { title, authors, pages, read_secs, read_pages, days, percent } or nil,
}
]]

local Stats = {}

local function epoch(date)
    local y, m, d = date:match("^(%d+)-(%d+)-(%d+)$")
    if not y then return nil end
    return os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }
end

local function dayBefore(date)
    return os.date("%Y-%m-%d", epoch(date) - 86400)
end

--- The last `n` dates, today first.
function Stats.lastDays(today, n)
    local out, d = {}, today
    for i = 1, n do
        out[i] = d
        d = dayBefore(d)
    end
    return out
end

--[[--
Days in a row with reading, ending today, or yesterday if today has none
yet (the streak isn't broken before the day is over).
]]
function Stats.streak(dates, today)
    local set = {}
    for _i, d in ipairs(dates or {}) do set[d] = true end
    local d = set[today] and today or dayBefore(today)
    local n = 0
    while set[d] do
        n = n + 1
        d = dayBefore(d)
    end
    return n
end

function Stats.summarize(raw)
    local today = raw.today
    local week = Stats.lastDays(today, 7)
    local s = { week = {} }
    local week_secs, week_pages = 0, 0
    for i = 7, 1, -1 do
        local d = week[i]
        local v = (raw.days or {})[d] or {}
        s.week[#s.week + 1] = { date = d, secs = v.secs or 0, pages = v.pages or 0 }
        week_secs = week_secs + (v.secs or 0)
        week_pages = week_pages + (v.pages or 0)
    end
    local t = (raw.days or {})[today] or {}
    s.today_secs, s.today_pages = t.secs or 0, t.pages or 0
    s.daily_avg_secs = math.floor(week_secs / 7 + 0.5)
    s.pages_per_day = math.floor(week_pages / 7 + 0.5)
    s.streak = Stats.streak(raw.dates, today)
    s.total_secs = raw.total and raw.total.secs or 0
    s.total_books = raw.total and raw.total.books or 0
    s.week_max = 0
    for _i, d in ipairs(s.week) do if d.secs > s.week_max then s.week_max = d.secs end end
    local b = raw.book
    if b then
        s.book = { title = b.title, authors = b.authors, days = b.days or 0, read_secs = b.read_secs or 0,
            percent = b.percent or 0 }
        -- time left: this book's own pace, over the pages still to read
        local per_page = (b.read_pages or 0) > 0 and b.read_secs / b.read_pages or nil
        if per_page and b.pages and b.pages > 0 then
            s.book.left_secs = math.floor(per_page * b.pages * (1 - (b.percent or 0)) + 0.5)
        end
    end
    s.empty = s.total_secs == 0
    return s
end

--- "2 h 13 min", "45 min", "under a minute" (`words` translates h, min, less).
function Stats.duration(secs, words)
    words = words or { h = "h", min = "min", less = "under a minute" }
    local mins = math.floor((secs or 0) / 60 + 0.5)
    if mins < 1 then return words.less end
    local h, m = math.floor(mins / 60), mins % 60
    if h == 0 then return string.format("%d %s", m, words.min) end
    if m == 0 then return string.format("%d %s", h, words.h) end
    return string.format("%d %s %d %s", h, words.h, m, words.min)
end

--- "1h 22m", "50m": the compact form for the number boxes.
function Stats.short(secs, words)
    words = words or { h = "h", m = "m" }
    local mins = math.floor((secs or 0) / 60 + 0.5)
    local h, m = math.floor(mins / 60), mins % 60
    if h == 0 then return string.format("%d%s", m, words.m) end
    if m == 0 then return string.format("%d%s", h, words.h) end
    return string.format("%d%s %d%s", h, words.h, m, words.m)
end

return Stats
