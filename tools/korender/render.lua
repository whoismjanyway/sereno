--[[
Renders Sereno's home screen with KOReader's *real* widget code: its
Blitbuffer, FreeType font rendering, TextWidget/TextBoxWidget,
IconWidget/ImageWidget and Sereno's HomeScreen widget, then writes a PGM
image per device. Unlike tools/preview.lua (an SVG approximation), this
exercises the same Lua code that runs on an e-reader, minus the C-only
parts (crengine, libarchive), which are not needed for the home screen.

Run it through tools/korender/run.sh, which prepares a KOReader runtime
folder (frontend + base ffi + fonts + a compiled lfs module).

    luajit render.lua <sereno_repo> <out_dir> [books_dir]
]]

local repo, out_dir, books_dir = arg[1], arg[2], arg[3]
assert(repo and out_dir, "usage: render.lua <sereno_repo> <out_dir> [books_dir]")
os.execute(string.format("mkdir -p %q", out_dir))

package.path = "common/?.lua;frontend/?.lua;" .. repo .. "/sereno.koplugin/?.lua;" .. package.path
local ffi = require("ffi")
-- KOReader's LuaJIT fork exposes the C library flavour; stock LuaJIT doesn't
ffi.libc = ffi.libc or "gnu"
require("ffi/loadlib")
-- utf8proc (Unicode case folding) is a C library KOReader ships; the home
-- screen only needs lower/upper-casing, so plain Lua stands in for it
package.loaded["ffi/utf8proc"] = {
    lowercase = function(s) return s:lower() end,
    uppercase = function(s) return s:upper() end,
    normalize_NFC = function(s) return s end,
    cased = function(s) return s:lower() end,
    count = function(s) local _, n = s:gsub("[^\128-\191]", "") return n end,
}
-- MuPDF is only needed for documents and images; CanvasContext sets a flag
-- on it and ImageWidget asks it to scale bitmaps, done here with a box filter
package.loaded["ffi/mupdf"] = {
    scaleBlitBuffer = function(bb, w, h)
        local BB = require("ffi/blitbuffer")
        local sw, sh = bb:getWidth(), bb:getHeight()
        local out = BB.new(w, h, BB.TYPE_BB8)
        for y = 0, h - 1 do
            local y0, y1 = math.floor(y * sh / h), math.max(math.floor(y * sh / h), math.floor((y + 1) * sh / h) - 1)
            for x = 0, w - 1 do
                local x0, x1 = math.floor(x * sw / w), math.max(math.floor(x * sw / w), math.floor((x + 1) * sw / w) - 1)
                local sum, n = 0, 0
                for yy = y0, y1, math.max(1, math.floor((y1 - y0) / 2)) do
                    for xx = x0, x1, math.max(1, math.floor((x1 - x0) / 2)) do
                        sum = sum + bb:getPixel(xx, yy):getColor8().a
                        n = n + 1
                    end
                end
                out:setPixel(x, y, BB.Color8(math.floor(sum / n + 0.5)))
            end
        end
        return out
    end,
}
-- KOReader's lfs is a C module; run.sh builds it from luafilesystem
package.loaded["libs/libkoreader-lfs"] = package.loadlib("libs/libkoreader-lfs.so", "luaopen_lfs")()

G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(out_dir .. "/settings.reader.lua")
-- the "xtext" shaper is a C++ module; KOReader falls back to plain FreeType without it
G_reader_settings:saveSetting("use_xtext", false)

local Blitbuffer = require("ffi/blitbuffer")
Blitbuffer:setUseCBB(false)

local DEVICES = {
    { id = "kindle-basic", width = 600, height = 800, dpi = 167 },
    { id = "paperwhite", width = 1236, height = 1648, dpi = 300 },
    { id = "scribe", width = 1860, height = 2480, dpi = 300 },
}
local only = os.getenv("KORENDER_DEVICE")

