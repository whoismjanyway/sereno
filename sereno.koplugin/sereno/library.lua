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

-- Covers Sereno rendered itself, most recently used last. Bounded, because
-- each one is a full-colour blitbuffer.
local own_covers = { order = {}, bb = {} }
Library.COVER_CACHE = 16
Library.COVER_MAX = { w = 480, h = 720 } -- render size; ImageWidget scales further down

local function rememberCover(file, bb)
    own_covers.bb[file] = bb
    table.insert(own_covers.order, file)
    while #own_covers.order > Library.COVER_CACHE do
        local old = table.remove(own_covers.order, 1)
        if own_covers.bb[old] and own_covers.bb[old] ~= false then own_covers.bb[old]:free() end
        own_covers.bb[old] = nil
    end
end

--- Renders the cover image stored inside an EPUB (its OPF cover item).
local function renderOwnCover(file, metrics)
    if not (metrics and metrics.cover_path) then return nil end
    local ok_a, Archiver = pcall(require, "ffi/archiver")
    if not ok_a then return nil end
    local reader = Archiver.Reader:new()
    if not reader:open(file) then return nil end
    local data = reader:extractToMemory(metrics.cover_path)
    reader:close()
    if not data or #data == 0 then return nil end
    local RenderImage = require("ui/renderimage")
    local ok, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false,
        Library.COVER_MAX.w, Library.COVER_MAX.h)
    if ok and bb then return bb end
    logger.dbg("Sereno: could not render cover of", file)
    return nil
end

--[[--
Cover blitbuffer for a book, or nil. CoverBrowser's cache is used when that
plugin is on; otherwise Sereno renders the cover image found in the EPUB
itself, so covers work with CoverBrowser disabled too.
The caller must not free the returned blitbuffer.
]]
function Library.cover(file, metrics)
    local bim = bookInfoManager()
    if bim then
        local ok, bi = pcall(bim.getBookInfo, bim, file, true)
        if ok and bi and bi.has_cover and not bi.ignore_cover and bi.cover_bb then
            return bi.cover_bb
        end
    end
    local cached = own_covers.bb[file]
    if cached ~= nil then return cached or nil end
    local bb = renderOwnCover(file, metrics)
    rememberCover(file, bb or false) -- remember failures too, to not retry every paint
    return bb
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

--- Counts for the home screen's library row.
function Library.stats()
    Library.newBooks(0) -- make sure the scan ran
    local stats = { unread = #(scan_cache or {}), in_progress = 0, finished = 0 }
    for _i, file in ipairs(Library.history()) do
        local state = BookList.getBookInfo(file) or {}
        if state.been_opened then
            if state.status == "complete" or (state.percent_finished or 0) >= 0.985 then
                stats.finished = stats.finished + 1
            elseif state.status ~= "abandoned" then
                stats.in_progress = stats.in_progress + 1
            end
        end
    end
    return stats
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
