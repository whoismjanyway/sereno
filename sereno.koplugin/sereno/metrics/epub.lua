--[[--
Reads the parts of an EPUB that matter for counting: metadata (title,
authors, language, ISBN) and the reading order (spine), with each spine
file's compressed and uncompressed size.

Works on a ZIP index (sereno/metrics/zip) plus a `read(name)` function that
returns an entry's decompressed content.
]]

local Html = require("sereno/metrics/html")

local Epub = {}

local function attr(tag, name)
    local v = tag:match("[%s:]" .. name .. '%s*=%s*"([^"]*)"') or tag:match("[%s:]" .. name .. "%s*=%s*'([^']*)'")
    return v and Html.decodeEntities(v) or nil
end

local function urlDecode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- Resolves "../Text/ch1.xhtml" against the OPF folder.
function Epub.resolve(base_dir, href)
    href = urlDecode(href:gsub("#.*$", ""))
    local parts = {}
    for p in (base_dir .. href):gmatch("[^/]+") do
        if p == ".." then
            parts[#parts] = nil
        elseif p ~= "." then
            parts[#parts + 1] = p
        end
    end
    return table.concat(parts, "/")
end

local function stripTags(s)
    return Html.decodeEntities((s:gsub("<[^>]*>", ""))):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Pulls a usable ISBN-13 or ISBN-10 out of an identifier string.
function Epub.isbn(s)
    if not s then return nil end
    local digits = s:gsub("[%s%-]", ""):gsub("^urn:isbn:", ""):gsub("^isbn:", "")
    local isbn = digits:match("97[89]%d%d%d%d%d%d%d%d%d%d") or digits:match("^%d%d%d%d%d%d%d%d%d[%dXx]$")
    return isbn
end

--[[--
@tparam function read  read(name) -> content or nil
@tparam table by_name  ZIP entries by name (for sizes)
@treturn table|nil { title, authors = {}, language, isbn, cover = { path, media_type },
  spine = { {path, linear, size, compressed_size} } }
@treturn string|nil error
]]
function Epub.open(read, by_name)
    local container = read("META-INF/container.xml")
    if not container then return nil, "no META-INF/container.xml" end
    local opf_path
    for tag in container:gmatch("<[%w:]*rootfile%s[^>]*>") do
        local mt = attr(tag, "media%-type")
        if not mt or mt == "application/oebps-package+xml" then
            opf_path = attr(tag, "full%-path")
            break
        end
    end
    if not opf_path then return nil, "no rootfile in container.xml" end
    local opf = read(opf_path)
    if not opf then return nil, "cannot read " .. opf_path end
    local base_dir = opf_path:match("^(.*/)") or ""

    local book = { authors = {}, spine = {}, opf_path = opf_path }

    -- metadata
    local metadata = opf:match("<[%w:]*metadata[^>]*>(.-)</[%w:]*metadata>") or opf
    book.title = metadata:match("<dc:title[^>]*>(.-)</dc:title>")
    book.title = book.title and stripTags(book.title)
    for creator_tag, name in metadata:gmatch("<dc:creator([^>]*)>(.-)</dc:creator>") do
        local role = attr(creator_tag, "role")
        if not role or role == "aut" then
            book.authors[#book.authors + 1] = stripTags(name)
        end
    end
    local lang = metadata:match("<dc:language[^>]*>(.-)</dc:language>")
    book.language = lang and stripTags(lang):lower() or nil
    for _tag, id in metadata:gmatch("<dc:identifier([^>]*)>(.-)</dc:identifier>") do
        local isbn = Epub.isbn(stripTags(id))
        if isbn then book.isbn = isbn break end
    end

    -- manifest
    local manifest = {}
    for tag in opf:gmatch("<[%w:]*item%s[^>]*>") do
        local id, href = attr(tag, "id"), attr(tag, "href")
        if id and href then
            manifest[id] = {
                path = Epub.resolve(base_dir, href),
                media_type = attr(tag, "media%-type"),
                properties = attr(tag, "properties") or "",
            }
        end
    end

    -- cover image: EPUB 3 "cover-image" property, EPUB 2 <meta name="cover">,
    -- or as a last resort an image whose id or file name says "cover"
    local cover
    for _id, item in pairs(manifest) do
        if item.properties:find("cover-image", 1, true) then cover = item break end
    end
    if not cover then
        for tag in metadata:gmatch("<[%w:]*meta%s[^>]*>") do
            if attr(tag, "name") == "cover" then
                local item = manifest[attr(tag, "content") or ""]
                if item and (item.media_type or ""):find("^image/") then cover = item end
                break
            end
        end
    end
    if not cover then
        for id, item in pairs(manifest) do
            if (item.media_type or ""):find("^image/") and (id:lower():find("cover", 1, true) or item.path:lower():find("cover", 1, true)) then
                cover = item
                break
            end
        end
    end
    if cover then book.cover = { path = cover.path, media_type = cover.media_type } end

    -- spine, in reading order
    local spine_xml = opf:match("<[%w:]*spine[^>]*>(.-)</[%w:]*spine>") or ""
    for tag in spine_xml:gmatch("<[%w:]*itemref%s[^>]*>") do
        local item = manifest[attr(tag, "idref") or ""]
        if item then
            local entry = by_name and by_name[item.path]
            book.spine[#book.spine + 1] = {
                path = item.path,
                linear = attr(tag, "linear") ~= "no",
                is_nav = item.properties:find("nav", 1, true) ~= nil,
                media_type = item.media_type,
                size = entry and entry.size or 0,
                compressed_size = entry and entry.compressed_size or 0,
            }
        end
    end
    if #book.spine == 0 then return nil, "empty spine" end
    return book
end

return Epub
