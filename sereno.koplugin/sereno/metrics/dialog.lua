--[[--
"Pages & readability" dialog for one book: every page estimate side by
side, words, reading time and readability, plus the Open Library download.
]]

local Analyzer = require("sereno/metrics/analyzer")
local Context = require("sereno/home/context")
local Presenter = require("sereno/home/presenter")
local Service = require("sereno/metrics/service")
local _ = require("sereno/l10n")

local InfoMessage = require("ui/widget/infomessage")
local KeyValuePage = require("ui/widget/keyvaluepage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template

local Dialog = {}

local METHOD_LABELS = {
    print = "Print model (Sereno)",
    downloaded = "Printed edition (Open Library)",
    apnx = "Calibre APNX estimate",
    adobe = "Adobe Digital Editions",
    chars = "Characters per page",
}
Dialog.METHOD_LABELS = METHOD_LABELS
Dialog.METHODS = { "print", "downloaded", "apnx", "adobe", "chars" }

local function n(v, sep)
    if not v then return "—" end
    return Presenter.thousands(v, sep or _.catalogue.thousands_separator or ",")
end

local function durationWords()
    return { h = _("h"), min = _("min"), less = _("under a minute") }
end

function Dialog.rows(m, opts)
    opts = opts or {}
    local rows = {}
    local function add(k, v, cb) rows[#rows + 1] = { k, v, callback = cb } end
    local function sep() if #rows > 0 then rows[#rows].separator = true end end
    local p = m.pages or {}
    local current = opts.page_method or "print"
    for _i, method in ipairs(Dialog.METHODS) do
        local value = p[method]
        if method == "chars" and value then
            value = T(_("%1 (%2 characters each)"), n(value), m.chars_per_page or 1500)
        elseif method == "downloaded" and value and m.download then
            if m.download.source == "work_median" and m.download.editions then
                value = T(_("%1 (median of %2 editions)"), n(value), m.download.editions)
            else
                value = n(value)
            end
        else
            value = value and n(value) or (method == "downloaded" and _("not downloaded") or nil)
        end
        if value then
            add((method == current and "▸ " or "") .. _(METHOD_LABELS[method]), value)
        end
    end
    sep()
    if m.words then
        add(_("Words"), n(m.words))
        add(T(_("Reading time at %1 wpm"), opts.wpm or 230),
            Context.formatDuration(Analyzer.readingMinutes(m.words, opts.wpm), durationWords()))
    end
    if m.images and m.images > 0 then add(_("Images"), n(m.images)) end
    local r = m.readability
    if r then
        sep()
        add(_("Readability"), _(Presenter.READABILITY[r.label] or r.label))
        local formula = ({ flesch = "Flesch Reading Ease", szigriszt_pazos = "Szigriszt-Pazos (INFLESZ)",
            amstad = "Flesch–Amstad" })[r.ease_formula] or r.ease_formula
        add(formula, tostring(r.ease) .. (r.approximate and (" (" .. _("approximate for this language") .. ")") or ""))
        if r.grade then add(_("Flesch–Kincaid grade"), tostring(r.grade)) end
        if r.fog then add(_("Gunning fog index"), tostring(r.fog)) end
        add(_("Words per sentence"), tostring(r.words_per_sentence))
    end
    if m.language then add(_("Language"), m.language) end
    return rows
end

--[[--
Shows the dialog, computing metrics first if needed.
@tparam string file
@tparam table opts { page_method, wpm, on_change = function() }
]]
function Dialog.show(file, opts)
    opts = opts or {}
    local m = Service.peek(file)
    if not m then
        local msg = InfoMessage:new{ text = _("Counting pages…") }
        UIManager:show(msg)
        UIManager:forceRePaint()
        local err
        m, err = Service.get(file)
        UIManager:close(msg)
        if not m then
            UIManager:show(InfoMessage:new{ text = T(_("Could not count this book:\n%1"), err or "?") })
            return
        end
        if opts.on_change then opts.on_change() end
    end
    local rows = Dialog.rows(m, opts)
    local page
    if #rows > 0 then rows[#rows].separator = true end
    rows[#rows + 1] = {
        _("Download printed page count"), "›",
        callback = function()
            local NetworkMgr = require("ui/network/manager")
            NetworkMgr:runWhenOnline(function()
                local msg = InfoMessage:new{ text = _("Asking Open Library…") }
                UIManager:show(msg)
                UIManager:forceRePaint()
                local result, err = Service.download(file)
                UIManager:close(msg)
                if result then
                    if page then UIManager:close(page) end
                    if opts.on_change then opts.on_change() end
                    Dialog.show(file, opts)
                else
                    UIManager:show(InfoMessage:new{ text = T(_("No printed page count found.\n%1"), err or "") })
                end
            end)
        end,
    }
    rows[#rows + 1] = {
        _("Count again"), "›",
        callback = function()
            if page then UIManager:close(page) end
            Service.get(file, true)
            if opts.on_change then opts.on_change() end
            Dialog.show(file, opts)
        end,
    }
    page = KeyValuePage:new{
        title = m.title or file:match("([^/]+)$"),
        kv_pairs = rows,
    }
    UIManager:show(page)
end

return Dialog
