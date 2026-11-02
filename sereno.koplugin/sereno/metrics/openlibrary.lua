--[[--
Downloads a printed page count from Open Library, the way Count Pages can
download one from Goodreads. Open Library has a free JSON API and no key.

1. With an ISBN: the page count of that exact edition.
2. Otherwise: search by title + author and take the median page count over
   all editions of the work (`number_of_pages_median`).

HTTP and JSON are injected so this can be tested offline:
  http_get(url, headers) -> body|nil, err
  json_decode(string) -> table
]]

local OpenLibrary = {}

OpenLibrary.BASE = "https://openlibrary.org"
OpenLibrary.USER_AGENT = "Sereno/0.2 (KOReader plugin; https://github.com/whoismjanyway/sereno)"

local function urlEncode(s)
    return (s:gsub("[^%w%-%._~ ]", function(c) return string.format("%%%02X", c:byte()) end):gsub(" ", "+"))
end

--- Keep the main title only: "Frankenstein; or, The Modern Prometheus" -> "Frankenstein".
function OpenLibrary.cleanTitle(title)
    if not title then return nil end
    local t = title:gsub("%s*[:;%(%[].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return t ~= "" and t or title
end

function OpenLibrary.isbnUrl(isbn)
    return string.format("%s/isbn/%s.json", OpenLibrary.BASE, isbn)
end

function OpenLibrary.searchUrl(title, author)
    local q = "title=" .. urlEncode(OpenLibrary.cleanTitle(title))
    if author and author ~= "" then
        -- surname is the most robust key ("Mary Wollstonecraft Shelley" vs "Mary Shelley")
        q = q .. "&author=" .. urlEncode(author:match("(%S+)%s*$") or author)
    end
    return string.format("%s/search.json?%s&fields=key,title,number_of_pages_median,edition_count&limit=5",
        OpenLibrary.BASE, q)
end

local function decode(deps, body)
    local ok, data = pcall(deps.json_decode, body)
    if ok and type(data) == "table" then return data end
    return nil
end

--[[--
@tparam table book { isbn, title, authors = {} }
@tparam table deps { http_get, json_decode }
@treturn table|nil { pages = n, source = "isbn"|"work_median", editions = n, key = "/works/..." }
@treturn string|nil error
]]
function OpenLibrary.fetch(book, deps)
    local headers = { ["User-Agent"] = OpenLibrary.USER_AGENT }
    if book.isbn then
        local body = deps.http_get(OpenLibrary.isbnUrl(book.isbn), headers)
        local data = body and decode(deps, body)
        local pages = data and tonumber(data.number_of_pages)
        if pages and pages > 0 then
            return { pages = pages, source = "isbn", key = data.key }
        end
    end
    if not book.title then return nil, "no title or ISBN to search for" end
    local body, err = deps.http_get(OpenLibrary.searchUrl(book.title, book.authors and book.authors[1]), headers)
    if not body then return nil, err or "network error" end
    local data = decode(deps, body)
    if not data or type(data.docs) ~= "table" then return nil, "unexpected answer from Open Library" end
    -- the work with most editions is almost always the one we mean
    local best
    for _i, doc in ipairs(data.docs) do
        local pages = tonumber(doc.number_of_pages_median)
        if pages and pages > 0 and (not best or (doc.edition_count or 0) > (best.edition_count or 0)) then
            best = doc
        end
    end
    if not best then return nil, "no page count found" end
    return {
        pages = tonumber(best.number_of_pages_median),
        source = "work_median",
        editions = best.edition_count,
        key = best.key,
    }
end

return OpenLibrary
