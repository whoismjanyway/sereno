--[[--
Manages settings/<prefix>_menu_order.lua, KOReader's official per-user
menu order override (read by MenuSorter:mergeAndSort on every menu build).

* adopt():   if the user already had their own file, move it aside once and
             use it as the base we filter, so their custom order is kept.
* apply():   write our generated file, only when its content changed.
* release(): remove our file and put the user's original back.

File-system access goes through `fs` so it can be tested without KOReader.
]]

local Serialize = require("sereno/menu/serialize")

local OrderFile = {}
OrderFile.__index = OrderFile

local function defaultFs()
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end
    return {
        read = function(path)
            local f = io.open(path, "rb")
            if not f then return nil end
            local s = f:read("*a")
            f:close()
            return s
        end,
        write = function(path, content)
            local tmp = path .. ".tmp"
            local f, err = io.open(tmp, "wb")
            if not f then return false, err end
            f:write(content)
            f:close()
            return os.rename(tmp, path)
        end,
        exists = function(path)
            local f = io.open(path, "rb")
            if f then f:close() return true end
            return false
        end,
        rename = os.rename,
        remove = os.remove,
        mkdir = function(path)
            if ok and lfs and lfs.mkdir then return lfs.mkdir(path) end
            return os.execute('mkdir -p "' .. path .. '"')
        end,
    }
end

function OrderFile.new(settings_dir, fs)
    local o = setmetatable({}, OrderFile)
    o.dir = settings_dir
    o.backup_dir = settings_dir .. "/sereno"
    o.fs = fs or defaultFs()
    return o
end

function OrderFile:livePath(prefix)
    return string.format("%s/%s_menu_order.lua", self.dir, prefix)
end

function OrderFile:backupPath(prefix)
    return string.format("%s/backup_%s_menu_order.lua", self.backup_dir, prefix)
end

local function loadLua(content, chunkname)
    if not content then return nil end
    local loader = loadstring or load
    local fn = loader(content, chunkname)
    if not fn then return nil end
    local ok, t = pcall(fn)
    if ok and type(t) == "table" then return t end
    return nil
end

--- Returns the user's own overrides (possibly empty), adopting their file once.
function OrderFile:adopt(prefix)
    local live, backup = self:livePath(prefix), self:backupPath(prefix)
    local content = self.fs.read(live)
    if content and not Serialize.isOurs(content) and not self.fs.exists(backup) then
        self.fs.mkdir(self.backup_dir)
        local ok = self.fs.rename(live, backup)
        if not ok then
            -- Can't move it: leave the user's file alone and don't take over.
            return nil, "could not back up " .. live
        end
    elseif content and not Serialize.isOurs(content) then
        -- A backup already exists and the user wrote a new file meanwhile:
        -- respect the newest one as their base.
        self.fs.mkdir(self.backup_dir)
        self.fs.remove(backup)
        if not self.fs.rename(live, backup) then
            return nil, "could not back up " .. live
        end
    end
    return loadLua(self.fs.read(backup), "=" .. backup) or {}
end

--- Writes the order. Returns true when the file changed.
function OrderFile:apply(prefix, order)
    local live = self:livePath(prefix)
    local content = Serialize.order(order)
    if self.fs.read(live) == content then return false end
    local ok, err = self.fs.write(live, content)
    if not ok then return false, err end
    return true
end

--- Undo everything for this prefix.
function OrderFile:release(prefix)
    local live, backup = self:livePath(prefix), self:backupPath(prefix)
    local content = self.fs.read(live)
    if content and Serialize.isOurs(content) then
        self.fs.remove(live)
    end
    if self.fs.exists(backup) and not self.fs.exists(live) then
        self.fs.rename(backup, live)
    end
end

--- Loads a pristine copy of KOReader's default order for this prefix.
-- We dofile the module source rather than use require(), because
-- MenuSorter mutates the cached required table with user overrides.
function OrderFile.loadDefaults(prefix)
    local modname = "ui/elements/" .. prefix .. "_menu_order"
    local path = package.searchpath and package.searchpath(modname, package.path)
    if path then
        local ok, t = pcall(dofile, path)
        if ok and type(t) == "table" then return t end
    end
    -- Fallback: the cached table. May contain overrides from a previous
    -- session, which is still a usable base.
    local ok, t = pcall(require, modname)
    if ok and type(t) == "table" then return t end
    return nil
end

return OrderFile
