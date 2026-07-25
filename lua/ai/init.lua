-- Collects every ported module's hooks into the table src/luaai.cpp's
-- register_hooks() reads at (re)load (IMPLEMENTATION_PLAN.md Phase 4.1/
-- 4.4: "one module per domain ... registering hooks in a central table").
local tech = dofile("lua/ai/tech.lua")
local social = dofile("lua/ai/social.lua")
local war = dofile("lua/ai/war.lua")
local build = dofile("lua/ai/build.lua")
local move = dofile("lua/ai/move.lua")
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
    turn_state_hash = state_hash.dump,
    -- Consolidation gate item b: facility_score/governor_priorities
    -- become hookable via the typed-descriptor refactor (out_count > 1)
    -- plus these two thin adapters (lua/ai/build.lua) -- closes the gap
    -- IMPLEMENTATION_DETAILS.md 4.9 left open.
    facility_score = build.facility_score_hook,
    governor_priorities = build.governor_priorities_hook,
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
    -- select_build itself, step 4 (IMPLEMENTATION_DETAILS.md 4.10): the
    -- real Class 2 hook (IMPLEMENTATION_PLAN.md Phase 4.1) -- the first
    -- hook in the project whose return value actually drives the game
    -- (via lua_ai_hook) rather than only feeding a shadow-mode
    -- comparison log. Every branch above remains registered too, so
    -- their existing lua_ai_shadow_call/_check seams in the C++
    -- fallback body still work whenever lua_ai=0 or this hook errors.
    select_build = build.select_build,
    -- Movement port, stage 1 (IMPLEMENTATION_DETAILS.md 4.12): the first
    -- Class 3 (command/effect) hook in the project -- see luaai.h's
    -- lua_ai_command_hook for the contract (no fallback once a mutation
    -- is issued, unlike every hook above).
    artifact_move = move.artifact_move,
    -- Movement port, stage 2 (IMPLEMENTATION_DETAILS.md 4.12): same
    -- Class 3 contract as artifact_move.
    crawler_move = move.crawler_move,
    -- Movement port, stage 3 (IMPLEMENTATION_DETAILS.md 4.12): same
    -- Class 3 contract as artifact_move/crawler_move.
    colony_move = move.colony_move,
    -- Movement port, stage 4 (IMPLEMENTATION_DETAILS.md 4.13): same
    -- Class 3 contract as artifact_move/crawler_move/colony_move.
    former_move = move.former_move,
    -- Movement port, stage 5 (IMPLEMENTATION_DETAILS.md 4.14): same
    -- Class 3 contract as artifact_move/crawler_move/colony_move/
    -- former_move.
    trans_move = move.trans_move,
    -- Movement port, stage 6 (IMPLEMENTATION_DETAILS.md 4.15): same
    -- Class 3 contract as artifact_move/crawler_move/colony_move/
    -- former_move/trans_move.
    combat_move = move.combat_move,
    -- Movement stage 7B (IMPLEMENTATION_DETAILS.md 4.16): first faction-
    -- level Class 3 hook (lua_ai_command_hook_faction, not
    -- lua_ai_command_hook -- (faction_id) -> void, not (veh_id) -> int).
    -- Hooked at the call site in move_upkeep (C++), not inside
    -- land_raise_plan's own body -- see move.cpp's move_upkeep.
    land_raise_plan = move.land_raise_plan,
    -- Movement stage 7C (IMPLEMENTATION_DETAILS.md 4.16): same
    -- faction-level Class 3 contract as land_raise_plan (7B), same hook
    -- site in move_upkeep.
    invasion_plan = move.invasion_plan,
}
