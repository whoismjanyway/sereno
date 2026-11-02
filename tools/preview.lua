-- Renders the home screen layout to SVG for several devices and states,
-- so typography and spacing can be reviewed without a device.
--
-- Usage (from the repository root):
--   luajit tools/preview.lua [out_dir] [books_dir]
-- With a folder of EPUBs, real metrics are computed for the sample books.
-- Convert with: rsvg-convert -o out.png out.svg

package.path = "sereno.koplugin/?.lua;" .. package.path
local Theme = require("sereno/ui/theme")
local Context = require("sereno/home/context")
local Layout = require("sereno/home/layout")
local Presenter = require("sereno/home/presenter")

local out_dir = arg[1] or "previews"
local books_dir = arg[2]
os.execute('mkdir -p "' .. out_dir .. '"')

local DEVICES = {
    { id = "kindle-basic", name = "Kindle (2019) 6\" 167 dpi", width = 600, height = 800, dpi = 167 },
    { id = "paperwhite", name = "Kindle Paperwhite 5, 6.8\" 300 dpi", width = 1236, height = 1648, dpi = 300 },
    { id = "scribe", name = "Kindle Scribe, 10.2\" 300 dpi", width = 1860, height = 2480, dpi = 300 },
    { id = "paperwhite-landscape", name = "Paperwhite 5, landscape", width = 1648, height = 1236, dpi = 300 },
}

-- sample library ------------------------------------------------------------
local SAMPLE = {
    ["gatsby"] = { title = "The Great Gatsby", authors = { "F. Scott Fitzgerald" }, percent = 0.38, status = "reading",
        epub = "f-scott-fitzgerald_the-great-gatsby.epub", metrics = { words = 49153, pages = { print = 179 }, readability = { label = "fairly_easy" } } },
    ["pride"] = { title = "Pride and Prejudice", authors = { "Jane Austen" }, percent = 0.12, status = "reading",
        epub = "jane-austen_pride-and-prejudice.epub", metrics = { words = 122692, pages = { print = 434 } } },
    ["frankenstein"] = { title = "Frankenstein; or, The Modern Prometheus", authors = { "Mary Shelley" },
        epub = "mary-shelley_frankenstein.epub", metrics = { words = 78619, pages = { print = 268 } } },
    ["treasure"] = { title = "Treasure Island", authors = { "Robert Louis Stevenson" },
        epub = "robert-louis-stevenson_treasure-island.epub", metrics = { words = 69109, pages = { print = 247 } } },
    ["alice"] = { title = "Alice’s Adventures in Wonderland", authors = { "Lewis Carroll" },
        epub = "lewis-carroll_alices-adventures-in-wonderland.epub", metrics = { words = 28116, pages = { print = 125 } } },
}

for i, t in ipairs({ "Middlemarch", "Moby-Dick", "Dracula", "Emma", "Persuasion" }) do
    SAMPLE["extra" .. i] = { title = t, authors = { "Sample Author" }, metrics = { words = 90000, pages = { print = 300 + i * 20 } } }
end

if books_dir then
    local Analyzer = require("sereno/metrics/analyzer")
    local function extract(path, name)
        local p = io.popen(string.format("unzip -p %q %q 2>/dev/null", path, name), "r")
        local d = p:read("*a"); p:close()
        return d ~= "" and d or nil
    end
    for _, b in pairs(SAMPLE) do
        local m = b.epub and Analyzer.analyze(books_dir .. "/" .. b.epub, { extract = extract })
        if m then b.metrics = m end
    end
end

local STATES = {
    reading = { history = { "gatsby", "pride" }, new = { "frankenstein", "treasure", "alice", "extra1", "extra2", "extra3", "extra4", "extra5" } },
    finished = { history = { "gatsby", "pride" }, new = { "frankenstein", "treasure", "alice" }, finish = "gatsby" },
    start = { history = {}, new = { "frankenstein", "treasure", "alice", "pride" } },
    empty = { history = {}, new = {} },
}

-- SVG output ----------------------------------------------------------------
local INK = { text = "#000000", secondary = "#444444", hairline = "#888888", track = "#cccccc" }

