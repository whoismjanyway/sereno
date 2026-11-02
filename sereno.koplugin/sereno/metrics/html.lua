--[[--
Turns an XHTML content document into a list of text blocks, the way a
printed book would see them: paragraphs, headings, images, breaks.

This is a forgiving tag scanner, not a full XML parser: EPUB content is
usually well-formed, but we must not crash on the ones that are not.
]]

local Text = require("sereno/metrics/text")

local Html = {}

local ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160",
    mdash = "\226\128\148", ndash = "\226\128\147", hellip = "\226\128\166",
    lsquo = "\226\128\152", rsquo = "\226\128\153", ldquo = "\226\128\156", rdquo = "\226\128\157",
    laquo = "\194\171", raquo = "\194\187", iexcl = "\194\161", iquest = "\194\191",
    shy = "", zwj = "", zwnj = "", thinsp = "\226\128\137", ensp = "\226\128\130", emsp = "\226\128\131",
    copy = "\194\169", reg = "\194\174", deg = "\194\176", middot = "\194\183", times = "\195\151",
    eacute = "é", aacute = "á", iacute = "í", oacute = "ó", uacute = "ú", ntilde = "ñ", uuml = "ü",
    Eacute = "É", Aacute = "Á", Iacute = "Í", Oacute = "Ó", Uacute = "Ú", Ntilde = "Ñ", Uuml = "Ü",
    egrave = "è", agrave = "à", ccedil = "ç", ouml = "ö", auml = "ä", szlig = "ß",
}

function Html.decodeEntities(s)
    if not s:find("&", 1, true) then return s end
    return (s:gsub("&(#?[%w]+);", function(e)
        if e:sub(1, 2) == "#x" or e:sub(1, 2) == "#X" then
            local cp = tonumber(e:sub(3), 16)
            return cp and Text.char(cp) or nil
        elseif e:sub(1, 1) == "#" then
            local cp = tonumber(e:sub(2))
            return cp and Text.char(cp) or nil
        end
        return ENTITIES[e]
    end))
end

-- Elements whose start or end begins a new block.
local BLOCK = {
    p = true, div = true, li = true, blockquote = true, pre = true, tr = true,
    dt = true, dd = true, figcaption = true, caption = true, section = true,
    article = true, aside = true, header = true, footer = true, nav = true,
    td = true, th = true, table = true, ul = true, ol = true, dl = true,
    figure = true, address = true, main = true, hgroup = true, body = true,
}
local HEADING = { h1 = 1, h2 = 2, h3 = 3, h4 = 4, h5 = 5, h6 = 6 }
local SKIP = { head = true, script = true, style = true, title = true }

--[[--
@string xhtml
@treturn table blocks: { kind = "p"|"h"|"img"|"hr", text = string, level = n,
  soft = true when the block follows a <br> inside the same paragraph }
@treturn table stats: { images = n }
]]
function Html.blocks(xhtml)
    local blocks = {}
    local buf = {}
    local skip_depth = 0
    local heading = nil
    local images = 0
    local soft = false -- next block continues a paragraph after <br>

    local function flush()
        if #buf == 0 then return end
        local text = Html.decodeEntities(table.concat(buf))
        buf = {}
        -- collapse whitespace (including the non-breaking one) and trim
        text = text:gsub("\194\160", " "):gsub("[%s]+", " "):gsub("^ ", ""):gsub(" $", "")
        if text ~= "" then
            blocks[#blocks + 1] = { kind = heading and "h" or "p", level = heading, text = text, soft = soft or nil }
        end
        soft = false
    end

    -- drop comments and CDATA wrappers up front
    xhtml = xhtml:gsub("<!%-%-.-%-%->", ""):gsub("<!%[CDATA%[(.-)%]%]>", "%1")

    local pos = 1
    local len = #xhtml
    while pos <= len do
        local lt = xhtml:find("<", pos, true)
        if not lt then
            if skip_depth == 0 then buf[#buf + 1] = xhtml:sub(pos) end
            break
        end
        if lt > pos and skip_depth == 0 then
            buf[#buf + 1] = xhtml:sub(pos, lt - 1)
        end
        local gt = xhtml:find(">", lt + 1, true)
        if not gt then break end
        local tag = xhtml:sub(lt + 1, gt - 1)
        pos = gt + 1

        local closing = tag:sub(1, 1) == "/"
        local name = tag:match("^/?%s*([%w:]+)")
        if name then
            name = name:lower():gsub("^.*:", "") -- svg:image -> image
            local self_closing = tag:sub(-1) == "/"
            if SKIP[name] then
                if closing then
                    skip_depth = math.max(0, skip_depth - 1)
                elseif not self_closing then
                    skip_depth = skip_depth + 1
                end
            elseif skip_depth == 0 then
                if HEADING[name] then
                    flush()
                    heading = not closing and HEADING[name] or nil
                elseif BLOCK[name] then
                    flush()
                    soft = false
                elseif name == "br" then
                    -- a line break inside a paragraph (verse, letters): new line, no new paragraph
                    flush()
                    soft = true
                elseif name == "hr" then
                    flush()
                    blocks[#blocks + 1] = { kind = "hr", text = "" }
                elseif (name == "img" or name == "image") and not closing then
                    flush()
                    images = images + 1
                    blocks[#blocks + 1] = { kind = "img", text = "" }
                end
            end
        end
    end
    flush()
    return blocks, { images = images }
end

--- Plain text of a document, blocks separated by newlines.
function Html.text(xhtml)
    local out = {}
    for _i, b in ipairs(Html.blocks(xhtml)) do
        if b.text ~= "" then out[#out + 1] = b.text end
    end
    return table.concat(out, "\n")
end

return Html
