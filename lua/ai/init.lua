-- Collects every ported module's hooks into the table src/luaai.cpp's
-- register_hooks() reads at (re)load (IMPLEMENTATION_PLAN.md Phase 4.1/
-- 4.4: "one module per domain ... registering hooks in a central table").
local tech = dofile("lua/ai/tech.lua")
local social = dofile("lua/ai/social.lua")
local war = dofile("lua/ai/war.lua")
local build = dofile("lua/ai/build.lua")
-- Not an AI module -- the autoplay determinism harness's per-turn state
-- hash (IMPLEMENTATION_PLAN.md "Consolidation gate" item a). Registered
-- here anyway because register_hooks() only reads this one table; see
-- lua/harness/state_hash.lua for why.
local state_hash = dofile("lua/harness/state_hash.lua")

return {
    mod_tech_val = tech.mod_tech_val,
    mod_tech_ai = tech.mod_tech_ai,
    mod_social_ai = social.mod_social_ai,
    mod_wants_to_attack = war.mod_wants_to_attack,
    find_proto = build.find_proto,
    select_colony = build.select_colony,
    select_combat = build.select_combat,
    vehicle_counts_check = build.vehicle_counts_check,
    turn_state_hash = state_hash.dump,
    -- Consolidation gate item b: facility_score/governor_priorities
    -- become hookable via the typed-descriptor refactor (out_count > 1)
    -- plus these two thin adapters (lua/ai/build.lua) -- closes the gap
    -- IMPLEMENTATION_DETAILS.md 4.9 left open.
    facility_score = build.facility_score_hook,
    governor_priorities = build.governor_priorities_hook,
}
