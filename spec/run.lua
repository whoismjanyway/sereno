-- Runs every spec. From the repository root:
--   luajit spec/run.lua
-- Optional environment:
--   KOREADER_DIR=path/to/koreader   also test the tier engine on KOReader's real menus
--   SERENO_BOOKS=path/to/epubs       also check page counts of real books
package.path = "spec/?.lua;" .. package.path
local H = require("helper")

for _i, spec in ipairs({ "menu_spec", "refresh_spec", "metrics_spec", "theme_spec", "home_spec", "smoke_spec" }) do
    local path = "spec/" .. spec .. ".lua"
    local f = io.open(path, "rb")
    if f then
        f:close()
        local ok, err = pcall(dofile, path)
        if not ok then
            H.failed = H.failed + 1
            print("\nERROR loading " .. path .. ": " .. tostring(err))
        end
    end
end

H.finish()
