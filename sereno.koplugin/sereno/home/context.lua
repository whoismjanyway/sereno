--[[--
Decides what the home screen should say, from reading history, book state
and book metrics. Pure Lua; everything comes in through `sources`.

The home screen is contextual rather than a dashboard of widgets:
* reading  – one large "continue" card: where you are, in stable print
             pages, and how long the rest of the book takes at your pace
* finished – you just finished a book: say so, and put the next one forward
* start    – nothing read yet: the newest book in the library, ready to open
* empty    – no books found
]]

local Cache = require("sereno/metrics/cache")

local Context = {}

Context.FINISHED_AT = 0.985 -- KOReader often leaves the last page at 98-99%
Context.DEFAULT_WPM = 230

-- part of the day, translated by the screen ("Good morning"...)
local function partOfDay(hour)
    if hour < 5 then return "night" end
    if hour < 12 then return "morning" end
    if hour < 18 then return "afternoon" end
    return "evening"
end

local function isNight(hour) return hour >= 21 or hour < 6 end

--- Builds the description of one book, as the home screen shows it.
function Context.describe(file, sources, opts)
    local info = sources.book_info(file) or {}
    local metrics = sources.metrics and sources.metrics(file)
    local percent = info.percent or 0
    local book = {
        file = file,
        title = info.title or (file:match("([^/]+)$") or file):gsub("%.[^.]+$", ""),
        authors = info.authors,
        series = info.series,
        series_index = info.series_index,
        percent = percent,
        status = info.status or (info.been_opened and "reading" or "new"),
        has_metrics = metrics ~= nil,
    }
    if metrics then
        local total, method = Cache.pageCount(metrics, opts.page_method)
        book.page_total, book.page_method = total, method
        if total and total > 0 then
            book.page_now = math.max(1, math.min(total, math.floor(percent * total + 0.5)))
        end
        if metrics.words then
            book.words = metrics.words
            book.minutes_left = math.ceil(metrics.words * (1 - percent) / (opts.wpm or Context.DEFAULT_WPM))
            book.minutes_total = math.ceil(metrics.words / (opts.wpm or Context.DEFAULT_WPM))
        end
        book.readability = metrics.readability and metrics.readability.label
    end
    return book
end

local function isFinished(book)
    return book.status == "complete" or book.percent >= Context.FINISHED_AT
end

--[[--
@tparam table sources
  history()         -> list of files, most recent first
  book_info(file)   -> { title, authors, series, series_index, percent, status, been_opened } or nil if missing
  new_books(n)      -> list of unopened files, newest first (optional)
  metrics(file)     -> cached metrics record or nil (optional)
  stats()           -> { unread, in_progress, finished } library counts (optional)
@tparam table opts { now = os.date("*t") table, page_method, wpm, shelf_size = 4 }
]]
function Context.build(sources, opts)
    opts = opts or {}
    local now = opts.now or os.date("*t")
    local shelf_size = opts.shelf_size or 4
    local model = {
        part_of_day = partOfDay(now.hour),
        is_night = isNight(now.hour),
        date = now,
        shelf = {},
        stats = sources.stats and sources.stats() or nil,
    }

    local seen = {}
    local hero
    local in_progress = {}
    for _i, file in ipairs(sources.history() or {}) do
        local info = sources.book_info(file)
        if info then
            local book = Context.describe(file, sources, opts)
            if not hero then
                hero = book
            elseif not isFinished(book) and book.status ~= "abandoned" and book.percent > 0 then
                in_progress[#in_progress + 1] = book
            end
        end
    end

    if hero then
        model.state = isFinished(hero) and "finished" or "reading"
        model.hero = hero
        seen[hero.file] = true
    end

    -- the shelf: next in the series, then other books in progress, then new ones
    local function add(book, reason)
        if #model.shelf >= shelf_size or seen[book.file] then return end
        book.reason = reason
        model.shelf[#model.shelf + 1] = book
        seen[book.file] = true
    end

    local new_files = sources.new_books and sources.new_books(shelf_size * 3) or {}
    if hero and hero.series then
        for _i, file in ipairs(new_files) do
            local info = sources.book_info(file)
            if info and info.series == hero.series and (info.series_index or 0) > (hero.series_index or 0) then
                add(Context.describe(file, sources, opts), "series")
            end
        end
    end
    for _i, book in ipairs(in_progress) do add(book, "in_progress") end
    for _i, file in ipairs(new_files) do
        if sources.book_info(file) then add(Context.describe(file, sources, opts), "new") end
    end

    if not hero then
        if #model.shelf > 0 then
            model.state = "start"
            model.hero = table.remove(model.shelf, 1)
        else
            model.state = "empty"
        end
    elseif model.state == "finished" and #model.shelf > 0 then
        model.up_next = model.shelf[1]
    end
    return model
end

--- "2 h 10 min", "45 min", "under a minute"
function Context.formatDuration(minutes, words)
    words = words or { h = "h", min = "min", less = "under a minute" }
    if not minutes then return nil end
    if minutes < 1 then return words.less end
    if minutes < 60 then return string.format("%d %s", minutes, words.min) end
    local h, m = math.floor(minutes / 60), minutes % 60
    if h >= 10 or m == 0 then return string.format("%d %s", h, words.h) end
    return string.format("%d %s %d %s", h, words.h, m, words.min)
end

return Context
