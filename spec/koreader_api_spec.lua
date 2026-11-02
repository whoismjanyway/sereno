-- Every KOReader function Sereno relies on exists in the KOReader checked
-- out at KOREADER_DIR (CI uses the latest release, as on e-readers).
local H = require("helper")
local test, truthy = H.it, H.truthy

local dir = os.getenv("KOREADER_DIR")
H.describe("KOReader API (" .. (dir or "skipped: KOREADER_DIR not set") .. ")")
if not dir then return end

local NEEDED = {
    { "frontend/apps/reader/readerui.lua", "function ReaderUI:onHome" },
    { "frontend/apps/reader/modules/readertoc.lua", "function ReaderToc:getTocTicksFlattened" },
    { "frontend/apps/reader/modules/readertoc.lua", "function ReaderToc:getPreviousChapter" },
    { "frontend/apps/reader/modules/readertoc.lua", "function ReaderToc:getNextChapter" },
    { "frontend/apps/reader/modules/readertoc.lua", "function ReaderToc:getTocTitleByPage" },
    { "frontend/apps/reader/modules/readertoc.lua", "function ReaderToc:onShowToc" },
    { "frontend/apps/reader/modules/readerlink.lua", "function ReaderLink:addCurrentLocationToStack" },
    { "frontend/apps/reader/modules/readerlink.lua", "function ReaderLink:onGoBackLink" },
    { "frontend/apps/reader/modules/readerbookmark.lua", "function ReaderBookmark:onShowBookmark" },
    { "frontend/apps/reader/modules/readersearch.lua", "function ReaderSearch:onShowFulltextSearchInput" },
    { "frontend/apps/reader/modules/readermenu.lua", '"readermenu_tap"' },
    { "frontend/apps/reader/modules/readermenu.lua", '"readermenu_ext_tap"' },
    { "frontend/apps/reader/modules/readermenu.lua", '"readermenu_swipe"' },
    { "frontend/apps/reader/modules/readerconfig.lua", '"readerconfigmenu_tap"' },
    { "frontend/apps/reader/modules/readerconfig.lua", '"readerconfigmenu_ext_tap"' },
    { "frontend/apps/reader/modules/readerstyletweak.lua", "function ReaderStyleTweak:updateCssText" },
    { "frontend/apps/reader/modules/readerfont.lua", "function ReaderFont:onSetFont" },
    { "frontend/apps/reader/modules/readerpagemap.lua", "function ReaderPageMap:wantsPageLabels" },
    { "frontend/apps/reader/modules/readerpagemap.lua", "function ReaderPageMap:getCurrentPageLabel" },
    { "frontend/apps/reader/modules/readerpagemap.lua", "function ReaderPageMap:resetLayout" },
    { "frontend/document/credocument.lua", "function CreDocument:buildSyntheticPageMap" },
    { "frontend/apps/reader/modules/readertypeset.lua", "unscaled_margins" },
    { "frontend/ui/elements/screensaver_menu.lua", "return" },
    { "frontend/ui/screensaver.lua", "random_image" },
    { "frontend/device/devicelistener.lua", "function DeviceListener:onIterateRotation" },
    { "frontend/device/devicelistener.lua", "function DeviceListener:onRequestSuspend" },
    { "frontend/device/devicelistener.lua", "function DeviceListener:onToggleNightMode" },
    { "frontend/ui/network/networklistener.lua", "function NetworkListener:onToggleWifi" },
    { "frontend/readcollection.lua", "function ReadCollection:getOrderedCollection" },
    { "frontend/ui/widget/booklist.lua", "function BookList.getBookInfo" },
    { "frontend/apps/filemanager/filemanager.lua", "function FileManager:addFileDialogButtons" },
    { "frontend/ui/widget/container/inputcontainer.lua", "function InputContainer:registerTouchZones" },
    { "frontend/fontlist.lua", "fontinfo" },
}

test("the functions Sereno calls are all there", function()
    for _i, need in ipairs(NEEDED) do
        local f = io.open(dir .. "/" .. need[1], "r")
        local src = f and f:read("*a") or ""
        if f then f:close() end
        truthy(src:find(need[2], 1, true), need[1] .. ": " .. need[2])
    end
end)
