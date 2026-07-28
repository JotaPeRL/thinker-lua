-- Production/plans port, item 3 remainder (IMPLEMENTATION_PLAN.md Phase
-- 4.2 item 3, IMPLEMENTATION_DETAILS.md 4.18 for the survey that scoped
-- this). former_plans (plan.cpp:448-467) is the first of three
-- (plans_upkeep and design_units follow; plans_upkeep itself is likely
-- not a porting target -- see 4.18). Faction-level Class 3 hook
-- (lua_ai_command_hook_faction), same shape stage 7B/7C/7D already
-- established -- hooked at the call site in plans_upkeep (plan.cpp), not
-- inside former_plans's own body, same convention as
-- land_raise_plan/invasion_plan.
local port = {
    source = {
        former_plans = { file = "src/plan.cpp", func = "former_plans",
            upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
    },
}

local types = dofile_once("lua/ffi/validate.lua")
local funcs = dofile_once("lua/ffi/funcs.lua")
local tech = dofile("lua/api/tech.lua")
local cmath = dofile("lua/api/cmath.lua")

local E = types.enums
local clamp = cmath.clamp

-- Same one-field-address technique as tech.lua's ResInfoRecyclingTanks
-- and move.lua's own ResInfoForestSq (the FIELD()/FieldShape mechanism
-- can't emit_struct a nested-struct member) -- read as int32_t[3]
-- (nutrient, mineral, energy, skipping the unused 4th), all three used
-- here unlike move.lua's single-field use.
local ResInfoForestSq = ffi.cast("int32_t*", types.globals.ResInfoForestSq)

-- former_plans's own fungus_yield(faction_id, RES_NONE) call kept as an
-- opaque host wrapper (IMPLEMENTATION_DETAILS.md 4.18): a real formula,
-- but over several Faction tech_fungus_*/SE_*_pending fields not yet
-- named in the generated cdef, plus the ManifoldHarmonicsBonus[][3]
-- lookup table -- not worth re-exposing either for this one call site.
local function former_plans(faction_id)
    local facility = tech.facility(E.FAC_TREE_FARM)
    local tree_farm = funcs.has_tech(facility.preq_tech, faction_id) ~= 0
        and facility.cost + facility.maint < 20
    local former_fungus = funcs.has_terra(E.FORMER_PLANT_FUNGUS, E.TRIAD_LAND, faction_id)
        or funcs.has_terra(E.FORMER_PLANT_FUNGUS, E.TRIAD_SEA, faction_id)
    local rules = tech.rules()
    local improv_fungus = funcs.has_tech(rules.tech_preq_improv_fungus, faction_id) ~= 0
        or funcs.has_tech(rules.tech_preq_build_road_fungus, faction_id) ~= 0
        or funcs.has_project(E.FAC_XENOEMPATHY_DOME, faction_id) ~= 0
    local value = funcs.fungus_yield(faction_id, E.RES_NONE)
        - (funcs.has_terra(E.FORMER_FOREST, E.TRIAD_LAND, faction_id)
            and ((tree_farm and 1 or 0) + ResInfoForestSq[0] + ResInfoForestSq[1] + ResInfoForestSq[2])
            or 2)
    funcs.set_keep_fungus(faction_id, clamp(2 * value, 0, improv_fungus and 8 or 4))
    local plant_fungus = former_fungus and value >= 0
        and value + (improv_fungus and 1 or 0)
            + funcs.has_project(E.FAC_MANIFOLD_HARMONICS, faction_id) > 1
    funcs.set_plant_fungus(faction_id, plant_fungus and 1 or 0)
    funcs.set_build_tubes(faction_id,
        funcs.has_terra(E.FORMER_MAGTUBE, E.TRIAD_LAND, faction_id) and 1 or 0)
end

port.former_plans = former_plans
return port
