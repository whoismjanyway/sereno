--[[--
Reads files out of an EPUB (a ZIP archive) on the device.

KOReader's libarchive reader (ffi/archiver) only knows an archive's
entries after walking through them once: `extractToMemory(name)` right
after `open()` finds nothing. KOReader's own code always iterates first,
and so does this helper. If libarchive can't open the file, the device's
`unzip` is tried, so a book is never reported unreadable for a reason
that isn't the book's.

  local zip = Archive.open(path)
  local data = zip and zip:read("META-INF/container.xml")
  zip:close()
]]

local Archive = {}
Archive.__index = Archive

local function libarchiveReader(path)
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not ok or not Archiver or not Archiver.Reader then return nil end
    local reader = Archiver.Reader:new()
    if not reader:open(path) then return nil end
    -- index every entry, as KOReader's own callers do before extracting
    if reader.iterate then
        local okit, err = pcall(function() for _entry in reader:iterate() do end end)
        if not okit then
            reader:close()
            return nil, err
        end
    end
    return reader
end

local function unzipRead(path, name)
    local p = io.popen(string.format("unzip -p %q %q 2>/dev/null", path, name), "r")
    if not p then return nil end
    local data = p:read("*a")
    p:close()
    if data and data ~= "" then return data end
end

function Archive.open(path)
    local self = setmetatable({ path = path }, Archive)
    self.reader = libarchiveReader(path)
    return self
end

--- The bytes of one file in the archive, or nil.
function Archive:read(name)
    if self.reader then
        local ok, data = pcall(self.reader.extractToMemory, self.reader, name)
        if ok and data then return data end
    end
    return unzipRead(self.path, name)
end

function Archive:close()
    if self.reader then
        pcall(self.reader.close, self.reader)
        self.reader = nil
    end
end

return Archive
