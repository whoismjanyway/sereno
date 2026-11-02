-- Minimal test harness shared by every spec file. No dependencies, runs on
-- LuaJIT (KOReader's runtime) and on Lua 5.1-5.4.

local H = { passed = 0, failed = 0, current = "" }

package.path = "sereno.koplugin/?.lua;spec/?.lua;" .. package.path

function H.describe(name)
    H.current = name
    print("\n" .. name)
end

function H.it(name, fn)
    local ok, err = pcall(fn)
    if ok then
        H.passed = H.passed + 1
        print("  ok    " .. name)
    else
        H.failed = H.failed + 1
        print("  FAIL  " .. name .. "\n        " .. tostring(err))
    end
end

function H.eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", tostring(expected), tostring(actual)), 2)
    end
end

function H.near(actual, expected, tolerance, msg)
    if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
        error(string.format("%sexpected %s ± %s, got %s", msg and (msg .. ": ") or "", tostring(expected),
            tostring(tolerance), tostring(actual)), 2)
    end
end

function H.truthy(v, msg)
    if not v then error(msg or "expected a truthy value", 2) end
end

function H.list(t) return table.concat(t, ",") end

function H.contains(t, v)
    for _i, x in ipairs(t) do if x == v then return true end end
    return false
end

--- Extracts a ZIP entry with the `unzip` command (tests only; KOReader uses libarchive).
function H.unzip(path, name)
    local p = io.popen(string.format("unzip -p %q %q 2>/dev/null", path, name), "r")
    local data = p:read("*a")
    p:close()
    return data ~= "" and data or nil
end

--- In-memory file system for the cache and order-file modules.
function H.memfs(files, attrs)
    files = files or {}
    attrs = attrs or {}
    return files, {
        read = function(p) return files[p] end,
        write = function(p, c) files[p] = c return true end,
        exists = function(p) return files[p] ~= nil end,
        rename = function(a, b)
            if not files[a] then return false end
            files[b] = files[a]; files[a] = nil
            return true
        end,
        remove = function(p) files[p] = nil return true end,
        mkdir = function() return true end,
        attributes = function(p) return attrs[p] end,
    }
end

function H.finish()
    print(string.format("\n%d passed, %d failed", H.passed, H.failed))
    os.exit(H.failed == 0 and 0 or 1)
end

return H
