--[[--
Computes a book's metrics from its file, without rendering it:
page counts (four estimators), words, characters, images, readability and
the print page where each chapter starts.

Pure Lua apart from the injected `extract(path, entry_name)` function used
for deflated ZIP entries (KOReader's libarchive on a device).
]]

local Epub = require("sereno/metrics/epub")
local Html = require("sereno/metrics/html")
local Pages = require("sereno/metrics/pages")
local Readability = require("sereno/metrics/readability")
local Text = require("sereno/metrics/text")
local Zip = require("sereno/metrics/zip")

local Analyzer = {}

Analyzer.VERSION = 1 -- bump when results change, so caches are refreshed
Analyzer.READABILITY_WORDS = 60000

local IMAGE_EXT = { jpg = true, jpeg = true, png = true, gif = true, webp = true, bmp = true, avif = true, jxl = true }

local function extension(path)
    return (path:match("%.([%w]+)$") or ""):lower()
end

local function clock()
    return os.clock()
end

--- Comic archives: one page per image, like Count Pages.
function Analyzer.cbz(path)
    local list, _by_name, err = Zip.index(path)
    if not list then return nil, err end
    local pages = 0
    for _i, e in ipairs(list) do
        if not e.is_dir and not e.name:find("__MACOSX", 1, true) and IMAGE_EXT[extension(e.name)] then
            pages = pages + 1
        end
    end
    return {
        version = Analyzer.VERSION,
        format = "cbz",
        pages = { print = pages, images = pages },
        page_method = "print",
    }
end

--[[--
@string path EPUB file
@tparam table deps { extract = function(path, name) -> string|nil, yield = function(fraction) (optional) }
@tparam table opts { chars_per_page = 1500, reference = Pages.REFERENCE }
@treturn table|nil metrics
@treturn string|nil error
]]
function Analyzer.epub(path, deps, opts)
    deps, opts = deps or {}, opts or {}
    local started = clock()
    local list, by_name, err = Zip.index(path)
    if not list then return nil, err end

    local function read(name)
        local entry = by_name[name]
        if not entry then return nil end
        local data = Zip.readStored(path, entry)
        if data then return data end
        if deps.extract then return deps.extract(path, name) end
        return nil
    end

    local book, berr = Epub.open(read, by_name)
    if not book then return nil, berr end
    local lang = Readability.language(book.language)

    local raw_parts = {}
    local paragraphs = {}
    local total_chars, total_words, images = 0, 0, 0
    local print_pages = 0
    local chapter_starts = {} -- print page on which each linear spine item starts
    local linear = {}
    for _i, item in ipairs(book.spine) do
        if item.linear and not item.is_nav then linear[#linear + 1] = item end
    end

    for i, item in ipairs(linear) do
        local raw = read(item.path)
        if raw then
            raw_parts[#raw_parts + 1] = raw
            local blocks, stats = Html.blocks(raw)
            local pages, chars = Pages.printModelDocument(blocks, opts.reference)
            if pages > 0 then chapter_starts[#chapter_starts + 1] = print_pages + 1 end
            print_pages = print_pages + pages
            total_chars = total_chars + chars
            images = images + stats.images
            for _j, b in ipairs(blocks) do
                if b.text ~= "" then
                    total_words = total_words + Text.countWords(b.text)
                    paragraphs[#paragraphs + 1] = b.text
                end
            end
        end
        if deps.yield then deps.yield(i / #linear) end
    end

    -- readability: whole book up to READABILITY_WORDS, evenly sampled beyond
    local sample
    local stride = math.max(1, math.ceil(total_words / Analyzer.READABILITY_WORDS))
    if stride == 1 then
        sample = table.concat(paragraphs, "\n")
    else
        local picked = {}
        for i = 1, #paragraphs, stride do picked[#picked + 1] = paragraphs[i] end
        sample = table.concat(picked, "\n")
    end
    local rstats = Readability.analyze(sample, lang, Analyzer.READABILITY_WORDS * 1.2)

    local raw_html = table.concat(raw_parts, " ")
    return {
        version = Analyzer.VERSION,
        format = "epub",
        title = book.title,
        authors = book.authors,
        language = lang,
        isbn = book.isbn,
        pages = {
            print = print_pages,
            apnx = Pages.apnx(raw_html, total_chars),
            adobe = Pages.adobe(linear),
            chars = Pages.chars(total_chars, opts.chars_per_page),
        },
        page_method = "print",
        chars_per_page = opts.chars_per_page or 1500,
        words = total_words,
        chars = total_chars,
        images = images,
        chapter_starts = chapter_starts,
        readability = Readability.scores(rstats, lang),
        seconds = math.floor((clock() - started) * 100 + 0.5) / 100,
    }
end

--- Dispatches on the file extension.
function Analyzer.analyze(path, deps, opts)
    local ext = extension(path)
    if ext == "epub" or ext == "kepub" then
        return Analyzer.epub(path, deps, opts)
    elseif ext == "cbz" then
        return Analyzer.cbz(path)
    end
    if deps and deps.page_count then
        -- PDF, DjVu...: fixed layout, the document knows its pages
        local n = deps.page_count(path)
        if n then
            return { version = Analyzer.VERSION, format = ext, pages = { print = n }, page_method = "print" }
        end
    end
    return nil, "unsupported format: " .. ext
end

--- Minutes to read `words` at `wpm` words per minute.
function Analyzer.readingMinutes(words, wpm)
    if not words or words <= 0 then return 0 end
    return math.ceil(words / (wpm or 230))
end

return Analyzer
