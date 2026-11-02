--[[--
Pure menu-tier engine. No KOReader dependencies, so it can be unit-tested
with plain Lua.

Given KOReader's default menu order table (the one in
ui/elements/<reader|filemanager>_menu_order.lua), optional user overrides
of that order, a map of item id -> level, and the current tier, it builds
an order table that KOReader's own MenuSorter understands. We hide items
through the official "KOMenu:disabled" list instead of patching widgets.

Levels:
  1 = Reading   (reading essentials)
  2 = Everyday  (no advanced options)
  3 = Everything (all of KOReader)
An item is visible when level(item) <= current tier.
]]

local Tiers = {}

Tiers.SEPARATOR = "----------------------------"
Tiers.READING, Tiers.EVERYDAY, Tiers.ALL = 1, 2, 3
Tiers.DEFAULT_LEVEL = 2
Tiers.BUTTONS = "KOMenu:menu_buttons"
Tiers.DISABLED = "KOMenu:disabled"

local function shallowCopyList(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    return out
end

--- Overlay user overrides (same shape as the default order) on the defaults.
-- Mirrors what MenuSorter:mergeAndSort does: per-key replacement.
function Tiers.merge(defaults, user)
    local out = {}
    for k, v in pairs(defaults) do
        if type(v) == "table" then out[k] = shallowCopyList(v) end
    end
    for k, v in pairs(user or {}) do
        if type(v) == "table" then out[k] = shallowCopyList(v) end
    end
    return out
end

--- Remove leading, trailing and doubled separators.
function Tiers.tidySeparators(list)
    local out = {}
    for _, id in ipairs(list) do
        if id == Tiers.SEPARATOR then
            if #out > 0 and out[#out] ~= Tiers.SEPARATOR then
                out[#out + 1] = id
            end
        else
            out[#out + 1] = id
        end
    end
    while out[#out] == Tiers.SEPARATOR do out[#out] = nil end
    return out
end

function Tiers.levelOf(id, levels, overrides)
    if overrides and overrides[id] then return overrides[id] end
    if levels and levels[id] then return levels[id] end
    return Tiers.DEFAULT_LEVEL
end

--[[--
Build the filtered order.

@tparam table base merged order (see Tiers.merge)
@tparam table opts
  levels     id -> default level
  overrides  id -> level chosen by the user (wins over levels)
  tier       current tier (1..3)
  pinned     set of ids that are always visible
  keep_empty_containers  keep containers even when all children are hidden
                         (needed in KOReader debug mode, where a plugin's
                         sorting_hint pointing at a missing menu asserts)
@treturn table order table, with Tiers.DISABLED listing every hidden id
@treturn table set of hidden ids
]]
function Tiers.build(base, opts)
    opts = opts or {}
    local tier = opts.tier or Tiers.ALL
    local pinned = opts.pinned or {}
    local hidden = {}
    local result = {}

    local function isContainer(id)
        return type(base[id]) == "table" and id ~= Tiers.BUTTONS
    end

    local function visibleLeaf(id)
        if pinned[id] then return true end
        return Tiers.levelOf(id, opts.levels, opts.overrides) <= tier
    end

    -- Depth-first so a container knows whether it ended up empty.
    local visiting = {}
    local function filter(menu_id)
        if result[menu_id] then return result[menu_id] end
        if visiting[menu_id] then return {} end -- defensive: cyclic order
        visiting[menu_id] = true
        local out = {}
        for _, id in ipairs(base[menu_id] or {}) do
            if id == Tiers.SEPARATOR then
                out[#out + 1] = id
            elseif isContainer(id) then
                local children = filter(id)
                local has_real = false
                for _, c in ipairs(children) do
                    if c ~= Tiers.SEPARATOR then has_real = true break end
                end
                -- A container is shown when it has visible children, unless it
                -- was given an explicit level of its own that hides it.
                local explicit = (opts.overrides and opts.overrides[id]) or (opts.levels and opts.levels[id])
                local container_ok = pinned[id] or not explicit or explicit <= tier
                -- Containers listed as empty in the defaults (e.g. "plus_menu",
                -- "filemanager") are filled at runtime: never drop them.
                local declared_empty = #base[id] == 0
                if declared_empty or opts.keep_empty_containers or (has_real and container_ok) then
                    out[#out + 1] = id
                else
                    hidden[id] = true
                end
            elseif visibleLeaf(id) then
                out[#out + 1] = id
            else
                hidden[id] = true
            end
        end
        result[menu_id] = Tiers.tidySeparators(out)
        visiting[menu_id] = nil
        return result[menu_id]
    end

    -- Top-level tabs are always kept, so sorting_hint targets survive.
    for _, tab in ipairs(base[Tiers.BUTTONS] or {}) do
        if isContainer(tab) then filter(tab) end
    end
    result[Tiers.BUTTONS] = shallowCopyList(base[Tiers.BUTTONS] or {})

    -- Containers not reachable from a tab still get written so a stale
    -- cached copy inside KOReader is fully overwritten.
    for id, v in pairs(base) do
        if type(v) == "table" and not result[id] and id ~= Tiers.DISABLED then
            filter(id)
        end
    end

    local disabled = {}
    for _, id in ipairs(base[Tiers.DISABLED] or {}) do
        disabled[#disabled + 1] = id
    end
    local hidden_sorted = {}
    for id in pairs(hidden) do hidden_sorted[#hidden_sorted + 1] = id end
    table.sort(hidden_sorted)
    for _, id in ipairs(hidden_sorted) do disabled[#disabled + 1] = id end
    result[Tiers.DISABLED] = disabled

    return result, hidden
end

--- Give level 3 to every unlisted leaf inside the given containers.
-- Returns a new map; the input map is left untouched.
function Tiers.expandLevels(base, levels, all_inside)
    local out = {}
    for k, v in pairs(levels or {}) do out[k] = v end
    for _, container in ipairs(all_inside or {}) do
        for _, id in ipairs(base[container] or {}) do
            if id ~= Tiers.SEPARATOR and out[id] == nil and type(base[id]) ~= "table" then
                out[id] = Tiers.ALL
            end
        end
    end
    return out
end

--- Count visible leaf items, used for the "N visible options" summary.
function Tiers.countVisible(order)
    local n = 0
    for id, list in pairs(order) do
        if id ~= Tiers.DISABLED and id ~= Tiers.BUTTONS then
            for _, item in ipairs(list) do
                if item ~= Tiers.SEPARATOR and type(order[item]) ~= "table" then
                    n = n + 1
                end
            end
        end
    end
    return n
end

return Tiers
