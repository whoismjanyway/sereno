-- Renders the home screen layout to SVG for several devices and states,
-- so typography and spacing can be reviewed without a device.
--
-- Usage (from the repository root):
--   luajit tools/preview.lua [out_dir] [books_dir]
--
-- books_dir: a folder of EPUBs (e.g. Standard Ebooks builds). Each sample
--   book found there gets its real metrics and its real cover, extracted
--   with Sereno's own EPUB reader, as on a device without CoverBrowser.
-- Environment:
--   KOREADER_DIR           KOReader checkout, for the real tab bar icons
--   SERENO_PREVIEW_COLOR=1 keep covers in colour (Kindle Colorsoft, Kobo
--                          colour); by default they are greyscale like e-ink
-- Needs `unzip`, plus `rsvg-convert` and ImageMagick `convert` for covers.
-- Convert the result with: rsvg-convert -o out.png out.svg

package.path = "sereno.koplugin/?.lua;" .. package.path
local Theme = require("sereno/ui/theme")
local Context = require("sereno/home/context")
local Layout = require("sereno/home/layout")
local Presenter = require("sereno/home/presenter")

local out_dir = arg[1] or "previews"
local books_dir = arg[2]
local ko_dir = os.getenv("KOREADER_DIR")
local color = os.getenv("SERENO_PREVIEW_COLOR") == "1"
os.execute('mkdir -p "' .. out_dir .. '/covers"')

local DEVICES = {
    { id = "kindle-basic", name = "Kindle (2019) 6\" 167 dpi", width = 600, height = 800, dpi = 167 },
    { id = "paperwhite", name = "Kindle Paperwhite 5, 6.8\" 300 dpi", width = 1236, height = 1648, dpi = 300 },
    { id = "scribe", name = "Kindle Scribe, 10.2\" 300 dpi", width = 1860, height = 2480, dpi = 300 },
    { id = "paperwhite-landscape", name = "Paperwhite 5, landscape", width = 1648, height = 1236, dpi = 300 },
}

-- sample library: Standard Ebooks titles (public domain, CC0 cover designs)
local SAMPLE = {
    gatsby = { title = "The Great Gatsby", authors = { "F. Scott Fitzgerald" }, percent = 0.38, status = "reading",
        epub = "f-scott-fitzgerald_the-great-gatsby.epub", metrics = { words = 49153, pages = { print = 179 }, readability = { label = "fairly_easy" } } },
    pride = { title = "Pride and Prejudice", authors = { "Jane Austen" }, percent = 0.12, status = "reading",
        epub = "jane-austen_pride-and-prejudice.epub", metrics = { words = 122692, pages = { print = 434 } } },
    frankenstein = { title = "Frankenstein; or, The Modern Prometheus", authors = { "Mary Shelley" },
        epub = "mary-shelley_frankenstein.epub", metrics = { words = 78619, pages = { print = 268 } } },
    treasure = { title = "Treasure Island", authors = { "Robert Louis Stevenson" },
        epub = "robert-louis-stevenson_treasure-island.epub", metrics = { words = 69109, pages = { print = 247 } } },
    alice = { title = "Alice’s Adventures in Wonderland", authors = { "Lewis Carroll" },
        epub = "lewis-carroll_alices-adventures-in-wonderland.epub", metrics = { words = 28116, pages = { print = 125 } } },
    dracula = { title = "Dracula", authors = { "Bram Stoker" }, epub = "bram-stoker_dracula.epub" },
    emma = { title = "Emma", authors = { "Jane Austen" }, epub = "jane-austen_emma.epub" },
    moby = { title = "Moby-Dick", authors = { "Herman Melville" }, epub = "herman-melville_moby-dick.epub" },
    persuasion = { title = "Persuasion", authors = { "Jane Austen" }, epub = "jane-austen_persuasion.epub" },
    middlemarch = { title = "Middlemarch", authors = { "George Eliot" }, epub = "george-eliot_middlemarch.epub" },
}

local function shell(cmd)
    local p = io.popen(cmd .. " 2>/dev/null", "r")
    local out = p:read("*a")
    p:close()
    return out
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

local function extract(path, name)
    local d = shell(string.format("unzip -p %q %q", path, name))
    return d ~= "" and d or nil
end

local function base64(path)
    return (shell(string.format("base64 -w0 %q", path)))
end

-- covers: extracted from the EPUB with Sereno's own analyser (cover_path)
local cover_png = {}
if books_dir then
    local Analyzer = require("sereno/metrics/analyzer")
    for id, b in pairs(SAMPLE) do
        local path = books_dir .. "/" .. b.epub
        if exists(path) then
            local m = Analyzer.analyze(path, { extract = extract })
            if m then
                b.metrics = m
                if m.cover_path then
                    local raw = string.format("%s/covers/%s.raw", out_dir, id)
                    local f = io.open(raw, "wb")
                    f:write(extract(path, m.cover_path) or "")
                    f:close()
                    local png = string.format("%s/covers/%s.png", out_dir, id)
                    local mono = color and "" or "-colorspace Gray"
                    if m.cover_path:match("%.svg$") then
                        shell(string.format("rsvg-convert -w 400 -o %q %q && convert %q %s %q", png, raw, png, mono, png))
                    else
                        shell(string.format("convert %q -resize 400x %s %q", raw, mono, png))
                    end
                    os.remove(raw)
                    if exists(png) then cover_png[id] = base64(png) end
                end
            end
        end
    end
end

local icon_svg = {}
local function iconData(name)
    if icon_svg[name] == nil then
        icon_svg[name] = false
        local path = ko_dir and (ko_dir .. "/resources/icons/mdlight/" .. name .. ".svg")
        if path and exists(path) then icon_svg[name] = base64(path) end
    end
    return icon_svg[name] or nil
