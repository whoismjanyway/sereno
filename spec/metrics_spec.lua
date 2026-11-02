-- Book metrics: ZIP, EPUB, HTML, page estimators, readability, cache, Open Library.
local H = require("helper")
local test, eq, near, truthy = H.it, H.eq, H.near, H.truthy
local Zip = require("sereno/metrics/zip")
local Epub = require("sereno/metrics/epub")
local Html = require("sereno/metrics/html")
local Text = require("sereno/metrics/text")
local Pages = require("sereno/metrics/pages")
local Readability = require("sereno/metrics/readability")
local Analyzer = require("sereno/metrics/analyzer")
local Cache = require("sereno/metrics/cache")
local OpenLibrary = require("sereno/metrics/openlibrary")

local EPUB = "spec/fixtures/sample.epub"
local CBZ = "spec/fixtures/sample.cbz"

H.describe("zip index")

test("lists entries with compressed and real sizes", function()
    local list, by_name = Zip.index(EPUB)
    truthy(list, "index")
    eq(list[1].name, "mimetype")
    eq(by_name["mimetype"].method, 0)
    local ch1 = by_name["OEBPS/Text/capítulo1.xhtml"]
    truthy(ch1, "UTF-8 entry name")
    eq(ch1.method, 8, "deflated")
    truthy(ch1.compressed_size < ch1.size, "compressed is smaller")
end)

test("reads stored entries without an extractor", function()
    local _list, by_name = Zip.index(EPUB)
    eq(Zip.readStored(EPUB, by_name["mimetype"]), "application/epub+zip")
    eq(Zip.readStored(EPUB, by_name["OEBPS/content.opf"]), nil, "deflated needs an extractor")
end)

test("rejects files that are not zips", function()
    local list, _, err = Zip.index("spec/helper.lua")
    eq(list, nil)
    truthy(err)
end)

H.describe("text helpers")

test("counts code points, columns and words", function()
    eq(Text.length("año"), 3)
    eq(Text.columns("日本語"), 6)
    eq(Text.countWords("Don't stop—believing… “really”"), 4)
    eq(Text.countWords("¿Qué tal? ¡Bien, gracias!"), 4)
    eq(Text.countWords("日本語の本"), 5, "every ideograph is a word")
    eq(Text.char(0xF1), "ñ")
end)

H.describe("html blocks")

