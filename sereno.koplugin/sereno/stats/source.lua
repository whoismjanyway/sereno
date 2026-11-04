--[[--
Reads KOReader's reading statistics database (settings/statistics.sqlite3,
written by the Reading statistics plugin that ships with KOReader) into
the raw numbers sereno/stats/stats.lua expects. Read-only: Sereno never
writes to it. Returns nil when the database isn't there (the plugin off,
or never used).
]]

local Source = {}

local function today()
    return os.date("%Y-%m-%d")
end

local function midnight(days_ago)
    local t = os.date("*t")
    t.hour, t.min, t.sec = 0, 0, 0
    return os.time(t) - (days_ago or 0) * 86400
end

--- @tparam string db_path; @tparam table opts { book_percent = function(title) -> 0..1 }
function Source.read(db_path, opts)
    opts = opts or {}
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(db_path, "mode") ~= "file" then return nil end
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq then return nil end
    local ok, raw = pcall(function()
        local conn = SQ3.open(db_path)
        local r = { today = today(), days = {}, dates = {} }
        -- one "page" = one book page read (a page read twice counts once)
        local res = conn:exec(string.format([[
            SELECT date(start_time, 'unixepoch', 'localtime') AS d, sum(duration), count(DISTINCT id_book * 1000000 + page)
            FROM page_stat_data WHERE start_time >= %d GROUP BY d;]], midnight(6)))
        if res and res[1] then
            for i = 1, #res[1] do
                r.days[res[1][i]] = { secs = tonumber(res[2][i]) or 0, pages = tonumber(res[3][i]) or 0 }
            end
        end
        res = conn:exec([[SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS d FROM page_stat_data
            ORDER BY d DESC LIMIT 1000;]])
        if res and res[1] then for i = 1, #res[1] do r.dates[i] = res[1][i] end end
        local secs, books = conn:rowexec("SELECT sum(duration), count(DISTINCT id_book) FROM page_stat_data;")
        r.total = { secs = tonumber(secs) or 0, books = tonumber(books) or 0 }
        -- the book read most recently
        res = conn:exec([[SELECT id, title, authors, pages, total_read_time, total_read_pages FROM book
            ORDER BY last_open DESC LIMIT 1;]])
        if res and res[1] and res[1][1] then
            local id = tonumber(res[1][1])
            local book = { title = res[2][1], authors = res[3][1], pages = tonumber(res[4][1]),
                read_secs = tonumber(res[5][1]) or 0, read_pages = tonumber(res[6][1]) or 0 }
            book.days = tonumber(conn:rowexec(string.format([[SELECT count(DISTINCT date(start_time, 'unixepoch', 'localtime'))
                FROM page_stat_data WHERE id_book = %d;]], id))) or 0
            book.percent = opts.book_percent and opts.book_percent(book.title) or nil
            if not book.percent and book.pages and book.pages > 0 then
                book.percent = math.min(1, book.read_pages / book.pages)
            end
            r.book = book
        end
        conn:close()
        return r
    end)
    if ok then return raw end
    return nil, raw
end

return Source
