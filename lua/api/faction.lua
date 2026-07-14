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

-- Social engineering (porting-order item 2, IMPLEMENTATION_DETAILS.md 4.5):
-- marshals a plain 0-indexed Lua model table {[0]=.., [1]=.., [2]=.., [3]=..}
-- into the ffi.new cdata LuaHostApi's social_calc/social_upheaval expect.
-- Kept here (not in lua/ai/social.lua) so lua/ai/ never touches ffi
-- directly, per the project's ai/ffi boundary rule.
local function models_to_cdata(models)
    return ffi.new("int32_t[4]", { models[0], models[1], models[2], models[3] })
end

-- Returns the 11 CSocialEffect values as a plain named table (field order
-- confirmed against engine_types.h:797-814's CSocialEffect union).
local function social_calc(models, faction_id)
    local out = ffi.new("int32_t[11]")
    funcs.social_calc(models_to_cdata(models), faction_id, out)
    return {
        economy = out[0], effic = out[1], support = out[2], talent = out[3],
        morale = out[4], police = out[5], growth = out[6], planet = out[7],
        probe = out[8], industry = out[9], research = out[10],
    }
end

local function social_upheaval(faction_id, models)
    return funcs.social_upheaval(faction_id, models_to_cdata(models))
end

return {
    get = get,
    meta = get_meta,
    is_human = funcs.is_human,
    has_treaty = funcs.has_treaty,
    climactic_battle = funcs.climactic_battle,
    mod_wants_to_attack = funcs.mod_wants_to_attack,
    society_avail = funcs.society_avail,
    has_project = funcs.has_project,
    has_free_facility = funcs.has_free_facility,
    has_aircraft = funcs.has_aircraft,
    mineral_factor = funcs.mineral_factor,
    un_charter = funcs.un_charter,
    defense_modifier = funcs.defense_modifier,
    keep_fungus = funcs.keep_fungus,
    social_ai_bias = funcs.social_ai_bias,
    social_calc = social_calc,
    social_upheaval = social_upheaval,
    -- War-decision port (porting-order item 2b, IMPLEMENTATION_DETAILS.md
    -- 4.6): great_beelzebub/great_satan/has_agenda stay opaque host calls;
    -- hq_region replaces evaluate_attack's own Bases[]/region_at scan.
    great_beelzebub = funcs.great_beelzebub,
    great_satan = funcs.great_satan,
    has_agenda = funcs.has_agenda,
    hq_region = funcs.hq_region,
}
