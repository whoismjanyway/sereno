--[[--
Library-wide store for book metrics, Sereno's equivalent of Calibre's
custom columns.

One small Lua table file (settings/sereno/metrics.lua) keyed by file path.
Each record keeps the file size and modification time it was computed
for, so a replaced file is re-analysed, and the analyser version, so an
improved algorithm refreshes old results. Books are never opened and no
sidecar (.sdr) folders are created for books you haven't read.

File system and serialisation are injected for tests.
]]

local Cache = {}
Cache.__index = Cache

local function serialize(value, indent)
    indent = indent or ""
    local t = type(value)
    if t == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return "0" end
        return string.format("%.17g", value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "boolean" then
        return tostring(value)
    elseif t == "table" then
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return a < b end
            return type(a) == "number"
        end)
        local inner = indent .. "  "
        local out = { "{\n" }
        for _i, k in ipairs(keys) do
            local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. serialize(k) .. "]")
            out[#out + 1] = inner .. key .. " = " .. serialize(value[k], inner) .. ",\n"
        end
        out[#out + 1] = indent .. "}"
        return table.concat(out)
    end
    return "nil"
end
Cache.serialize = serialize

--[[--
@string path where to store the cache
@tparam table fs { read(path), write(path, content), attributes(path) -> {size, modification} }
@number version analyser version; older records are treated as missing
]]
function Cache.new(path, fs, version)
    local o = setmetatable({ path = path, fs = fs, version = version or 1, dirty = false }, Cache)
    o:load()
    return o
end

function Cache:load()
    self.records = {}
    local content = self.fs.read(self.path)
    if not content then return end
    local loader = loadstring or load
    local fn = loader(content, "=sereno-metrics")
    if not fn then return end
    local ok, t = pcall(fn)
    if ok and type(t) == "table" and type(t.books) == "table" then
        self.records = t.books
    end
end

function Cache:flush()
    if not self.dirty then return true end
    local ok, err = self.fs.write(self.path, "-- Sereno book metrics cache, safe to delete.\nreturn "
        .. serialize({ books = self.records }) .. "\n")
    if ok then self.dirty = false end
    return ok, err
end

local function stamp(fs, file)
    local a = fs.attributes(file)
    if not a then return nil end
    return a.size, a.modification
end

--- Returns the metrics for `file` if they are still valid.
function Cache:get(file)
    local r = self.records[file]
    if not r or r.version ~= self.version then return nil end
    local size, mtime = stamp(self.fs, file)
    if not size or r.file_size ~= size or r.file_mtime ~= mtime then return nil end
    return r
end

--- Returns any stored metrics, even stale ones (for display while re-analysing).
function Cache:peek(file)
    return self.records[file]
end

function Cache:put(file, metrics)
    local size, mtime = stamp(self.fs, file)
    metrics.file_size, metrics.file_mtime = size, mtime
    metrics.version = metrics.version or self.version
    self.records[file] = metrics
    self.dirty = true
    return metrics
end

--- Stores a downloaded page count next to the computed ones.
function Cache:setDownloaded(file, result)
    local r = self.records[file]
    if not r then return nil end
    r.pages = r.pages or {}
    r.pages.downloaded = result.pages
    r.download = { source = result.source, editions = result.editions, key = result.key }
    self.dirty = true
    return r
end

--- Chooses which page count to show for a book.
-- `method` is a user setting: "print" (default), "downloaded", "apnx", "adobe", "chars".
-- A downloaded count wins when the method is "downloaded" and one exists.
function Cache.pageCount(r, method)
    if not r or not r.pages then return nil end
    method = method or "print"
    return r.pages[method] or r.pages.print, (r.pages[method] and method or "print")
end

function Cache:rename(old, new)
    if self.records[old] then
        self.records[new] = self.records[old]
        self.records[old] = nil
        self.dirty = true
    end
end

function Cache:remove(file)
    if self.records[file] then
        self.records[file] = nil
        self.dirty = true
    end
end

--- Drops records whose file no longer exists.
function Cache:prune()
    local removed = 0
    for file in pairs(self.records) do
        if not self.fs.attributes(file) then
            self.records[file] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then self.dirty = true end
    return removed
end

return Cache
