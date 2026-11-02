-- Command-line page counter, handy for calibrating the print model.
-- Usage (from the repository root): luajit tools/count.lua book.epub [...]
package.path = "sereno.koplugin/?.lua;" .. package.path
local Analyzer = require("sereno/metrics/analyzer")

local function extract(path, name)
    local p = io.popen(string.format("unzip -p %q %q 2>/dev/null", path, name), "r")
    local data = p:read("*a")
    p:close()
    return data ~= "" and data or nil
end

for _, path in ipairs(arg) do
    local m, err = Analyzer.analyze(path, { extract = extract })
    if not m then
        print(path, "ERROR", err)
    else
        local r = m.readability or {}
        print(string.format("%-45s print %4d | apnx %4d | adobe %4d | chars %4d | words %6d | wpp %3d | ease %5s %s grade %s fog %s | %.2fs",
            (m.title or path):sub(1, 45), m.pages.print, m.pages.apnx or 0, m.pages.adobe or 0, m.pages.chars or 0,
            m.words or 0, (m.words or 0) / math.max(1, m.pages.print), tostring(r.ease), tostring(r.label),
            tostring(r.grade), tostring(r.fog), m.seconds or 0))
    end
end