-- The device module would probe the hardware (or start SDL); a minimal
-- Device around KOReader's own dummy framebuffer is all the widgets need.
local function makeDevice(d)
    local fb = require("ffi/framebuffer_dummy")
    local screen = fb:new{ device = { display_dpi = d.dpi }, debug = function() end }
    screen.bb:free()
    screen.bb = Blitbuffer.new(d.width, d.height, Blitbuffer.TYPE_BB8)
    screen.bb:fill(Blitbuffer.COLOR_WHITE)
    screen.screen_size = { w = d.width, h = d.height }
    screen.dpi = d.dpi
    function screen:getRawSize() return { w = d.width, h = d.height } end
    function screen:getWidth() return d.width end
    function screen:getHeight() return d.height end
    function screen:getSize() return { w = d.width, h = d.height } end
    function screen:getDPI() return d.dpi end
    function screen:isColorEnabled() return false end
    function screen:isColorScreen() return false end
    function screen:scaleBySize(px)
        local s = math.min(d.width, d.height) / 600
        return math.ceil(px * s)
    end
    local device = setmetatable({
        screen = screen,
        model = "korender",
        input = { group = { Back = { "Back" } } },
        isTouchDevice = function() return true end,
        hasKeys = function() return false end,
        hasBattery = function() return true end,
        hasFrontlight = function() return true end,
        hasSystemFonts = function() return false end,
        isKindle = function() return false end,
        getPowerDevice = function()
            -- what KOReader's widgets ask the power device for; anything else is "no"
            return setmetatable({
                getCapacity = function() return 82 end, getBatterySymbol = function() return "" end,
                frontlightIntensity = function() return 14 end, isFrontlightOn = function() return true end,
            }, { __index = function(_, k)
                return function() if k:match("^get") then return 0 end return false end
            end })
        end,
    }, { __index = function() return function() return false end end })
    return device
end

-- Turns an image file into a greyscale Blitbuffer with ImageMagick/rsvg, in
-- place of the C decoders KOReader ships (nanosvg, turbojpeg, mupdf).
local function grayImage(path, W, H, is_svg)
    local tmp = os.tmpname()
    local raw = tmp .. ".gray"
    if is_svg then
        os.execute(string.format("rsvg-convert -b white -w %d -h %d -o %q.png %q 2>/dev/null && convert %q.png -colorspace Gray -depth 8 gray:%q",
            W, H, tmp, path, tmp, raw))
    else
        os.execute(string.format("convert %q -resize %dx%d! -colorspace Gray -depth 8 gray:%q 2>/dev/null", path, W, H, raw))
    end
    local g = io.open(raw, "rb")
    local data = g and g:read("*a")
    if g then g:close() end
    os.remove(tmp); os.remove(raw); os.remove(tmp .. ".png")
    if not data or #data ~= W * H then return nil end
    local bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            bb:setPixel(x, y, Blitbuffer.Color8(data:byte(y * W + x + 1)))
        end
    end
    return bb
end