end

local STATES = {
    reading = { history = { "gatsby", "pride" }, new = { "frankenstein", "treasure", "alice", "dracula", "emma", "moby", "persuasion", "middlemarch" },
        stats = { unread = 128, in_progress = 3, finished = 27 } },
    finished = { history = { "gatsby", "pride" }, new = { "frankenstein", "treasure", "alice", "dracula", "emma", "moby", "persuasion" }, finish = "gatsby",
        stats = { unread = 128, in_progress = 2, finished = 28 } },
    start = { history = {}, new = { "frankenstein", "treasure", "alice", "pride", "dracula", "emma", "moby" },
        stats = { unread = 131, in_progress = 0, finished = 0 } },
    empty = { history = {}, new = {}, stats = { unread = 0, in_progress = 0, finished = 0 } },
}

-- SVG output ----------------------------------------------------------------
local INK = { text = "#000000", secondary = "#444444", hairline = "#888888", track = "#cccccc", paper = "#ffffff" }

local function esc(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function family(font)
    return font:find("Serif") and "Noto Serif, serif" or "Noto Sans, sans-serif"
end

local function weight(font) return font:find("Bold") and "bold" or "normal" end

local function typesetCover(t, n, out)
    local b = n.book
    out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="#fff" stroke="#000" stroke-width="%d"/>',
        n.x, n.y, n.w, n.h, t.hairline)
    local inset = math.floor(n.w * 0.1)
    local title_style = { size = math.max(8, math.floor(n.w / 7)), font = "NotoSerif" }
    local lines = Layout.wrap(Presenter.shortTitle(b.title or ""), title_style, n.w - 2 * inset, 4)
    local y = n.y + math.floor(n.h * 0.22)
    for _, l in ipairs(lines) do
        y = y + math.floor(title_style.size * 1.2)
        out[#out + 1] = string.format('<text x="%d" y="%d" font-family="Noto Serif, serif" font-size="%d" text-anchor="middle">%s</text>',
            n.x + n.w / 2, y, title_style.size, esc(l))
    end
end

local function render(t, nodes, path, title)
    local out = {
        string.format('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="%d" height="%d" viewBox="0 0 %d %d">', t.width, t.height, t.width, t.height),
        string.format('<rect width="%d" height="%d" fill="#fff"/>', t.width, t.height),
        "<!-- " .. esc(title) .. " -->",
    }
    for _, n in ipairs(nodes) do
        if n.kind == "text" then
            local style = t.type[n.style]
            local lines = Layout.wrap(n.text or "", style, n.w, n.max_lines or 1)
            local anchor, x = "start", n.x
            if n.align == "center" then anchor, x = "middle", n.x + n.w / 2
            elseif n.align == "right" then anchor, x = "end", n.x + n.w end
            local spacing = (n.style == "micro" and (n.text or ""):upper() == n.text) and string.format(' letter-spacing="%0.1f"', style.size * 0.1) or ""
            for i, l in ipairs(lines) do
                local y = n.y + (i - 1) * style.line + math.floor(style.line * 0.5 + style.size * 0.36)
                out[#out + 1] = string.format('<text x="%d" y="%d" font-family="%s" font-weight="%s" font-size="%d" fill="%s" text-anchor="%s"%s>%s</text>',
                    x, y, family(style.font), weight(style.font), style.size, INK[n.color] or INK.text, anchor, spacing, esc(l))
            end
        elseif n.kind == "box" then
            out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="%s" stroke="%s" stroke-width="%d"/>',
                n.x, n.y, n.w, n.h, n.radius or 0, n.fill and INK[n.fill] or "none", n.border and INK[n.border] or "none", n.border and (n.bw or 1) or 0)
        elseif n.kind == "cover" then
            local id
            for k, b in pairs(SAMPLE) do if b == n.book or b.title == (n.book and n.book.title) then id = k end end
            if id and cover_png[id] then
                out[#out + 1] = string.format('<image x="%d" y="%d" width="%d" height="%d" preserveAspectRatio="xMidYMax slice" xlink:href="data:image/png;base64,%s"/>',
                    n.x, n.y, n.w, n.h, cover_png[id])
                out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="#000" stroke-width="%d"/>', n.x, n.y, n.w, n.h, t.hairline)
            else
                typesetCover(t, n, out)
            end
        elseif n.kind == "icon" then
            local data = iconData(n.name)
            if data then
                out[#out + 1] = string.format('<image x="%d" y="%d" width="%d" height="%d" opacity="%s" xlink:href="data:image/svg+xml;base64,%s"/>',
                    n.x, n.y, n.w, n.h, n.color == "text" and "1" or "0.75", data)
            else
                out[#out + 1] = string.format('<circle cx="%d" cy="%d" r="%d" fill="none" stroke="%s" stroke-width="%d"/>',
                    n.x + n.w / 2, n.y + n.h / 2, n.w / 2.5, INK[n.color] or INK.text, t.rule)
            end
        elseif n.kind == "rule" then
            out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>', n.x, n.y, n.w, n.h, INK[n.color] or INK.text)
        elseif n.kind == "bar" then
            local track = n.inset and "#ffffff" or INK.track
            out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="%s" stroke="%s" stroke-width="%d"/>',
                n.x, n.y, n.w, n.h, n.h / 2, track, n.inset and "#000" or "none", n.inset and 1 or 0)
            out[#out + 1] = string.format('<rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="#000"/>', n.x, n.y, math.floor(n.w * n.fraction), n.h, n.h / 2)
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
            stats = function() return spec.stats end,
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
