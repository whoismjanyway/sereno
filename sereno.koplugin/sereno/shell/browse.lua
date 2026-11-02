--[[--
What the Library, Reading, Collections and Search tabs show. Pure Lua:
everything comes in through `sources`, so the tabs can be built and
checked without KOReader.

  Browse.build(tab, state, sources) -> model

tab      "library" | "history" | "collections" | "search"
state    { path, collection, query, sort, page }
sources  {
  home_dir()            -> path
  list_dir(path)        -> { dirs = { {name, path, count} }, files = { path... } }
  history()             -> { path... }, most recent first
  collections()         -> { {name, count} }
  collection(name)      -> { path... }
  search(query)         -> { path... }
  book_info(path)       -> { title, authors, percent, status, mtime }
}
model    { tab, title, subtitle, back (action or nil), sort, query,
           items = { {kind = "folder"|"collection"|"book", ...} }, empty }
]]

local Browse = {}

Browse.SORTS = { "title", "author", "recent" }
Browse.SORT_LABELS = { title = "Title", author = "Author", recent = "Recent" }

local function basename(path)
    return (path:gsub("/+$", ""):match("([^/]+)$")) or path
end

local function lower(s) return (s or ""):lower() end

local function bookItem(sources, file)
    local info = sources.book_info and sources.book_info(file) or {}
    local authors = info.authors
    if type(authors) == "table" then authors = table.concat(authors, ", ") end
    local title = info.title
    if not title or title == "" then
        title = basename(file):gsub("%.[^.]+$", ""):gsub("_", " ")
    end
    return {
        kind = "book", file = file, title = title, authors = authors,
        percent = info.percent or 0, status = info.status or "new", mtime = info.mtime or 0,
    }
end

local function sortBooks(items, sort)
    table.sort(items, function(a, b)
        if sort == "author" then
            local x, y = lower(a.authors), lower(b.authors)
            if x ~= y then
                if x == "" then return false end
                if y == "" then return true end
                return x < y
            end
        elseif sort == "recent" then
            if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        end
        return lower(a.title) < lower(b.title)
    end)
end

local function books(sources, files, sort)
    local items = {}
    for _i, f in ipairs(files or {}) do items[#items + 1] = bookItem(sources, f) end
    if sort then sortBooks(items, sort) end
    return items
end

function Browse.build(tab, state, sources)
    state = state or {}
    local sort = state.sort or "title"
    local model = { tab = tab, sort = sort, items = {} }

    if tab == "library" then
        local home = sources.home_dir and sources.home_dir() or "/"
        local path = state.path or home
        local listing = sources.list_dir(path) or {}
        local items = {}
        local dirs = listing.dirs or {}
        table.sort(dirs, function(a, b) return lower(a.name) < lower(b.name) end)
        for _i, d in ipairs(dirs) do
            items[#items + 1] = { kind = "folder", name = d.name, path = d.path, count = d.count }
        end
        local book_items = books(sources, listing.files, sort)
        for _i, b in ipairs(book_items) do items[#items + 1] = b end
        model.items = items
        model.path = path
        model.title = path == home and "Library" or basename(path)
        model.subtitle_count = #book_items
        model.subtitle_folders = #dirs
        if path ~= home and path:sub(1, #home) == home then
            model.back = { type = "folder", path = path:match("^(.*)/[^/]+/?$") or home }
        end
        model.sortable = true
        model.empty = "No books in this folder"
    elseif tab == "history" then
        -- the reading list: books in progress first, then the rest by recency
        local items = books(sources, sources.history and sources.history() or {})
        local reading, rest = {}, {}
        for _i, b in ipairs(items) do
            if b.status == "reading" or (b.status ~= "complete" and b.percent > 0 and b.percent < 1) then
                reading[#reading + 1] = b
            else
                rest[#rest + 1] = b
            end
        end
        for _i, b in ipairs(rest) do reading[#reading + 1] = b end
        model.items = reading
        model.title = "Reading"
        model.subtitle_count = #reading
        model.empty = "Books you open appear here"
    elseif tab == "collections" then
        if state.collection then
            model.items = books(sources, sources.collection and sources.collection(state.collection) or {})
            model.title = state.collection
            model.back = { type = "collections_root" }
            model.subtitle_count = #model.items
            model.empty = "This collection is empty"
        else
            for _i, c in ipairs(sources.collections and sources.collections() or {}) do
                model.items[#model.items + 1] = { kind = "collection", name = c.name, count = c.count }
            end
            model.title = "Collections"
            model.subtitle_collections = #model.items
            model.empty = "Long-press a book in KOReader's file browser to add it to a collection"
        end
    elseif tab == "search" then
        model.title = "Search"
        model.query = state.query
        if state.query and state.query ~= "" then
            model.items = books(sources, sources.search and sources.search(state.query) or {}, sort)
            model.subtitle_count = #model.items
            model.empty = "No books match"
        else
            model.empty = "Search your library by title, author or file name"
        end
        model.searchable = true
    end
    return model
end

--- Next sort order after `sort`.
function Browse.nextSort(sort)
    for i, s in ipairs(Browse.SORTS) do
        if s == sort then return Browse.SORTS[i % #Browse.SORTS + 1] end
    end
    return Browse.SORTS[1]
end

--[[--
Matches a query against a book: every word of the query must appear in its
title, authors or file name, ignoring case.
]]
function Browse.matches(query, title, authors, file)
    local hay = lower(title) .. " " .. lower(authors) .. " " .. lower(basename(file or ""))
    for word in lower(query):gmatch("%S+") do
        if not hay:find(word, 1, true) then return false end
    end
    return true
end

return Browse
