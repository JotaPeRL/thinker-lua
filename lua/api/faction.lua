-- Faction/MFaction accessors + the faction-domain host-API wrappers
-- mod_tech_val/mod_tech_ai depend on (IMPLEMENTATION_PLAN.md Phase 3.2,
-- narrowed to the tech-AI pilot's needs -- see the plan for what's
-- deliberately deferred: no VEH/BASE/live-map access here).
local types = dofile_once("lua/ffi/validate.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")

local Factions = ffi.cast("Faction*", types.globals.Factions)
local MFactions = ffi.cast("MFaction*", types.globals.MFactions)

local function get(faction_id)
    assert(faction_id >= 0 and faction_id < types.counts.MaxPlayerNum,
        "faction_id out of range: " .. tostring(faction_id))
    return Factions[faction_id]
end

local function get_meta(faction_id)
    assert(faction_id >= 0 and faction_id < types.counts.MaxPlayerNum,
        "faction_id out of range: " .. tostring(faction_id))
    return MFactions[faction_id]
end

return {
    get = get,
    meta = get_meta,
    is_human = funcs.is_human,
    has_treaty = funcs.has_treaty,
    climactic_battle = funcs.climactic_battle,
    mod_wants_to_attack = funcs.mod_wants_to_attack,
}