local function esc(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function family(font)
    return font:find("Serif") and "Noto Serif, serif" or "Noto Sans, sans-serif"
end

local function weight(font) return font:find("Bold") and "bold" or "normal" end

-- the same wrapping the layout uses to size its boxes
local function wrap(text, style, width, max_lines)
    return Layout.wrap(text, style, width, max_lines)
end

local function coverSvg(t, n, out)
    local b = n.book
    out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="#fff" stroke="#000" stroke-width="%d"/>',
        n.x, n.y, n.w, n.h, t.hairline)
    -- typeset cover: title in serif, author in small sans, like a plain hardback
    local inset = math.floor(n.w * 0.1)
    local title_style = { size = math.max(8, math.floor(n.w / 7)), font = "NotoSerif" }
    local lines = wrap(Presenter.shortTitle(b.title or ""), title_style, n.w - 2 * inset, 4)
    local y = n.y + math.floor(n.h * 0.22)
    for _, l in ipairs(lines) do
        y = y + math.floor(title_style.size * 1.2)
        out[#out + 1] = string.format('<text x="%d" y="%d" font-family="Noto Serif, serif" font-size="%d" text-anchor="middle">%s</text>',
            n.x + n.w / 2, y, title_style.size, esc(l))
    end
    local rule_y = y + math.floor(title_style.size * 0.8)
    out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="#000"/>', n.x + n.w / 2 - n.w / 10, rule_y, n.w / 5, t.hairline)
    local author = type(b.authors) == "table" and b.authors[1] or b.authors
    if author then
        local size = math.max(6, math.floor(n.w / 13))
        out[#out + 1] = string.format('<text x="%d" y="%d" font-family="Noto Sans, sans-serif" font-size="%d" text-anchor="middle" letter-spacing="%0.1f">%s</text>',
            n.x + n.w / 2, n.y + n.h - math.floor(n.h * 0.12), size, size * 0.08, esc(author:upper()))
    end
end

local function render(t, nodes, path, title)
    local out = {
        string.format('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">', t.width, t.height, t.width, t.height),
        string.format('<rect width="%d" height="%d" fill="#fff"/>', t.width, t.height),
        "<!-- " .. esc(title) .. " -->",
    }
    for _, n in ipairs(nodes) do
        if n.kind == "text" then
            local style = t.type[n.style]
            local lines = wrap(n.text or "", style, n.w, n.max_lines or 1)
            local anchor, x = "start", n.x
            if n.align == "center" then anchor, x = "middle", n.x + n.w / 2
            elseif n.align == "right" then anchor, x = "end", n.x + n.w end
            local spacing = n.id == "label" and string.format(' letter-spacing="%0.1f"', style.size * 0.12) or ""
            for i, l in ipairs(lines) do
                -- baseline at ~ 78% of the line box
                local y = n.y + (i - 1) * style.line + math.floor(style.line * 0.5 + style.size * 0.36)
                out[#out + 1] = string.format('<text x="%d" y="%d" font-family="%s" font-weight="%s" font-size="%d" fill="%s" text-anchor="%s"%s>%s</text>',
                    x, y, family(style.font), weight(style.font), style.size, INK[n.color] or INK.text, anchor, spacing, esc(l))
            end
        elseif n.kind == "cover" then
            coverSvg(t, n, out)
        elseif n.kind == "rule" then
            out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>', n.x, n.y, n.w, n.h, INK[n.color] or INK.text)
        elseif n.kind == "bar" then
            out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>', n.x, n.y + n.h / 2 - t.hairline / 2, n.w, t.hairline, INK.hairline)
            out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="#000"/>', n.x, n.y, math.floor(n.w * n.fraction), n.h)
        end
    end
    out[#out + 1] = "</svg>"
    local f = assert(io.open(path, "w"))
    f:write(table.concat(out, "\n"))
    f:close()
end

-- run -----------------------------------------------------------------------
local now = { year = 2026, month = 11, day = 2, hour = 19, min = 48, wday = 2 }
local report = {}
for _, dev in ipairs(DEVICES) do
    local t = Theme.new({ width = dev.width, height = dev.height, dpi = dev.dpi })
    for state, spec in pairs(STATES) do
        local sources = {
            history = function() return spec.history end,
            book_info = function(id)
                local b = SAMPLE[id]
                if not b then return nil end
                local info = { title = b.title, authors = b.authors, percent = b.percent or 0, status = b.status or "new",
                    been_opened = b.percent ~= nil }
                if spec.finish == id then info.percent, info.status = 1, "complete" end
                return info
            end,
            new_books = function() return spec.new end,
            metrics = function(id) return SAMPLE[id] and SAMPLE[id].metrics end,
        }
        local model = Context.build(sources, { now = now, shelf_size = 10 })
        local copy = Presenter.present(model, function(s) return s end, { time = "19:48", battery = 82 })
        local nodes = Layout.home(t, model, copy)
        local problems = Layout.check(t, nodes)
        local file = string.format("%s/%s-%s.svg", out_dir, dev.id, state)
        render(t, nodes, file, dev.name .. " – " .. state)
        report[#report + 1] = string.format("%-24s %-9s body %2dpx (%.1fpt) margin %3dpx (%.1fmm) %s", dev.id, state,
            t.type.body.size, t.body_pt, t.margin, t.margin / t.dpi * 25.4,
            #problems == 0 and "ok" or ("PROBLEMS: " .. table.concat(problems, "; ")))
    end
end
table.sort(report)
print(table.concat(report, "\n"))
