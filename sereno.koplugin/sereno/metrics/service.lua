--[[--
KOReader glue for the metrics engine: where the cache lives, how ZIP
entries are inflated (libarchive), how fixed-layout documents report their
pages, folder-wide counting with a cancellable progress message, and the
Open Library download.
]]

local Analyzer = require("sereno/metrics/analyzer")
local Cache = require("sereno/metrics/cache")
local OpenLibrary = require("sereno/metrics/openlibrary")

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Service = {}

local FIXED_LAYOUT = { pdf = true, djvu = true, xps = true, oxps = true }

local cache

function Service.cache()
    if not cache then
        local dir = DataStorage:getSettingsDir() .. "/sereno"
        if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
        cache = Cache.new(dir .. "/metrics.lua", {
            read = function(p)
                local f = io.open(p, "rb")
                if not f then return nil end
                local s = f:read("*a"); f:close()
                return s
            end,
            write = function(p, content)
                local tmp = p .. ".tmp"
                local f, err = io.open(tmp, "wb")
                if not f then return false, err end
                f:write(content); f:close()
                return os.rename(tmp, p)
            end,
            attributes = function(p) return lfs.attributes(p) end,
        }, Analyzer.VERSION)
    end
    return cache
end

--- Extractor over sereno/archive (libarchive, then the device's unzip), one archive kept open per book.
local function archiveExtractor()
    local Archive = require("sereno/archive")
    local zip, opened_path
    local extract = function(path, name)
        if opened_path ~= path then
            if zip then zip:close() end
            zip, opened_path = Archive.open(path), path
        end
        return zip:read(name)
    end
    local close = function()
        if zip then zip:close() end
        zip, opened_path = nil, nil
    end
    return extract, close
end

local function pageCount(path)
    local ext = (path:match("%.(%w+)$") or ""):lower()
    if not FIXED_LAYOUT[ext] then return nil end
    local DocumentRegistry = require("document/documentregistry")
    local doc = DocumentRegistry:openDocument(path)
    if not doc then return nil end
    local ok, n = pcall(doc.getPageCount, doc)
    doc:close()
    return ok and n or nil
end

--- Metrics for a file, computed when missing or stale. Returns record or nil, err.
function Service.get(file, force)
    local c = Service.cache()
    if not force then
        local r = c:get(file)
        if r then return r end
    end
    local extract, close = archiveExtractor()
    local ok, metrics, err = pcall(Analyzer.analyze, file, { extract = extract, page_count = pageCount })
    close()
    if not ok then
        logger.warn("Sereno: analysis failed for", file, metrics)
        return nil, tostring(metrics)
    end
    if not metrics then return nil, err end
    -- keep a downloaded count across re-analysis
    local old = c:peek(file)
    if old and old.pages and old.pages.downloaded then
        metrics.pages.downloaded = old.pages.downloaded
        metrics.download = old.download
    end
    c:put(file, metrics)
    c:flush()
    return metrics
end

--- Cached metrics only, never computing (for drawing lists quickly).
function Service.peek(file)
    return Service.cache():get(file)
end

--[[--
Counts every book in `files`, showing progress. Runs inside Trapper so the
user can tap to cancel; returns counted, failed, skipped.
]]
function Service.countAll(files, texts)
    local Trapper = require("ui/trapper")
    local counted, failed, skipped = 0, 0, 0
    Trapper:wrap(function()
        local c = Service.cache()
        for i, file in ipairs(files) do
            if c:get(file) then
                skipped = skipped + 1
            else
                local go_on = Trapper:info(texts.progress(i, #files, file:match("([^/]+)$")))
                if not go_on then break end
                if Service.get(file) then counted = counted + 1 else failed = failed + 1 end
            end
        end
        Trapper:clear()
    end)
    return counted, failed, skipped
end

--- Default HTTP getter: KOReader's LuaSocket (with its HTTPS support) and timeouts.
local function httpGet(url, headers)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    socketutil:set_timeout(10, 30)
    local code = socket.skip(1, http.request({ url = url, method = "GET", headers = headers, sink = ltn12.sink.table(sink) }))
    socketutil:reset_timeout()
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    return table.concat(sink)
end

--- Downloads a printed page count for `file` and stores it. Needs network.
function Service.download(file)
    local metrics, err = Service.get(file)
    if not metrics then return nil, err end
    local JSON = require("json")
    local result, derr = OpenLibrary.fetch(
        { isbn = metrics.isbn, title = metrics.title, authors = metrics.authors },
        { http_get = httpGet, json_decode = JSON.decode })
    if not result then return nil, derr end
    local c = Service.cache()
    c:setDownloaded(file, result)
    c:flush()
    return result
end

function Service.fileRenamed(old, new)
    local c = Service.cache()
    c:rename(old, new)
    c:flush()
end

return Service
