--[[--
The book page: the book's title as a running head in spaced capitals at
the top, and the page number centred at the foot, as in a printed book.

Registered with KOReader's ReaderView as a view module (the same public
hook KOReader uses for its own page-number labels), so it is painted with
every page and needs no refresh of its own. KOReader's status bar is
hidden while it shows (and given back when it's turned off).

Folio.head(title, upper) and Folio.place(...) are pure, for the tests and
the renderers; Folio.new{...} is the KOReader widget.
]]

local Folio = {}
Folio.__index = Folio

--- "El hobbit" -> "E L   H O B B I T"-like spaced capitals (hair spaces).
function Folio.head(title, upper)
    title = (upper or string.upper)(title or "")
    local out = {}
    for ch in title:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = ch == " " and "\u{2002}" or ch
    end
    return table.concat(out, "\u{200A}")
end

--[[--
Where the head and the folio go: centred, in the middle of the top and
bottom margins. Returns { head_y, folio_y } for text boxes of height
head_h and folio_h.
]]
function Folio.place(screen_h, top_px, bottom_px, head_h, folio_h)
    return {
        head_y = math.max(0, math.floor((top_px - head_h) * 0.55)),
        folio_y = math.floor(screen_h - bottom_px + (bottom_px - folio_h) * 0.45),
    }
end

--[[--
@tparam table o {
  enabled()  -> bool
  info()     -> { title, page_label, font_file, font_size, top_px, bottom_px } or nil
}
]]
function Folio.new(o)
    return setmetatable(o, Folio)
end

local function face(file, size)
    local Font = require("ui/font")
    local ok, f = pcall(Font.getFace, Font, file or "NotoSerif-Regular.ttf", size)
    if ok and f then return f end
    return Font:getFace("NotoSerif-Regular.ttf", size)
end

function Folio:paintTo(bb, x, y)
    if not (self.enabled and self.enabled()) then return end
    local info = self.info and self.info()
    if not info then return end
    local Blitbuffer = require("ffi/blitbuffer")
    local TextWidget = require("ui/widget/textwidget")
    local Screen = require("device").screen
    local w = Screen:getWidth()
    local size = info.font_size or 22
    local upper
    local okp, utf8proc = pcall(require, "ffi/utf8proc")
    if okp and utf8proc and utf8proc.uppercase then upper = function(s) return utf8proc.uppercase(s) end end
    local head = TextWidget:new{ text = Folio.head(info.title, upper), face = face(info.font_file, math.max(9, math.floor(size * 0.6))),
        max_width = math.floor(w * 0.7), fgcolor = Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK, padding = 0 }
    local folio = TextWidget:new{ text = tostring(info.page_label or ""), face = face(info.font_file, math.max(10, math.floor(size * 0.72))),
        fgcolor = Blitbuffer.COLOR_BLACK, padding = 0 }
    local hs, fs = head:getSize(), folio:getSize()
    local pos = Folio.place(Screen:getHeight(), info.top_px or 0, info.bottom_px or 0, hs.h, fs.h)
    if info.title and info.title ~= "" and (info.top_px or 0) >= hs.h then
        head:paintTo(bb, x + math.floor((w - hs.w) / 2), y + pos.head_y)
    end
    if info.page_label and (info.bottom_px or 0) >= fs.h then
        folio:paintTo(bb, x + math.floor((w - fs.w) / 2), y + pos.folio_y)
    end
    head:free()
    folio:free()
end

-- ReaderView calls these on its modules
function Folio:resetLayout() end
function Folio:onCloseWidget() end

return Folio
