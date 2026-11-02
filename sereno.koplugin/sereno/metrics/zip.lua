--[[--
Reads a ZIP file's central directory in pure Lua.

EPUB and CBZ files are ZIP archives. We need each entry's name, compressed
and uncompressed sizes without inflating anything (the Adobe-style page
count is based on compressed sizes, which KOReader's Archiver does not
expose). Decompression itself is delegated to an `extract` function, so
on a device it can use KOReader's libarchive bindings.
]]

local Zip = {}

local EOCD_SIG = "PK\5\6"
local CDIR_SIG = "PK\1\2"
local MAX_COMMENT = 65535
local EOCD_MIN = 22

local function u16(s, i)
    local a, b = s:byte(i, i + 1)
    return a + b * 256
end

local function u32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return a + b * 256 + c * 65536 + d * 16777216
end

--- Finds the end-of-central-directory record.
local function findEOCD(f, file_size)
    local tail_len = math.min(file_size, EOCD_MIN + MAX_COMMENT)
    f:seek("set", file_size - tail_len)
    local tail = f:read(tail_len)
    if not tail then return nil end
    -- search backwards: the comment could contain the signature, the last hit is the real one
    local pos
    local start = 1
    while true do
        local p = tail:find(EOCD_SIG, start, true)
        if not p then break end
        if p + EOCD_MIN - 1 <= #tail then pos = p end
        start = p + 1
    end
    if not pos then return nil end
    return {
        entries = u16(tail, pos + 10),
        cd_size = u32(tail, pos + 12),
        cd_offset = u32(tail, pos + 16),
    }
end

--[[--
Lists the entries of a ZIP archive.
@string path
@treturn table|nil list of { name, method, compressed_size, size, offset } in archive order
@treturn table|nil same entries indexed by name
@treturn string|nil error
]]
function Zip.index(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, nil, err end
    local file_size = f:seek("end")
    if not file_size or file_size < EOCD_MIN then
        f:close()
        return nil, nil, "not a zip file"
    end
    local eocd = findEOCD(f, file_size)
    if not eocd or eocd.cd_offset + eocd.cd_size > file_size then
        f:close()
        return nil, nil, "zip central directory not found"
    end
    f:seek("set", eocd.cd_offset)
    local cd = f:read(eocd.cd_size)
    f:close()
    if not cd or #cd < eocd.cd_size then return nil, nil, "truncated zip" end

    local list, by_name = {}, {}
    local i = 1
    while i + 45 <= #cd and cd:sub(i, i + 3) == CDIR_SIG do
        local method = u16(cd, i + 10)
        local csize = u32(cd, i + 20)
        local usize = u32(cd, i + 24)
        local name_len = u16(cd, i + 28)
        local extra_len = u16(cd, i + 30)
        local comment_len = u16(cd, i + 32)
        local offset = u32(cd, i + 42)
        local name = cd:sub(i + 46, i + 45 + name_len)
        local entry = {
            name = name,
            method = method,
            compressed_size = csize,
            size = usize,
            offset = offset,
            is_dir = name:sub(-1) == "/",
        }
        list[#list + 1] = entry
        by_name[name] = entry
        i = i + 46 + name_len + extra_len + comment_len
    end
    if #list == 0 then return nil, nil, "empty zip" end
    return list, by_name
end

--[[--
Reads an uncompressed ("stored") entry directly. Deflated entries return nil;
callers fall back to an extractor.
]]
function Zip.readStored(path, entry)
    if entry.method ~= 0 then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    f:seek("set", entry.offset)
    local header = f:read(30)
    if not header or header:sub(1, 4) ~= "PK\3\4" then f:close() return nil end
    local skip = u16(header, 27) + u16(header, 29)
    f:seek("cur", skip)
    local data = f:read(entry.size)
    f:close()
    return data
end

return Zip
