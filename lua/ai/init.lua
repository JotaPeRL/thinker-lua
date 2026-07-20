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
    -- select_build step 2 (IMPLEMENTATION_DETAILS.md 4.10.9, resumed
    -- after the Consolidation gate): temporary, verification-only, same
    -- precedent as vehicle_counts_check -- deleted once step 4 wires the
    -- real select_build hook.
    push_item_check = build.push_item_check,
    -- select_build step 3 sub-step 1 (IMPLEMENTATION_DETAILS.md
    -- 4.10.9/4.10.12, resumed after the Consolidation gate): same
    -- temporary, verification-only precedent.
    select_build_prologue_check = build.select_build_prologue_check,
    -- select_build step 3 sub-step 2 (IMPLEMENTATION_DETAILS.md
    -- 4.10.9/4.10.13, resumed after the Consolidation gate): real
    -- Class 1/2 shadow hooks, not temporary diagnostic ones -- both
    -- consume RNG (random(8)/random(256)) with no existing debug line to
    -- diff against, so C++ calls these via lua_ai_shadow_call/_check
    -- (RNG snapshot/restore), same as find_proto/mod_tech_ai.
    defend_unit_land_defense = build.defend_unit_land_defense,
    defend_unit_explore_veh = build.defend_unit_explore_veh,
    combat_unit_early_return = build.combat_unit_early_return,
    -- select_build step 3 sub-step 3 (IMPLEMENTATION_DETAILS.md
    -- 4.10.9/4.10.14, resumed after the Consolidation gate): the
    -- build_order loop's per-item base score. Real shadow hook (consumes
    -- RNG via random(32)), same reasoning as sub-step 2.
    build_order_item_score = build.build_order_item_score,
    -- select_build itself, unit-branch catalog (IMPLEMENTATION_DETAILS.md
    -- 4.10.27): ColonyUnit/CrawlerUnit/FerryUnit/SeaProbeUnit. All consume
    -- RNG (find_proto/select_colony's own internal draws), same
    -- shadow_call/check treatment as the branches above.
    colony_unit_branch = build.colony_unit_branch,
    crawler_unit_branch = build.crawler_unit_branch,
    ferry_unit_branch = build.ferry_unit_branch,
    sea_probe_unit_branch = build.sea_probe_unit_branch,
    satellites_branch = build.satellites_branch,
    secret_project_branch = build.secret_project_branch,
    former_unit_branch = build.former_unit_branch,
}