local function writePGM(bb, path)
    local w, h = bb:getWidth(), bb:getHeight()
    local f = assert(io.open(path, "wb"))
    f:write(string.format("P5\n%d %d\n255\n", w, h))
    local row = {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            row[x + 1] = string.char(bb:getPixel(x, y):getColor8().a)
        end
        f:write(table.concat(row, "", 1, w))
    end
    f:close()
end

-- sample library: real EPUBs when given, analysed with Sereno's own engine
local Analyzer = require("sereno/metrics/analyzer")
local function extract(path, name)
    local p = io.popen(string.format("unzip -p %q %q 2>/dev/null", path, name), "r")
    local d = p:read("*a"); p:close()
    return d ~= "" and d or nil
end
local SAMPLE = {
    { file = "f-scott-fitzgerald_the-great-gatsby.epub", percent = 0.38, status = "reading" },
    { file = "jane-austen_pride-and-prejudice.epub", percent = 0.12, status = "reading" },
    { file = "mary-shelley_frankenstein.epub" },
    { file = "robert-louis-stevenson_treasure-island.epub" },
    { file = "lewis-carroll_alices-adventures-in-wonderland.epub" },
    { file = "bram-stoker_dracula.epub" },
    { file = "jane-austen_emma.epub" },
    { file = "herman-melville_moby-dick.epub" },
    { file = "jane-austen_persuasion.epub" },
}
local by_file, metrics = {}, {}
for _, b in ipairs(SAMPLE) do
    b.path = (books_dir or ".") .. "/" .. b.file
    by_file[b.path] = b
    if books_dir then metrics[b.path] = Analyzer.analyze(b.path, { extract = extract }) end
end

for _, d in ipairs(DEVICES) do
    if not only or only == d.id then
        local Device = makeDevice(d)
        -- every KOReader module that asks for the device gets this one
        package.loaded["device"] = Device
        for name in pairs(package.loaded) do
            if name:match("^ui/") or name:match("^sereno/home") or name:match("^sereno/ui") then package.loaded[name] = nil end
        end
        package.loaded["document/canvascontext"] = nil
        require("document/canvascontext"):init(Device)
        local Font = require("ui/font")
        local HomeScreen = require("sereno/home/homescreen")
        local RenderImage = require("ui/renderimage")
        -- icons are SVG files rendered by nanosvg (a C module) on devices
        RenderImage.renderSVGImageFile = function(_self, filename, width, height)
            return grayImage(filename, width or 64, height or 64, true)
        end
        local _ = require("sereno/l10n")

        -- covers: Sereno's own EPUB cover lookup, then rendered by ImageMagick into
        -- a raw greyscale buffer (KOReader would use its turbojpeg/mupdf libraries)
        local cover_cache = {}
        local function cover(path)
            if cover_cache[path] ~= nil then return cover_cache[path] or nil end
            local m = metrics[path]
            if not (m and m.cover_path) then cover_cache[path] = false return nil end
            local tmp = os.tmpname()
            local f = io.open(tmp, "wb"); f:write(extract(path, m.cover_path) or ""); f:close()
            local bb = grayImage(tmp, 400, 600, m.cover_path:match("%.svg$"))
            os.remove(tmp)
            if not bb then cover_cache[path] = false return nil end
            cover_cache[path] = bb
            return bb
        end

        local history, new = {}, {}
        for _, b in ipairs(SAMPLE) do
            if b.status then history[#history + 1] = b.path else new[#new + 1] = b.path end
        end
        local home = HomeScreen:new{
            sources = {
                history = function() return history end,
                new_books = function() return new end,
                book_info = function(path)
                    local b, m = by_file[path], metrics[path] or {}
                    return { title = m.title or b.file, authors = m.authors, percent = b.percent or 0,
                        status = b.status or "new", been_opened = b.status ~= nil }
                end,
                metrics = function(path) return metrics[path] end,
                stats = function() return { unread = 128, in_progress = 3, finished = 27 } end,
                cover = cover,
                home_dir = function() return books_dir or "." end,
                list_dir = function()
                    local files = {}
                    for _, b in ipairs(SAMPLE) do files[#files + 1] = b.path end
                    return { dirs = { { name = "Classics", path = (books_dir or ".") .. "/Classics", count = 12 },
                        { name = "Poetry", path = (books_dir or ".") .. "/Poetry", count = 4 } }, files = files }
                end,
                collections = function() return { { name = "Favorites", count = 3 }, { name = "To read", count = 9 } } end,
                collection = function() return { SAMPLE[1].path, SAMPLE[3].path } end,
                search = function() return { SAMPLE[3].path } end,
            },
            options = { translate = _, page_method = "print", wpm = 230 },
        }
        local bb = Device.screen.bb
        home:paintTo(bb, 0, 0)
        local pgm = string.format("%s/%s.pgm", out_dir, d.id)
        writePGM(bb, pgm)
        print(string.format("%-14s %dx%d @%d dpi -> %s (%d nodes, body face %dpx)", d.id, d.width, d.height, d.dpi, pgm,
            #home.nodes, home:face("body").size))
        -- the Library tab, then the quick controls pulled down over the home screen
        home.tab = "library"
        home:build()
        home:paintTo(bb, 0, 0)
        writePGM(bb, string.format("%s/%s-library.pgm", out_dir, d.id))
        home.tab = "home"
        home:build()
        home:paintTo(bb, 0, 0)
        local Painter = require("sereno/ui/painter")
        local ControlsLayout = require("sereno/controls/layout")
        local painter = Painter.new(home.theme)
        local nodes = ControlsLayout.layout(home.theme, {
            time = "9:41", battery = 82, wifi = true, night = false, has_frontlight = true, light_on = true,
            brightness = 14, brightness_max = 24, has_warmth = true, warmth = 35, warmth_max = 100,
        }, { wifi = _("Wi-Fi"), night = _("Night"), light = _("Light"), rotate = _("Rotate"), restart = _("Restart"),
            sleep = _("Sleep"), wifi_on = _("Wi-Fi on"), wifi_off = _("Wi-Fi off"), brightness = _("Brightness: %d"),
            warmth = _("Warmth: %d"), koreader_menu = _("KOReader menu"), files = _("File browser") })
        painter:paint(bb, nodes)
        painter:free()
        writePGM(bb, string.format("%s/%s-controls.pgm", out_dir, d.id))
        -- Sereno's sleep screen (portrait), with the book being read
        do
            local SleepLayout = require("sereno/sleep/layout")
            local sp = Painter.new(home.theme, cover)
            bb:fill(Blitbuffer.COLOR_WHITE)
            local g = metrics[SAMPLE[1].path] or {}
            sp:paint(bb, SleepLayout.layout(home.theme, { file = SAMPLE[1].path, title = g.title or "The Great Gatsby",
                authors = g.authors and table.concat(g.authors, ", ") or "F. Scott Fitzgerald", percent = 0.38 },
                { progress = "Page 68 of 179 · 38%", date = "Monday, 2 November", logo = repo .. "/sereno.koplugin/icons/sereno.logo.svg" }))
            sp:free()
            writePGM(bb, string.format("%s/%s-sleep.pgm", out_dir, d.id))
        end
        -- the settings: KOReader's own TouchMenu, Sereno's tab first, then KOReader's tabs
        do
            local ok, err = pcall(function()
                local TouchMenu = require("ui/widget/touchmenu")
                local CenterContainer = require("ui/widget/container/centercontainer")
                local container = CenterContainer:new{ ignore = "height", dimen = Device.screen:getSize() }
                local item = function(text) return { text = text, sub_item_table = { { text = "…" } } } end
                local tabs = {
                    { icon = "sereno.logo", item(_("Home screen")), item(_("Reader")), item(_("Sleep screen")),
                      item(_("Tiered menus")), { text = _("Refresh budget"), separator = true }, { text = _("About Sereno") } },
                    { icon = "appbar.filebrowser", item("…") }, { icon = "appbar.settings", item("…") },
                    { icon = "appbar.tools", item("…") }, { icon = "appbar.search", item("…") }, { icon = "appbar.menu", item("…") },
                }
                local tm = TouchMenu:new{ width = d.width, tab_item_table = tabs, show_parent = container, last_index = 1 }
                container[1] = tm
                home:paintTo(bb, 0, 0)
                container:paintTo(bb, 0, 0)
                writePGM(bb, string.format("%s/%s-settings.pgm", out_dir, d.id))
            end)
            if not ok then print("settings render failed: " .. tostring(err)) end
        end
        home:onCloseWidget()
        if Font.cleanup then Font:cleanup() end
    end
end

-- ---------------------------------------------------------------------------
-- Reader pages: the opening page of a book set like crengine sets it
-- (tools/korender/bookpage.lua: crengine's hyphenation patterns, justified
-- lines, first-line indents, the font's own line height), once with
-- KOReader's default layout and once with Sereno's "Paperback", plus the
-- "Text & page" panel over the page. crengine itself is a C++ engine not
-- built here, so line endings can differ a little from a device.
if os.getenv("KORENDER_READER") == "1" and books_dir then
    local Html = require("sereno/metrics/html")
    local ReaderLayout = require("sereno/reader/layout")
    package.path = repo .. "/tools/korender/?.lua;" .. package.path
    local BookPage = require("bookpage")
    local hyph = os.getenv("KORENDER_HYPH") and BookPage.loadPatterns(os.getenv("KORENDER_HYPH"))
    if not hyph then print("no hyphenation patterns (KORENDER_HYPH): lines will not be hyphenated") end
    local gatsby = books_dir .. "/f-scott-fitzgerald_the-great-gatsby.epub"
    local chapter = extract(gatsby, "epub/text/chapter-1.xhtml") or ""
    local blocks = {}
    for _, b in ipairs(Html.blocks(chapter)) do
        if b.kind == "p" or b.kind == "h" then blocks[#blocks + 1] = { kind = b.kind, text = b.text } end
        if #blocks >= 16 then break end
    end
    local total = metrics[gatsby] and metrics[gatsby].pages and metrics[gatsby].pages.print or 179

    for _, d in ipairs(DEVICES) do
        if not only or only == d.id then
            local Device = makeDevice(d)
            package.loaded["device"] = Device
            for name in pairs(package.loaded) do
                if name:match("^ui/") or name:match("^sereno/reader/panelwidget") or name:match("^sereno/ui") or name:match("^sereno/reader/panel$") then
                    package.loaded[name] = nil
                end
            end
            package.loaded["document/canvascontext"] = nil
            require("document/canvascontext"):init(Device)
            local Font = require("ui/font")
            local RenderText = require("ui/rendertext")
            require("ui/renderimage").renderSVGImageFile = function(_self, filename, width, height)
                return grayImage(filename, width or 64, height or 64, true)
            end
            local PanelWidget = require("sereno/reader/panelwidget")
            local _ = require("sereno/l10n")
            local screen = { width = d.width, height = d.height, dpi = d.dpi }
            local f = ReaderLayout.scaleFactor(screen)
            -- KOReader's status bar: DMINIBAR_CONTAINER_HEIGHT (14) and a 14 px font, both scaled
            local footer_px = math.ceil(14 * f)
            screen.footer_px = footer_px
            local sereno = ReaderLayout.compute(screen, "paperback")
            local cases = {
                { id = "koreader", align = "justify",
                  v = { font_size = 22, h_margin = 10, t_margin = 10, b_margin = 10, line_spacing = 100 } },
                { id = "sereno", align = sereno.align,
                  v = { font_size = sereno.font_size, h_margin = sereno.h_margins[1], t_margin = sereno.t_margin,
                        b_margin = sereno.b_margin, line_spacing = sereno.line_spacing } },
                { id = "bars", align = sereno.align, bars = true,
                  v = { font_size = sereno.font_size, h_margin = sereno.h_margins[1], t_margin = sereno.t_margin,
                        b_margin = sereno.b_margin, line_spacing = sereno.line_spacing } },
                { id = "panel", align = sereno.align, panel = true,
                  v = { font_size = sereno.font_size, h_margin = sereno.h_margins[1], t_margin = sereno.t_margin,
                        b_margin = sereno.b_margin, line_spacing = sereno.line_spacing } },
            }
            -- every preset, on the Paperwhite only
            if d.id == "paperwhite" then
                for _j, p in ipairs(ReaderLayout.PRESETS) do
                    local pv = ReaderLayout.compute(screen, p.id)
                    cases[#cases + 1] = { id = "preset-" .. p.id, align = pv.align,
                        v = { font_size = pv.font_size, h_margin = pv.h_margins[1], t_margin = pv.t_margin,
                              b_margin = pv.b_margin, line_spacing = pv.line_spacing } }
                end
            end
            for _i, c in ipairs(cases) do
                local ph = ReaderLayout.describe(screen, c.v)
                local bb = Blitbuffer.new(d.width, d.height, Blitbuffer.TYPE_BB8)
                bb:fill(Blitbuffer.COLOR_WHITE)
                local face = Font:getFace("NotoSerif-Regular.ttf", c.v.font_size)
                local heading_face = Font:getFace("NotoSerif-Regular.ttf", c.v.font_size * 1.6)
                local footer_face = Font:getFace("NotoSans-Regular.ttf", 14)
                local text_h = d.height - ph.top_px - ph.bottom_px - footer_px
                local stats = BookPage.render{
                    bb = bb, x = ph.side_px, y = ph.top_px, width = d.width - 2 * ph.side_px, height = text_h,
                    face = face, heading_face = heading_face, footer_face = footer_face, RenderText = RenderText,
                    color = Blitbuffer.COLOR_BLACK, grey = Blitbuffer.COLOR_GRAY_4 or Blitbuffer.COLOR_DARK_GRAY,
                    line_px = ph.line_px, font_px = ph.font_px, align = c.align, hyph = hyph,
                    blocks = blocks, chapter_opening = true,
                    footer = { left = string.format("1 / %d", total), right = "1%", y = d.height - footer_px, h = footer_px },
                }
                if c.bars then
                    local Theme = require("sereno/ui/theme")
                    local Painter = require("sereno/ui/painter")
                    local ChromeLayout = require("sereno/reader/chrome")
                    local theme = Theme.new{ width = d.width, height = d.height, dpi = d.dpi,
                        scale_by_size = function(n) return Device.screen:scaleBySize(n) end }
                    local painter = Painter.new(theme)
                    local nodes = ChromeLayout.layout(theme, {
                        title = "The Great Gatsby · F. Scott Fitzgerald", chapter = "I", page_label = "1",
                        total_label = tostring(total), percent = 0.004, ticks = { 0, 0.11, 0.2, 0.34, 0.47, 0.58, 0.7, 0.79, 0.9 },
                        can_prev = false, can_next = true,
                    }, { home = _("Home"), page_of = _("Page %s of %s") })
                    painter:paint(bb, nodes)
                    painter:free()
                end
                if c.panel then
                    local panel = PanelWidget:new{ values = sereno, translate = _ }
                    panel:paintTo(bb, 0, 0)
                    panel:onCloseWidget()
                end
                local info = io.open(string.format("%s/reader-%s-%s.txt", out_dir, d.id, c.id), "w")
                info:write(string.format("%.1f pt · %.1f mm margins · %d characters a line", ph.font_pt, ph.side_mm,
                    stats.chars_per_line))
                info:close()
                local pgm = string.format("%s/reader-%s-%s.pgm", out_dir, d.id, c.id)
                writePGM(bb, pgm)
                bb:free()
                print(string.format("%-12s %-8s %.1f pt, side %.1f mm, top %.1f mm, %d lines, ~%d chars/line, %d hyphens -> %s",
                    d.id, c.id, ph.font_pt, ph.side_mm, ph.top_mm, stats.lines, stats.chars_per_line, stats.hyphens, pgm))
            end
        end
    end
end