test("paragraphs, headings, images, breaks; skips head, script, comments", function()
    local blocks, stats = Html.blocks([[<html><head><title>T</title><style>p{}</style></head><body>
      <h1>Title &amp; more</h1><p>One <em>two</em>&#160;three</p><!-- <p>no</p> -->
      <script>x = "<p>no</p>"</script><img src="a.png"/><hr/><p>a<br/>b</p></body></html>]])
    eq(#blocks, 6)
    eq(blocks[1].kind, "h"); eq(blocks[1].text, "Title & more"); eq(blocks[1].level, 1)
    eq(blocks[2].text, "One two three")
    eq(blocks[3].kind, "img"); eq(blocks[4].kind, "hr")
    eq(blocks[5].text, "a"); eq(blocks[6].text, "b"); eq(blocks[6].soft, true)
    eq(stats.images, 1)
end)

test("decodes named and numeric entities", function()
    eq(Html.decodeEntities("&ntilde;&#241;&#xF1;&unknown;"), "ñññ&unknown;")
end)

H.describe("epub")

test("reads metadata and spine through the extractor", function()
    local _list, by_name = Zip.index(EPUB)
    local book = Epub.open(function(name)
        local e = by_name[name]
        return e and (Zip.readStored(EPUB, e) or H.unzip(EPUB, name))
    end, by_name)
    eq(book.title, "Cien años de prueba: una novela")
    eq(#book.authors, 1, "translator is not an author")
    eq(book.authors[1], "Ana Ejemplo")
    eq(book.language, "es-mx")
    eq(book.isbn, "9788437604947")
    eq(#book.spine, 5)
    eq(book.spine[1].is_nav, true)
    eq(book.spine[3].path, "OEBPS/Text/capítulo1.xhtml", "percent-decoded href")
    eq(book.spine[5].linear, false)
    truthy(book.spine[3].compressed_size > 0)
end)

test("resolves relative paths and extracts ISBNs", function()
    eq(Epub.resolve("OEBPS/", "../Images/a%20b.jpg#x"), "Images/a b.jpg")
    eq(Epub.isbn("urn:isbn:0-306-40615-2"), "0306406152")
    eq(Epub.isbn("urn:uuid:1234"), nil)
end)

H.describe("page estimators")

test("greedy wrapping", function()
    eq(Pages.wrapLines("aaaa bbbb cccc", 9, 0), 2)
    eq(Pages.wrapLines("aaaa bbbb", 9, 0), 1)
    eq(Pages.wrapLines(string.rep("x", 25), 10, 0), 3, "long words are hard-broken")
    eq(Pages.wrapLines("aaaa bbbb", 9, 3), 2, "indent pushes a word down")
    eq(Pages.wrapLines("", 10, 0), 0)
    eq(Pages.wrapLines("日本語日本語", 4, 0), 3, "CJK fills by columns")
end)

test("print model: chapters start pages, headings and images take room", function()
    local ref = { columns = 10, lines = 10, indent = 0, heading_columns = 10, heading_lines = 1,
        heading_space = 0, chapter_sink = 0, image_lines = 5, break_lines = 1 }
    eq(Pages.printModelDocument({}, ref), 0, "empty document")
    eq(Pages.printModelDocument({ { kind = "img", text = "" } }, ref), 1)
    local blocks = {}
    for i = 1, 11 do blocks[i] = { kind = "p", text = "one line" } end
    eq(Pages.printModelDocument(blocks, ref), 2, "11 lines on 10-line pages")
end)

test("adobe and chars estimators", function()
    eq(Pages.adobe({ { compressed_size = 1 }, { compressed_size = 1025 }, { compressed_size = 0 } }), 3)
    eq(Pages.chars(3001, 1500), 3)
    eq(Pages.chars(0), 0)
end)

test("apnx estimator matches its definition", function()
    -- 62 paragraphs of 69 chars: 62 paragraph lines, plus one line per 70
    -- characters *carried across paragraphs* (as in the original): 61 -> 123 lines
    local html = string.rep("<p>" .. string.rep("a", 69) .. "</p>", 62)
    eq(Pages.apnx(html, 62 * 69), 3)
    -- a 70-char paragraph needs two lines
    eq(Pages.apnx(string.rep("<p>" .. string.rep("a", 70) .. "</p>", 31), 31 * 70), 2)
end)

H.describe("readability")

test("Spanish syllables follow diphthong and hiatus rules", function()
    local cases = { casa = 2, ["día"] = 2, leer = 2, ciudad = 2, guerra = 2, ["pingüino"] = 3,
        hoy = 1, ["murciélago"] = 4, aire = 2, ["país"] = 2, y = 1, queso = 2 }
    for word, n in pairs(cases) do eq(Readability.syllablesEs(word), n, word) end
end)

test("English syllables are close enough", function()
    local cases = { cat = 1, table = 2, make = 1, jumped = 1, wanted = 2, ratio = 3, beautiful = 3, readability = 5 }
    for word, n in pairs(cases) do eq(Readability.syllablesEn(word), n, word) end
end)

test("language codes", function()
    eq(Readability.language("en-US"), "en")
    eq(Readability.language("spa"), "es")
    eq(Readability.language("de_DE"), "de")
    eq(Readability.language(nil), nil)
end)

test("simple text scores easier than dense text", function()
    local easy = string.rep("The cat sat on the mat. It was a big cat. ", 30)
    local hard = string.rep("Notwithstanding considerable institutional reluctance, comprehensive "
        .. "administrative reorganization necessitated unprecedented interdepartmental cooperation. ", 15)
    local e = Readability.scores(Readability.analyze(easy, "en"), "en")
    local d = Readability.scores(Readability.analyze(hard, "en"), "en")
    truthy(e.ease > 90, "easy: " .. e.ease)
    truthy(d.ease < 10, "hard: " .. d.ease)
    truthy(d.grade > e.grade and d.fog > e.fog)
    eq(e.ease_formula, "flesch")
end)

test("Spanish uses Szigriszt-Pazos on the INFLESZ scale", function()
    local text = string.rep("El niño come pan. La casa es azul y el perro duerme. ", 20)
    local s = Readability.scores(Readability.analyze(text, "es"), "es")
    eq(s.ease_formula, "szigriszt_pazos")
    truthy(s.ease > 80, "simple Spanish is very easy: " .. s.ease)
    eq(s.label, "very_easy")
    eq(s.grade, nil, "grade levels are English-only")
end)

test("too little text gives no score", function()
    eq(Readability.scores(Readability.analyze("Hi there.", "en"), "en"), nil)
end)

H.describe("analyzer")

test("analyses the sample EPUB end to end", function()
    local m = assert(Analyzer.analyze(EPUB, { extract = H.unzip }))
    eq(m.format, "epub")
    eq(m.language, "es")
    eq(m.isbn, "9788437604947")
    eq(m.images, 1, "cover image; non-linear notes skipped")
    truthy(m.words > 3100 and m.words < 3300, "words: " .. m.words)
    eq(#m.chapter_starts, 3, "cover, chapter 1, chapter 2")
    eq(m.chapter_starts[1], 1)
    truthy(m.pages.print >= 4, "print pages: " .. m.pages.print)
    truthy(m.pages.apnx >= 1 and m.pages.adobe >= 1 and m.pages.chars >= 1)
    eq(m.readability.ease_formula, "szigriszt_pazos")
    eq(m.cover_path, "OEBPS/Images/cover.jpg", "cover found by file name")
end)

test("finds covers the EPUB 3 and EPUB 2 ways", function()
    local function open(opf)
        local files = {
            ["META-INF/container.xml"] = '<rootfile full-path="o.opf" media-type="application/oebps-package+xml"/>',
            ["o.opf"] = opf,
        }
        return Epub.open(function(n) return files[n] end, {})
    end
    local spine = '<spine><itemref idref="t"/></spine>'
    local b3 = open('<metadata></metadata><manifest><item id="t" href="t.xhtml" media-type="application/xhtml+xml"/>'
        .. '<item id="c" href="img/front.svg" media-type="image/svg+xml" properties="cover-image"/></manifest>' .. spine)
    eq(b3.cover.path, "img/front.svg")
    local b2 = open('<metadata><meta name="cover" content="pic"/></metadata><manifest><item id="t" href="t.xhtml" media-type="application/xhtml+xml"/>'
        .. '<item id="pic" href="a.jpg" media-type="image/jpeg"/></manifest>' .. spine)
    eq(b2.cover.path, "a.jpg")
end)

test("counts comic pages", function()
    local m = assert(Analyzer.analyze(CBZ))
    eq(m.pages.print, 3)
end)

test("fixed-layout formats ask the document", function()
    local m = Analyzer.analyze("x.pdf", { page_count = function() return 321 end })
    eq(m.pages.print, 321)
    local none, err = Analyzer.analyze("x.mobi", {})
    eq(none, nil); truthy(err)
end)

test("reading time", function()
    eq(Analyzer.readingMinutes(2300, 230), 10)
    eq(Analyzer.readingMinutes(0), 0)
end)

H.describe("metrics cache")

test("stores, validates against file changes and versions", function()
    local files, fs = H.memfs({}, { ["/b/a.epub"] = { size = 10, modification = 1 } })
    local attrs = { ["/b/a.epub"] = { size = 10, modification = 1 } }
    fs.attributes = function(p) return attrs[p] end
    local c = Cache.new("/s/metrics.lua", fs, 1)
    c:put("/b/a.epub", { version = 1, pages = { print = 100 } })
    eq(c:get("/b/a.epub").pages.print, 100)
    c:flush()
    local c2 = Cache.new("/s/metrics.lua", fs, 1)
    eq(c2:get("/b/a.epub").pages.print, 100, "survives reload")
    attrs["/b/a.epub"].modification = 2
    eq(c2:get("/b/a.epub"), nil, "file changed")
    truthy(c2:peek("/b/a.epub"), "stale data still visible")
    local c3 = Cache.new("/s/metrics.lua", fs, 2)
    attrs["/b/a.epub"].modification = 1
    eq(c3:get("/b/a.epub"), nil, "new analyser version")
    truthy(files["/s/metrics.lua"]:find("safe to delete", 1, true))
end)

test("downloaded counts and method selection", function()
    local _files, fs = H.memfs({}, { ["/b/a.epub"] = { size = 1, modification = 1 } })
    local c = Cache.new("/s/m.lua", fs, 1)
    local r = c:put("/b/a.epub", { version = 1, pages = { print = 200, apnx = 180 } })
    eq(Cache.pageCount(r, "downloaded"), 200, "falls back to print")
    c:setDownloaded("/b/a.epub", { pages = 240, source = "work_median", editions = 12 })
    local n, method = Cache.pageCount(r, "downloaded")
    eq(n, 240); eq(method, "downloaded")
    eq(Cache.pageCount(r, "apnx"), 180)
end)

test("rename, remove and prune", function()
    local attrs = { ["/b/a.epub"] = { size = 1, modification = 1 } }
    local _files, fs = H.memfs({}, attrs)
    local c = Cache.new("/s/m.lua", fs, 1)
    c:put("/b/a.epub", { pages = { print = 1 } })
    c:put("/b/gone.epub", { pages = { print = 1 } })
    eq(c:prune(), 1)
    c:rename("/b/a.epub", "/b/b.epub")
    eq(c:peek("/b/a.epub"), nil)
    truthy(c:peek("/b/b.epub"))
end)

test("serializer handles odd keys and numbers", function()
    local s = Cache.serialize({ ["a b"] = 1, [2] = "x", n = 0 / 0, nested = { 1, 2 } })
    local t = (loadstring or load)("return " .. s)()
    eq(t["a b"], 1); eq(t[2], "x"); eq(t.n, 0); eq(t.nested[2], 2)
end)

H.describe("open library")

local function fakeHttp(responses)
    local calls = {}
    return calls, function(url, headers)
        calls[#calls + 1] = { url = url, headers = headers }
        for pattern, body in pairs(responses) do
            if url:find(pattern, 1, true) then return body end
        end
        return nil, "404"
    end
end

-- the json module ships with KOReader; tests only need these shapes
local function fakeJson(s)
    return (loadstring or load)("return " .. s:gsub("%[", "{"):gsub("%]", "}"):gsub('"([%w_]+)":', "%1="))()
end

test("uses the edition's page count when an ISBN is known", function()
    local calls, get = fakeHttp({ ["/isbn/9780743273565.json"] = '{"number_of_pages": 180, "key": "/books/OL1M"}' })
    local r = OpenLibrary.fetch({ isbn = "9780743273565", title = "The Great Gatsby" }, { http_get = get, json_decode = fakeJson })
    eq(r.pages, 180); eq(r.source, "isbn"); eq(#calls, 1)
    truthy(calls[1].headers["User-Agent"]:find("Sereno", 1, true))
end)

test("falls back to the median of the work with most editions", function()
    local calls, get = fakeHttp({ ["search.json"] = '{"docs": [{"key": "/works/A", "number_of_pages_median": 90, "edition_count": 2},'
        .. '{"key": "/works/B", "number_of_pages_median": 288, "edition_count": 400}]}' })
    local r = OpenLibrary.fetch({ title = "Frankenstein; or, The Modern Prometheus", authors = { "Mary Shelley" } },
        { http_get = get, json_decode = fakeJson })
    eq(r.pages, 288); eq(r.source, "work_median"); eq(r.editions, 400)
    truthy(calls[1].url:find("title=Frankenstein&author=Shelley", 1, true), calls[1].url)
end)

test("reports failures", function()
    local _calls, get = fakeHttp({})
    local r, err = OpenLibrary.fetch({ title = "x" }, { http_get = get, json_decode = fakeJson })
    eq(r, nil); truthy(err)
    eq(OpenLibrary.fetch({}, { http_get = get, json_decode = fakeJson }), nil)
end)

-- Optional: real books, used to calibrate the print model.
local books = os.getenv("SERENO_BOOKS")
if books then
    H.describe("real books in " .. books)
    -- printed editions used as reference (see docs/page-count.md)
    local expected = {
        ["f-scott-fitzgerald_the-great-gatsby.epub"] = { pages = 180, tolerance = 0.08 },
    }
    for name, e in pairs(expected) do
        local path = books .. "/" .. name
        if io.open(path, "rb") then
            test(name, function()
                local m = assert(Analyzer.analyze(path, { extract = H.unzip }))
                near(m.pages.print, e.pages, e.pages * e.tolerance, "print pages")
            end)
        end
    end
end
