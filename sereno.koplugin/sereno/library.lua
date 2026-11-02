--[[--
KOReader-side data sources for the home screen: reading history, book
state, metadata and covers, and the newest unread books.

Only stable, public pieces of KOReader are used (ReadHistory, BookList,
DocSettings, and CoverBrowser's BookInfoManager when that plugin is on).
]]

local BookList = require("ui/widget/booklist")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local ReadHistory = require("readhistory")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Library = {}

Library.SCAN_MAX_FILES = 3000
Library.SCAN_MAX_DEPTH = 4

local function exists(path)
    return path and lfs.attributes(path, "mode") == "file"
end

-- CoverBrowser keeps titles, authors, series and covers in its database.
local function bookInfoManager()
    return package.loaded["bookinfomanager"]
end

function Library.history()
    local files = {}
    for _i, item in ipairs(ReadHistory.hist or {}) do
        if not item.dim and exists(item.file) then files[#files + 1] = item.file end
    end
    return files
end

local function splitAuthors(s)
    if type(s) ~= "string" then return s end
    local out = {}
    for a in s:gmatch("[^\n]+") do out[#out + 1] = a end
    return out
end

--- Title, authors, series, progress and status of a book, or nil if it's gone.
-- `metrics` (optional) supplies metadata Sereno read from the file itself.
function Library.bookInfo(file, metrics)
    if not exists(file) then return nil end
    local info = {}
    local state = BookList.getBookInfo(file) or {}
    info.been_opened = state.been_opened
    info.status = state.been_opened and (state.status or "reading") or "new"
    info.percent = state.percent_finished or 0

    local bim = bookInfoManager()
    if bim then
        local ok, bi = pcall(bim.getBookInfo, bim, file, false)
        if ok and bi and not bi.ignore_meta then
            info.title, info.authors = bi.title, splitAuthors(bi.authors)
            info.series, info.series_index = bi.series, bi.series_index
        end
    end
    if not info.title and state.been_opened then
        local ok, ds = pcall(DocSettings.open, DocSettings, file)
        local props = ok and ds and ds:readSetting("doc_props")
        if props then
            info.title, info.authors = props.title, splitAuthors(props.authors)
            info.series, info.series_index = props.series, props.series_index
        end
    end
    if not info.title and metrics then
        info.title, info.authors = metrics.title, metrics.authors
    end
    if info.title == "" then info.title = nil end
    return info
end

--- Cover blitbuffer from CoverBrowser's cache (nil when unavailable).
-- The caller must not free it: it belongs to the returned bookinfo.
function Library.cover(file)
    local bim = bookInfoManager()
    if not bim then return nil end
    local ok, bi = pcall(bim.getBookInfo, bim, file, true)
    if ok and bi and bi.has_cover and not bi.ignore_cover and bi.cover_bb then
        return bi.cover_bb
    end
    return nil
end

--[[--
Newest books that were never opened, from the home folder.
The scan is bounded (files and depth) and cached until `invalidate()`.
]]
local scan_cache
function Library.newBooks(n)
    if not scan_cache then
        scan_cache = {}
        local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
        if home and lfs.attributes(home, "mode") == "directory" then
            local found = {}
            local function walk(dir, depth)
                if depth > Library.SCAN_MAX_DEPTH or #found >= Library.SCAN_MAX_FILES then return end
                local ok, iter, state = pcall(lfs.dir, dir)
                if not ok then return end
                for name in iter, state do
                    if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                        local path = dir .. "/" .. name
                        local attr = lfs.attributes(path)
                        if attr and attr.mode == "directory" then
                            walk(path, depth + 1)
                        elseif attr and attr.mode == "file" and DocumentRegistry:hasProvider(path) then
                            found[#found + 1] = { path = path, mtime = attr.modification or 0 }
                        end
                    end
                end
            end
            walk(home, 1)
            table.sort(found, function(a, b) return a.mtime > b.mtime end)
            for _i, f in ipairs(found) do
                if not DocSettings:hasSidecarFile(f.path) then scan_cache[#scan_cache + 1] = f.path end
            end
            logger.dbg("Sereno: library scan found", #found, "books,", #scan_cache, "unopened")
        end
    end
    local out = {}
    for i = 1, math.min(n or 10, #scan_cache) do out[i] = scan_cache[i] end
    return out
end

function Library.invalidate()
    scan_cache = nil
end

--- All book files under a folder (for counting a whole folder).
function Library.booksIn(dir, recursive)
    local out = {}
    local function walk(d, depth)
        local ok, iter, state = pcall(lfs.dir, d)
        if not ok then return end
        for name in iter, state do
            if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                local path = d .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" and recursive and depth < 8 then
                    walk(path, depth + 1)
                elseif mode == "file" and DocumentRegistry:hasProvider(path) then
                    out[#out + 1] = path
                end
            end
        end
    end
    walk(dir, 1)
    table.sort(out)
    return out
end

return Library
