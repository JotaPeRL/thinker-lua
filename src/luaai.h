#pragma once
/*
 * Embedded Lua AI runtime — Phase 2B production lifecycle.
 * Owns the single LuaJIT state. Initialization is lazy, triggered from
 * mod_turn_upkeep: it must never run in DllMain's attach path, which holds
 * the Windows loader lock (file I/O and JIT activation there are UB).
 */

#include <cstdint>
#include <initializer_list>

// Versioned struct of function pointers exposed to Lua as a single
// lightuserdata (the `__host_api_ptr` global, cast by lua/ffi/funcs.lua).
// Bump api_version on any layout change; Lua asserts it before trusting the
// pointer. Entries beyond RNG are added on demand as each module needs
// them -- this set covers exactly what the tech-AI pilot's dependencies
// require (mod_tech_val/mod_tech_ai in src/tech.cpp), nothing broader.
//
// All of these are already-compiled Thinker C++ free functions (not raw
// engine-address calls), assigned here by pointer value in the same
// translation unit -- extern "C" is irrelevant for that (it only affects
// name-mangling for cross-TU symbol lookup, not calling convention), so
// no trampoline wrappers are needed, same as rand_game/rand_map.
struct LuaHostApi {
    uint32_t api_version;
    int32_t (*rand_game)(int32_t value);         // -> game_randv
    int32_t (*rand_map)(int32_t low, int32_t high); // -> random_get
    bool (*is_human)(int faction_id);
    int (*has_treaty)(int faction_id_1, int faction_id_2, uint32_t status);
    int (*climactic_battle)();
    int (*mod_wants_to_attack)(int faction_id, int faction_id_tgt, int faction_id_unk);
    int (*has_tech)(int tech_id, int faction_id);
    int (*tech_level)(int tech_id, int lvl);
    int (*mod_tech_avail)(int tech_id, int faction_id);
    int (*tech_is_preq)(int preq_tech_id, int parent_tech_id, int range);
    int (*bad_reg)(int region);
    bool (*revised_tech_cost)();
    int (*tech_balance_enabled)(); // -> conf.tech_balance
    // Social engineering (porting-order item 2, IMPLEMENTATION_DETAILS.md
    // 4.5): engine mechanics that stay C++, exposed read-only to the
    // social_score/mod_social_ai Lua port. models[4]/out_values[11]/cost
    // wrappers build/read a local CSocialCategory/CSocialEffect from a flat
    // int array -- see src/luaai.cpp for why that's safe (CSocialEffect's
    // values[11] union member).
    void (*social_calc)(const int32_t* models, int32_t faction_id, int32_t* out_values);
    int32_t (*society_avail)(int32_t sf, int32_t sm, int32_t faction_id);
    int32_t (*social_upheaval)(int32_t faction_id, const int32_t* models);
    bool (*has_project)(int32_t item_id, int32_t faction_id);
    bool (*has_free_facility)(int32_t item_id, int32_t faction_id);
    bool (*has_aircraft)(int32_t faction_id);
    int32_t (*mineral_factor)(int32_t faction_id, int32_t se_industry);
    bool (*un_charter)();
    int32_t (*defense_modifier)(int32_t faction_id); // -> plans[faction_id].defense_modifier
    int32_t (*keep_fungus)(int32_t faction_id);       // -> plans[faction_id].keep_fungus
    int32_t (*social_ai_bias)();                      // -> conf.social_ai_bias
    // War-decision port (porting-order item 2b, IMPLEMENTATION_DETAILS.md
    // 4.6): great_beelzebub/great_satan stay opaque (engine "who's the
    // dominant threat" heuristics, not the attack decision itself, same
    // precedent as social_calc); has_agenda is trivial but kept as a
    // wrapper for consistency with is_human/has_treaty; hq_region replaces
    // evaluate_attack's own Bases[]/has_fac_built/region_at scan so BASE
    // never needs FFI exposure for this port (deferred to item 3).
    int32_t (*great_beelzebub)(int32_t faction_id, int32_t is_aggressive);
    int32_t (*great_satan)(int32_t faction_id, int32_t is_aggressive);
    int32_t (*has_agenda)(int32_t faction_id_1, int32_t faction_id_2, uint32_t status);
    int32_t (*hq_region)(int32_t faction_id); // -1 if no HQ built
    // Production/plans port, first slice (porting-order item 3,
    // IMPLEMENTATION_DETAILS.md 4.7). bases_ptr returns Bases' current
    // value (not its address) -- Bases is a mutable, re-pointable global
    // (3.2, same category as Vehs), so lua/api/base.lua re-fetches this
    // on every access rather than caching a stale cast the way Factions/
    // MFactions (fixed addresses) are cached. mod_veh_avail/has_abil stay
    // opaque (eligibility/capability gates, not AI policy, see 4.7);
    // has_fac_built is generic (any facility, any base), unlike the
    // existing faction-level has_project/has_free_facility.
    int32_t (*bases_ptr)();
    int32_t (*mod_veh_avail)(int32_t unit_id, int32_t faction_id, int32_t base_id);
    int32_t (*has_abil)(int32_t unit_id, uint32_t ability);
    int32_t (*has_fac_built)(int32_t item_id, int32_t base_id);
    int32_t (*ignore_reactor_power)(); // -> conf.ignore_reactor_power
    int32_t (*long_range_artillery)(); // -> conf.long_range_artillery
    int32_t (*modify_unit_support)();  // -> conf.modify_unit_support
    int32_t (*psi_score)(int32_t faction_id);        // -> plans[faction_id].psi_score
    int32_t (*missile_units)(int32_t faction_id);     // -> plans[faction_id].missile_units
    int32_t (*median_limit)(int32_t faction_id);      // -> plans[faction_id].median_limit
    int32_t (*max_offense_value)(int32_t faction_id); // -> plans[faction_id].max_offense_value
    int32_t (*max_defense_value)(int32_t faction_id); // -> plans[faction_id].max_defense_value
    // Production/plans port, second slice (porting-order item 3,
    // IMPLEMENTATION_DETAILS.md 4.8). has_base_sites/is_ocean/map_range/
    // check_probe stay opaque because they reach into TileSearch/MAP/VEH,
    // none of which are open to Lua yet (plan 4.3: TileSearch/MAP stay in
    // C++ entirely; VEH is deferred to select_build itself).
    int32_t (*has_base_sites)(int32_t x, int32_t y, int32_t faction_id, int32_t triad);
    int32_t (*is_ocean)(int32_t base_id);
    int32_t (*map_range)(int32_t x1, int32_t y1, int32_t x2, int32_t y2);
    int32_t (*check_probe)(int32_t base_id, int32_t triad);
    int32_t (*has_wmode)(int32_t faction_id, int32_t mode);
    int32_t (*has_pact)(int32_t faction_id_1, int32_t faction_id_2);
    int32_t (*at_war)(int32_t faction_id_1, int32_t faction_id_2);
    int32_t (*best_reactor)(int32_t faction_id);
    int32_t (*expansion_autoscale)(); // -> conf.expansion_autoscale
    int32_t (*air_combat_units)(int32_t faction_id);   // -> plans[faction_id].air_combat_units
    int32_t (*transport_units)(int32_t faction_id);    // -> plans[faction_id].transport_units
    int32_t (*probe_units)(int32_t faction_id);        // -> plans[faction_id].probe_units
    int32_t (*sea_combat_units)(int32_t faction_id);   // -> plans[faction_id].sea_combat_units
    int32_t (*land_combat_units)(int32_t faction_id);  // -> plans[faction_id].land_combat_units
    int32_t (*contacted_factions)(int32_t faction_id); // -> plans[faction_id].contacted_factions
    // select_colony's own iterate_tiles(x,y,1,9) scan for a placeable land
    // tile (MAP fields veh_owner()/is_owned()/owner) -- found while
    // translating select_colony, not anticipated when this slice was
    // scoped (IMPLEMENTATION_DETAILS.md 4.8). Consumes RNG internally
    // (random(4)/random(8), conditionally, matching the original's
    // short-circuit exactly), so `land` is passed in rather than checked
    // Lua-side, to keep RNG consumption identical to the C++ original.
    int32_t (*ocean_colony_land_site)(int32_t base_id, int32_t land);
    // select_build itself (porting-order item 3, final piece,
    // IMPLEMENTATION_DETAILS.md 4.10.1). vehs_ptr mirrors bases_ptr:
    // Vehs is a mutable, re-pointable global (3.2), so lua/api/veh.lua
    // re-fetches this on every access rather than caching a stale cast.
    int32_t (*vehs_ptr)();
    // Phase 5.3.5 determinism diagnostics (IMPLEMENTATION_DETAILS.md):
    // read-only peeks at RNG state/draw counts, never consumed by these
    // calls themselves -- distinct from rand_game/rand_map above, which
    // both advance their stream. Folded into lua/harness/state_hash.lua's
    // per-turn line so a divergence between two runs' RNG state is visible
    // directly, without needing the state hash itself to differ yet.
    uint32_t (*game_rand_state)();
    uint32_t (*mod_rand_state)();     // -> random_state()
    uint32_t (*map_rand_state)();     // -> map_rand.get_state()
    uint32_t (*game_rand_draws)();    // -> g_game_rand_draws
    uint32_t (*mod_rng_draws)();      // -> g_mod_rng_draws
    uint32_t (*map_rng_draws)();      // -> g_map_rand_draws
    // select_build step 2 (IMPLEMENTATION_DETAILS.md 4.10.5/4.10.9,
    // resumed after the Consolidation gate): opaque engine-mechanics
    // wrappers push_item/has_retool/skip_facility need.
    int32_t (*mod_base_making)(int32_t item_id, int32_t base_id);
    int32_t (*skip_gov_facility_bit)(int32_t item_id);
    // select_build step 3 sub-step 1 (IMPLEMENTATION_DETAILS.md 4.10.9/
    // 4.10.12, resumed after the Consolidation gate): the shared
    // prologue through Wbase/Wthreat.
    int32_t (*region_at)(int32_t x, int32_t y);
    int32_t (*allow_expand)(int32_t faction_id);
    int32_t (*project_limit)(int32_t faction_id);
    int32_t (*main_region)(int32_t faction_id);
    int32_t (*target_land_region)(int32_t faction_id);
    int32_t (*enemy_bases)(int32_t faction_id);
    float (*enemy_mil_factor)(int32_t faction_id);
    float (*enemy_base_range)(int32_t faction_id);
    // select_build step 3 sub-step 2 (IMPLEMENTATION_DETAILS.md 4.10.9/
    // 4.10.13, resumed after the Consolidation gate): DefendUnit/
    // CombatUnit's early-return decision.
    int32_t (*need_scouts)(int32_t base_id, int32_t triad);
    int32_t (*has_ships)(int32_t faction_id);
    int32_t (*adjacent_region)(int32_t x, int32_t y, int32_t owner, int32_t threshold, int32_t ocean);
    // select_build step 3 sub-step 3 (IMPLEMENTATION_DETAILS.md 4.10.9/
    // 4.10.14, resumed after the Consolidation gate): the build_order
    // loop's per-item base score.
    int32_t (*can_build)(int32_t base_id, int32_t item_id);
    int32_t (*energy_limit)(int32_t faction_id);
    // select_build itself, facility-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.17): FAC_BIOLOGY_LAB's own branch
    // (build.cpp:1302-1306). conf is Thinker-internal, not FFI-mapped,
    // same pattern as tech_balance_enabled/social_ai_bias.
    int32_t (*biology_lab_bonus)(); // -> conf.biology_lab_bonus
    // select_build itself, facility-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.18): the shared FAC_RECREATION_
    // COMMONS/FAC_HOLOGRAM_THEATRE/FAC_RESEARCH_HOSPITAL/FAC_PARADISE_
    // GARDEN branch. Two-out-param shape kept as-is (same precedent as
    // social_calc's out_values array) rather than split into two
    // single-value wrappers -- content_pop/base_limit are computed
    // together from the same diff_level/MapAreaSqRoot inputs.
    void (*mod_psych_check)(int32_t faction_id, int32_t* content_pop, int32_t* base_limit);
    // select_build itself, facility-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.19): FAC_PSI_GATE's own branch,
    // same AIPlans-accessor pattern as main_region/target_land_region.
    int32_t (*naval_start_x)(int32_t faction_id); // -> plans[faction_id].naval_start_x
    int32_t (*naval_start_y)(int32_t faction_id); // -> plans[faction_id].naval_start_y
    // select_build itself, facility-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.22): FAC_CHILDREN_CRECHE's own
    // branch. Real engine mechanics (population-cap formula depending on
    // Rules/MFaction/has_fac_built), not AI policy -- same precedent as
    // mineral_output_modifier-style wrappers.
    int32_t (*base_unused_space)(int32_t base_id);
    // select_build itself, facility-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.23): FAC_TREE_FARM/FAC_HYBRID_
    // FOREST's shared branch. Pure tile-scan (path.cpp:369-380) over the
    // retained TableOffsetX/Y primitives -- stays in C++ per Phase 4.3,
    // same category as has_base_sites.
    int32_t (*nearby_items)(int32_t x, int32_t y, int32_t start_index, int32_t end_index, uint32_t item);
    // select_build itself, facility-branch catalog continued
    // (IMPLEMENTATION_DETAILS.md 4.10.24): the FAC_GENEJACK_FACTORY
    // group's shared branch. mineral_output_modifier aggregates several
    // facility/project checks (base.cpp:4358-4376) -- real engine
    // mechanics, not AI policy, same precedent as has_base_sites.
    // clean_minerals is Thinker-internal conf, not FFI-mapped, same
    // pattern as biology_lab_bonus.
    int32_t (*mineral_output_modifier)(int32_t base_id);
    int32_t (*clean_minerals)(); // -> conf.clean_minerals
    // select_build itself, unit-branch catalog (IMPLEMENTATION_DETAILS.md
    // 4.10.27): SeaProbeUnit's own AIPlans accessor.
    int32_t (*unknown_factions)(int32_t faction_id); // -> plans[faction_id].unknown_factions
    // Satellites branch, via find_satellite (build.cpp:286-330). Real
    // engine mechanics (facility/secret-project redundancy + faction
    // aliveness), not AI policy -- same precedent as has_base_sites.
    int32_t (*has_facility)(int32_t item_id, int32_t base_id);
    int32_t (*is_alive)(int32_t faction_id);
    int32_t (*enemy_odp)(int32_t faction_id);      // -> plans[faction_id].enemy_odp
    int32_t (*enemy_sat)(int32_t faction_id);      // -> plans[faction_id].enemy_sat
    int32_t (*satellite_goal_setting)(int32_t faction_id); // -> plans[faction_id].satellite_goal
    int32_t (*max_satellites)(); // -> conf.max_satellites
    // select_build itself, unit-branch catalog continued (IMPLEMENTATION_
    // DETAILS.md 4.10.28): faction_might, via find_project's SecretProject
    // branch.
    int32_t (*mil_strength)(int32_t faction_id); // -> plans[faction_id].mil_strength
    // select_build itself, unit-branch catalog continued (IMPLEMENTATION_
    // DETAILS.md 4.10.29): FormerUnit's own tile-quality tally
    // (build.cpp:1157-1166). Kept as one opaque wrapper reproducing the
    // whole iterate_tiles/select_item/is_ocean scan in C++, rather than
    // porting select_item's own ~200-line terraform-choice logic (and the
    // dozen tile-eligibility primitives it depends on) to Lua -- within
    // select_build, select_item's return value is only ever used as a
    // >=0 eligibility check, never scored; the specific terraform action
    // it picks only matters later, in former_move (Phase 4.2 item 4,
    // Movement, not yet ported), which is where select_item would
    // actually need porting as AI policy. Same "engine mechanics" bucket
    // as has_base_sites (which wraps an analogous iterate_tiles scan for
    // select_colony, 4.8) -- raw pointers (MAP*, the tile iterator) never
    // cross into Lua either way.
    void (*former_tile_tally)(int32_t base_id, int32_t* num, int32_t* sea);
    // select_build itself, step 4 (IMPLEMENTATION_DETAILS.md 4.10):
    // allow_units's own can_build_unit(base_id, -1) call reduces to a
    // single conf.max_veh_num-gated expression for unit_id == -1 -- see
    // src/luaai.cpp's host_max_veh_num for why only this one conf field
    // needs a wrapper, not the whole function.
    int32_t (*max_veh_num)(); // -> conf.max_veh_num
    // Movement port, stage 1 (IMPLEMENTATION_DETAILS.md 4.12):
    // artifact_move's own dependencies. base_at/can_link_artifact are
    // plain read queries; map_safety reads mapdata (PMTable, a
    // std::unordered_map -- stays entirely in C++ per Phase 4.3, exposed
    // only as this one-field read, same tier as former_tile_tally's
    // opaque tile scan). search_route wraps its own local TileSearch
    // (also stays in C++) and returns via 3 out-params (found/tx/ty),
    // same shape as mod_psych_check/former_tile_tally.
    int32_t (*base_at)(int32_t x, int32_t y);
    int32_t (*can_link_artifact)(int32_t base_id);
    int32_t (*map_safety)(int32_t x, int32_t y);
    // x/y seed the search (the vehicle's current position, matching the
    // C++ call sites' own `int tx = veh->x; int ty = veh->y;` before
    // calling search_route) -- tx/ty are updated in place only if found.
    void (*search_route)(int32_t veh_id, int32_t x, int32_t y,
        int32_t* found, int32_t* tx, int32_t* ty);
    // Mutating wrappers (IMPLEMENTATION_PLAN.md Phase 3's read/write
    // asymmetry: the first ever needed, since every wrapper before this
    // phase was a pure read). Each sets g_mutation_issued (src/luaai.cpp)
    // as its first action -- see lua_ai_command_hook for why.
    int32_t (*mod_study_artifact)(int32_t veh_id);
    int32_t (*set_move_to)(int32_t veh_id, int32_t x, int32_t y);
    int32_t (*mod_veh_skip)(int32_t veh_id);
    // Movement port, stage 2 (IMPLEMENTATION_DETAILS.md 4.12):
    // crawler_move's own dependencies. The first two wrap whole decision
    // blocks (move.cpp:1229-1239/1240-1246) rather than exposing their
    // individual MAP-tile/VEH-field touches piecemeal (sq->is_base()/
    // ->owner, a direct veh->order write) -- both blocks are eligibility/
    // bookkeeping with no real AI judgment in them, same tier as
    // former_tile_tally. applicable=0 means "guard condition was false,
    // continue with the rest of crawler_move normally"; applicable!=0
    // means the whole block ran and `action` is the final return value.
    void (*crawler_home_base_check)(int32_t veh_id, int32_t* applicable, int32_t* action);
    void (*crawler_at_target_check)(int32_t veh_id, int32_t* applicable, int32_t* action);
    void (*mark_convoy_site)(int32_t x, int32_t y);
    int32_t (*set_convoy)(int32_t veh_id, int32_t res);
    int32_t (*move_to_base)(int32_t veh_id, int32_t ally);
    // Movement port, stage 2 rework (IMPLEMENTATION_DETAILS.md 4.12,
    // 2026-07-21): want_convoy's scoring formula is real AI policy --
    // crawlers are the game's single biggest economic lever and the
    // project's stated priority area, so the formula itself now lives
    // in Lua (lua/ai/move.lua), not behind an opaque wrapper. Only the
    // genuine engine mechanics it depends on stay as thin wrappers:
    // the three yield calculators, and single-field tile reads (MAP*
    // can't cross the FFI boundary, so these substitute for it, same
    // tier as map_safety/base_at).
    int32_t (*mod_crop_yield)(int32_t faction_id, int32_t base_id, int32_t x, int32_t y, int32_t flag);
    int32_t (*mod_mine_yield)(int32_t faction_id, int32_t base_id, int32_t x, int32_t y, int32_t flag);
    int32_t (*mod_energy_yield)(int32_t faction_id, int32_t base_id, int32_t x, int32_t y, int32_t flag);
    int32_t (*tile_is_base)(int32_t x, int32_t y);
    int32_t (*tile_owner)(int32_t x, int32_t y); // -1 if unowned
    int32_t (*tile_is_base_radius)(int32_t x, int32_t y);
    // faction.cpp:70-74, a one-line SecretProjects[] array lookup -- the
    // array itself isn't otherwise worth exposing for one call site.
    int32_t (*project_base)(int32_t item_id);
    // The TileSearch scan (move.cpp:1253-1275) as an incremental
    // iterator instead of one opaque "whole scan" call: TileSearch still
    // never crosses into Lua (Phase 4.3, it lives in a static C++ local
    // between calls), but Lua now drives the loop and scores each
    // candidate itself via the real (Lua) want_convoy, so the "which
    // tile is best" judgment is genuinely in Lua, not baked into the
    // host wrapper. crawler_search_next applies the same safety/ally/
    // convoy-site filters the original loop's `continue` did, and
    // respects the original `limit` bound internally (a static counter,
    // reset by crawler_search_start) -- it only ever returns candidates
    // that passed those filters, one per call, until exhausted.
    void (*crawler_search_start)(int32_t veh_id, int32_t limit);
    void (*crawler_search_next)(int32_t faction_id, int32_t* valid,
        int32_t* tx, int32_t* ty, int32_t* dist);
    // Movement port, stage 3 (IMPLEMENTATION_DETAILS.md 4.12):
    // escape_score's own dependencies (used by escape_move/search_escape/
    // search_base, all needed by colony_move). Single-field tile reads,
    // same tier as map_safety -- MAP* still can't cross the FFI boundary.
    int32_t (*map_target)(int32_t x, int32_t y);
    uint32_t (*tile_items)(int32_t x, int32_t y);
    int32_t (*tile_is_rocky)(int32_t x, int32_t y);
    int32_t (*has_map_node)(int32_t x, int32_t y, int32_t node_type);
    void (*mark_map_node)(int32_t x, int32_t y, int32_t node_type);
    int32_t (*veh_need_monolith)(int32_t veh_id);
    int32_t (*veh_need_refuel)(int32_t veh_id);
    int32_t (*veh_speed)(int32_t veh_id, int32_t skip_morale);
    int32_t (*allow_move)(int32_t x, int32_t y, int32_t faction_id, int32_t triad);
    int32_t (*non_ally_in_tile)(int32_t x, int32_t y, int32_t faction_id);
    int32_t (*defend_tile)(int32_t veh_id);
    int32_t (*set_order_none)(int32_t veh_id);
    // search_escape (move.cpp/path.cpp originals: escape_move/search_base
    // also feed it) as an incremental iterator, same start/next shape as
    // crawler_search_*. escape_score itself is pure Lua now (lua/ai/move.lua).
    void (*search_escape_start)(int32_t veh_id);
    void (*search_escape_next)(int32_t faction_id, int32_t* valid,
        int32_t* tx, int32_t* ty, int32_t* dist);
    // search_base: `already_there` (1 = standing on a valid base already,
    // matching the C++ original's own early "return 0" case) or 0 with
    // `max_dist` set to proceed to search_base_next. `found`, passed in by
    // Lua on every _next call, mirrors the C++ local of the same name --
    // once Lua has accepted a friendly-base match, non-base candidates
    // stop being returned (kind=2), matching move.cpp's own `!found` gate.
    // kind: 0 = exhausted, 1 = friendly base found (tx/ty set, Lua decides
    // whether to keep searching, same random(2)/triad==AIR break rule as
    // the original), 2 = eligible non-base candidate (tx/ty/dist set, Lua
    // scores it with escape_score).
    void (*search_base_start)(int32_t veh_id, int32_t ally,
        int32_t* already_there, int32_t* max_dist);
    void (*search_base_next)(int32_t faction_id, int32_t triad, int32_t ally, int32_t found,
        int32_t* kind, int32_t* tx, int32_t* ty, int32_t* dist);
    // base_tile_score's own dependencies (colony_move's site-scoring
    // formula). Same single-field-read tier as the escape_score set above.
    int32_t (*tile_alt_level)(int32_t x, int32_t y);
    int32_t (*tile_bonus)(int32_t x, int32_t y); // -> engine's bonus_at()
    uint32_t (*tile_lm_items)(int32_t x, int32_t y);
    int32_t (*tile_is_land_region)(int32_t x, int32_t y);
    int32_t (*tile_region)(int32_t x, int32_t y);
    int32_t (*tile_is_rainy)(int32_t x, int32_t y);
    int32_t (*tile_is_moist)(int32_t x, int32_t y);
    int32_t (*tile_is_rolling)(int32_t x, int32_t y);
    int32_t (*both_non_enemy)(int32_t faction_id_1, int32_t faction_id_2);
    int32_t (*ocean_coast_tiles)(int32_t x, int32_t y);
    // colony_move's own remaining dependencies, beyond base_tile_score/
    // escape_score. can_build_base/near_ocean_coast/has_transport/
    // allow_civ_move/can_airdrop/allow_airdrop/invasion_unit are pure
    // eligibility facts (no scoring/comparison among alternatives), same
    // tier as check_probe/has_base_sites (4.8). action_airdrop/
    // mod_veh_kill/net_action_build are mutators. connect_roads
    // constructs its own local TileSearch (like search_route) and is a
    // pure road-planning mechanic, not AI choice.
    int32_t (*can_build_base)(int32_t x, int32_t y, int32_t faction_id, int32_t triad);
    int32_t (*near_ocean_coast)(int32_t x, int32_t y);
    int32_t (*has_transport)(int32_t x, int32_t y, int32_t faction_id);
    int32_t (*allow_civ_move)(int32_t x, int32_t y, int32_t faction_id, int32_t triad);
    int32_t (*can_airdrop)(int32_t veh_id);
    int32_t (*drop_range)(int32_t faction_id);
    int32_t (*allow_airdrop)(int32_t x, int32_t y, int32_t faction_id, int32_t combat);
    int32_t (*action_airdrop)(int32_t veh_id, int32_t tx, int32_t ty, int32_t flags);
    int32_t (*mod_veh_kill)(int32_t veh_id);
    int32_t (*path_cost)(int32_t x1, int32_t y1, int32_t x2, int32_t y2,
        int32_t unit_id, int32_t faction_id, int32_t max_cost);
    int32_t (*invasion_unit)(int32_t veh_id);
    int32_t (*net_action_build)(int32_t veh_id);
    void (*connect_roads)(int32_t x, int32_t y, int32_t faction_id);
    // colony_move's own site-selection scan (move.cpp:1454-1484), the
    // real "which tile is the best colony site" judgment -- same
    // incremental iterator shape as crawler_search_*/search_escape_*,
    // scoring each candidate in Lua with the (now-Lua) base_tile_score.
    // airdrop/invasion-specific search origin and the safe_path/airdrop-
    // range filters stay host-side (TileSearch-internal state), matching
    // crawler_search_next's own precedent. _start computes and returns
    // airdrop (the drop range if can_airdrop, else 0 -- matching
    // move.cpp:1453's own `int airdrop = can_airdrop(...) ? drop_range(...)
    // : 0;`), veh_region and triad, since Lua needs to pass all three
    // back into every _next call.
    void (*colony_search_start)(int32_t veh_id, int32_t skip_owner,
        int32_t* airdrop, int32_t* veh_region, int32_t* triad);
    void (*colony_search_next)(int32_t faction_id, int32_t triad, int32_t skip_owner,
        int32_t airdrop, int32_t veh_region,
        int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist);
    // base_tile_score's own 21-neighbor scan (move.cpp:1355,
    // `iterate_tiles(x, y, 0, 21)`). iterate_tiles itself is a fixed
    // TableOffsetX/Y ring-index table plus map-edge wrapping -- pure
    // geometry, not judgment (same tier as TileSearch) -- so this wrapper
    // only resolves index `i` to real, wrapped, on-map coordinates (or
    // reports invalid at the map edge); Lua drives the i=0..20 loop and
    // scores each neighbor with the tile_* fact wrappers above.
    int32_t (*tile_neighbor)(int32_t x, int32_t y, int32_t i, int32_t* tx, int32_t* ty);
    // colony_move's own site-radius mark / automation flags / ocean-
    // transport branch / site-visibility fact -- see src/luaai.cpp's
    // comments on each for why they stay opaque (mechanical, no scoring).
    void (*mark_base_site_radius)(int32_t x, int32_t y);
    void (*set_colony_automation_flags)(int32_t veh_id);
    void (*colony_transport_check)(int32_t veh_id, int32_t* has_transport,
        int32_t* tx, int32_t* ty);
    int32_t (*tile_is_visible)(int32_t x, int32_t y, int32_t faction_id);
    // Movement port, route_score sub-stage (IMPLEMENTATION_DETAILS.md
    // 4.12): resolving the "route_score baked into an opaque search_route
    // wrapper" defect flagged when colony_move was audited. route_score
    // itself and both plain Bases[] scans that consume it move to Lua
    // (lua/ai/move.lua) this sub-stage; the three TileSearch-driven scans
    // (sea-triad branch, general territory-pact branch, naval-pickup-point
    // search) are deferred to a following sub-stage. tile_is_ocean mirrors
    // the tile_is_base/tile_owner tier (MAP* can't cross the FFI boundary,
    // this is the coordinate overload of is_ocean, distinct from the
    // existing BASE-overload wrapper of the same C++ name); can_use_teleport
    // is a boolean gate (Psi Gate charge availability), same tier as
    // has_fac_built; net_action_gate is the actual teleport action.
    int32_t (*tile_is_ocean)(int32_t x, int32_t y);
    int32_t (*can_use_teleport)(int32_t base_id);
    int32_t (*net_action_gate)(int32_t veh_id, int32_t base_id);
    // Movement port, route_score sub-stage B (IMPLEMENTATION_DETAILS.md
    // 4.12): the three TileSearch-driven scans deferred from sub-stage A,
    // assembling the full search_route replacement. main_region_x/y (the
    // TRIAD_AIR branch) and naval_end_x/y (the TRIAD_SEA branch's score
    // adjustment) are AIPlans accessors, same tier as main_region/
    // naval_start_x. tile_is_fungus is a MAP method (not a bare items&
    // check -- it also gates on alt_level()), same tier as tile_is_rocky.
    // cargo_capacity aggregates veh_cargo/veh_cargo_loaded (genuine
    // chassis/cargo engine formulas, not AI policy), kept opaque like
    // mineral_output_modifier.
    int32_t (*main_region_x)(int32_t faction_id);
    int32_t (*main_region_y)(int32_t faction_id);
    int32_t (*naval_end_x)(int32_t faction_id);
    int32_t (*naval_end_y)(int32_t faction_id);
    int32_t (*tile_is_fungus)(int32_t x, int32_t y);
    int32_t (*cargo_capacity)(int32_t x, int32_t y, int32_t faction_id);
    // route_search_sea_*: TRIAD_SEA branch's own-base scan (path.cpp:
    // 707-732). The original's is_base+owner / safe_path(dist<8) /
    // map_range-to-naval_end filters are mechanical facts with no scoring
    // (equivalent to computing route_score and discarding, since none
    // have side effects) -- folded host-side exactly like
    // search_escape_next/search_base_next already do. route_score itself
    // and the invade-adjustment/best-tracking/dist>=25 break stay in Lua.
    void (*route_search_sea_start)(int32_t veh_id);
    void (*route_search_sea_next)(int32_t faction_id,
        int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist);
    // route_search_pact_*: the general territory-pact scan (path.cpp:
    // 757-793). Unlike the sea scan, this one has two genuinely different
    // candidate kinds per tile (a naval-pick early-exit-with-RNG special
    // case, and a scoreable base candidate) that can BOTH apply to the
    // same tile (the original's own fallthrough when the naval-pick
    // RNG check doesn't fire) -- so both facts are reported every time a
    // tile matches either, rather than collapsing to one mutually-
    // exclusive "kind". naval_pick/is_base_safe are 0/1; combat/scout are
    // passed in (Lua already computed them for the outer function) rather
    // than recomputed host-side, so there is one source of truth.
    void (*route_search_pact_start)(int32_t veh_id);
    void (*route_search_pact_next)(int32_t faction_id, int32_t combat, int32_t scout,
        int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist,
        int32_t* naval_pick, int32_t* is_base_safe);
    // route_search_naval_seed: the naval-pickup-point search's own seed-
    // building scan (path.cpp:817-835) -- a "does the search reach my own
    // position" mechanic (first-match wins, no scoring) that also
    // collects ocean tiles into the point list the next scan seeds from.
    // Kept as one opaque wrapper, same tier as has_base_sites/
    // colony_transport_check. redirect=1 means the original's own early
    // "already close enough by land, go straight there" return fired;
    // tx/ty are px/py themselves in that case (not the search position),
    // matching the original's own *tx=px;*ty=py.
    void (*route_search_naval_seed)(int32_t veh_id, int32_t px, int32_t py,
        int32_t* redirect, int32_t* tx, int32_t* ty);
    // route_search_naval_pickup_*: the real scoring scan (path.cpp:
    // 838-860) that walks the search tree's parent chain -- the one place
    // in this sub-stage TileSearch-internal state (get_prev()) has no
    // Lua-side substitute. Bare walk plus the one fact Lua can't get any
    // other way (prev_x/prev_y); every other input to the scoring formula
    // is already exposed as an atomic tile fact.
    void (*route_search_naval_pickup_start)();
    void (*route_search_naval_pickup_next)(
        int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist,
        int32_t* prev_x, int32_t* prev_y);
    // add_goal: generic AI goal creation (src/goal.cpp), needed here for
    // the naval-pickup branch's AI_GOAL_NAVAL_PICK -- ahead of goal.cpp's
    // own stage (Movement stage 7), reused there later. Mutating.
    void (*add_goal)(int32_t faction_id, int32_t type, int32_t priority,
        int32_t x, int32_t y, int32_t base_id);
    // former_move port, sub-stage 1 (IMPLEMENTATION_DETAILS.md 4.13): the
    // 12 can_*/keep_fungus/plant_fungus tile-eligibility helpers ported to
    // Lua, plus the engine-mechanics primitives they depend on.
    // has_terra wraps terrain_avail -- a genuine faction-level tech/
    // reactor eligibility gate (same tier as has_fac_built), not AI
    // policy, even though it's called from what IS AI policy below.
    int32_t (*has_terra)(int32_t item_id, int32_t ocean, int32_t faction_id);
    // coast_tiles/both_neutral: plain engine queries, no scoring.
    int32_t (*coast_tiles)(int32_t x, int32_t y);
    int32_t (*both_neutral)(int32_t faction_id_1, int32_t faction_id_2);
    // map_former/map_roads: PInfo fields (mapdata, a std::unordered_map --
    // stays entirely in C++ per Phase 4.3), same tier as map_target/
    // map_safety.
    int32_t (*map_former)(int32_t x, int32_t y);
    int32_t (*map_roads)(int32_t x, int32_t y);
    // tile_near8: can_road's own 8-direction NearbyTiles[] ring (distinct,
    // smaller table from the 21-tile TableOffsetX/Y ring tile_neighbor
    // already resolves) -- same "pure geometry, not judgment" tier and
    // shape as tile_neighbor, just a different fixed table.
    int32_t (*tile_near8)(int32_t x, int32_t y, int32_t i, int32_t* tx, int32_t* ty);
    // tile_output_limit_nutrient: conf.tile_output_limit[0], Thinker-
    // internal Config array, same pattern as max_veh_num/biology_lab_bonus.
    int32_t (*tile_output_limit_nutrient)();
    // can_bridge (path.cpp:1530-1566) stays fully opaque, unlike its 12
    // siblings: it couples a bounded TileSearch scan (used only to build
    // an oldtiles set, no per-candidate scoring) with a territory-conflict
    // check (compare_might) -- a structural eligibility gate with no
    // comparison-among-candidates judgment in it, same tier as
    // has_base_sites, not real AI policy the way select_item's own choice
    // among the ported can_* results is.
    int32_t (*can_bridge)(int32_t x, int32_t y, int32_t faction_id);
    // plant_fungus_flag/build_tubes: AIPlans accessors, same tier as the
    // existing keep_fungus accessor (plant_fungus_flag is named to avoid
    // colliding with lua/ai/move.lua's own ported plant_fungus function).
    int32_t (*plant_fungus_flag)(int32_t faction_id);
    int32_t (*build_tubes)(int32_t faction_id);
    // former_move port, sub-stage 2 (IMPLEMENTATION_DETAILS.md 4.13):
    // select_item's own remaining dependencies, beyond the 12 can_*
    // helpers it combines. tile_is_volcano_center is a MAP method, same
    // tier as tile_is_fungus. terraform_cost/item_yield/bonus_yield are
    // real engine yield-calculation formulas (item_yield especially --
    // a long landmark/social-engineering-dependent computation), same
    // "engine mechanics, not AI policy" tier as the already-opaque
    // mod_crop_yield/mod_mine_yield/mod_energy_yield -- select_item's own
    // judgment is which terraform action to pick given these values, not
    // how the values themselves are computed. total_yield needs no new
    // wrapper: it's just mod_crop_yield+mod_mine_yield+mod_energy_yield,
    // all three already exposed, summed directly in Lua.
    int32_t (*tile_is_volcano_center)(int32_t x, int32_t y);
    int32_t (*terraform_cost)(int32_t x, int32_t y, int32_t faction_id);
    int32_t (*item_yield)(int32_t x, int32_t y, int32_t faction_id, int32_t bonus, int32_t item);
    int32_t (*bonus_yield)(int32_t res_type);
    // former_move port, sub-stage 4 (IMPLEMENTATION_DETAILS.md 4.13):
    // former_move itself. former_search_*: the vehicle's own-triad
    // TileSearch scan (move.cpp:2150-2176) -- a bare walk (unlike most
    // prior iterators, no host-side filtering at all): every filter
    // condition in the original is already an atomic fact Lua can read
    // itself (tile_is_base/tile_owner/map_roads/map_former/map_safety/
    // non_ally_in_tile/map_range), so there is no "mechanical, no
    // judgment" residue left to keep host-side, unlike route_search_
    // sea_next's is_base+safe_path+map_range filters. former_consume/
    // former_apply_action/former_request_new_orders are mutating:
    // former_consume is the plain `mapdata[{x,y}].former -= 2` bookkeeping
    // (used at the "move to a chosen candidate tile" call site);
    // former_apply_action bundles the "execute the chosen item right
    // now" sequence (own-tile former decrement + conditional
    // terraform_cost/energy_credits deduction + set_action) since none
    // of those three steps is a separate AI decision -- item itself was
    // already chosen by Lua's own select_item call before this is
    // invoked. former_request_new_orders is the FM_Farm_Road/FM_Mine_Road
    // branch's veh->state/order writes, same tier as
    // set_colony_automation_flags (direct field writes can't cross the
    // FFI read-only boundary any other way).
    void (*former_search_start)(int32_t veh_id);
    void (*former_search_next)(int32_t* valid, int32_t* tx, int32_t* ty);
    void (*former_consume)(int32_t x, int32_t y);
    int32_t (*former_apply_action)(int32_t veh_id, int32_t item);
    void (*former_request_new_orders)(int32_t veh_id);
    // trans_move port, sub-stage 1 (IMPLEMENTATION_DETAILS.md 4.14):
    // near_landing/make_landing's own dependencies. reg_enemy_at queries
    // region_probe/region_enemy, two move.cpp-internal containers
    // populated by move_upkeep (not yet ported, movement stage 7) --
    // pure precomputed-fact lookup, not AI policy, kept opaque.
    int32_t (*reg_enemy_at)(int32_t region, int32_t is_probe);
    // trans_move port, sub-stage 2 (IMPLEMENTATION_DETAILS.md 4.14):
    // trans_move itself. veh_cargo/veh_need_heals/goody_at/allow_scout
    // are genuine engine mechanics (chassis cargo formula, damage/repair
    // eligibility, map pod presence, a scouting-eligibility gate that
    // itself consumes RNG) -- same "engine mechanics, not AI policy"
    // tier as has_base_sites/allow_move, kept opaque. tile_veh_who/
    // map_unit_near are single-field tile facts, same tier as
    // tile_owner/map_target. choose_defender/battle_priority stay
    // opaque -- confirmed (4.14's own classification note) to belong to
    // combat_move's own family (movement stage 6), not trans_move's;
    // trans_move's real judgment is the surrounding decision of
    // whether/where to attack, not the odds formula itself.
    int32_t (*veh_cargo)(int32_t veh_id);
    int32_t (*veh_need_heals)(int32_t veh_id);
    void (*veh_wake)(int32_t veh_id);
    int32_t (*unmark_map_node)(int32_t x, int32_t y, int32_t node_type);
    void (*set_board_to)(int32_t veh_id, int32_t trans_veh_id);
    int32_t (*tile_veh_who)(int32_t x, int32_t y);
    int32_t (*map_unit_near)(int32_t x, int32_t y);
    int32_t (*choose_defender)(int32_t x, int32_t y, int32_t veh_id_atk);
    double (*battle_priority)(int32_t veh_id_atk, int32_t veh_id_def, int32_t dist, int32_t moves,
        int32_t x, int32_t y);
    int32_t (*goody_at)(int32_t x, int32_t y);
    int32_t (*allow_scout)(int32_t faction_id, int32_t x, int32_t y);
    // trans_move's own TileSearch scan (move.cpp:2583-2669): a bare
    // walk, same reasoning as former_search_next -- every filter
    // condition the original applies (is_base, owner, is_ocean,
    // allow_move) is already an atomic fact exposed to Lua.
    void (*trans_search_start)(int32_t veh_id);
    void (*trans_search_next)(int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist);
    // combat_move port, sub-stage A (IMPLEMENTATION_DETAILS.md 4.15):
    // engine surface for cover_score/target_priority/flank_score/
    // teleport_score/allow_conv_missile. map_enemy/map_enemy_near/
    // map_enemy_dist extend the map_target/map_roads/map_unit_near/
    // map_safety/map_former PMTable-field-accessor family (same "opaque
    // std::unordered_map, one field at a time" tier). is_objective wraps
    // an engine __cdecl call (base.h:62), same tier as has_fac_built.
    // veh_high_damage extends the veh_need_heals/veh_need_refuel family
    // (a VEH-instance-level derived boolean, not AI policy). enemy_factions
    // extends the contacted_factions/land_combat_units AIPlans single-field
    // accessor family.
    int32_t (*map_enemy)(int32_t x, int32_t y);
    int32_t (*map_enemy_near)(int32_t x, int32_t y);
    int32_t (*map_enemy_dist)(int32_t x, int32_t y);
    int32_t (*is_objective)(int32_t base_id);
    int32_t (*veh_high_damage)(int32_t veh_id);
    int32_t (*enemy_factions)(int32_t faction_id);
    // combat_move port, sub-stage B (IMPLEMENTATION_DETAILS.md 4.15):
    // airdrop_move + allow_airdrop's own dependencies not already
    // covered by sub-stage A. mod_stack_check (veh.cpp:2499) is a
    // generic multi-purpose stack inspector used with cryptic magic-
    // number args in dozens of engine call sites -- kept opaque, same
    // "not AI policy" precedent as mod_veh_avail/great_beelzebub.
    // mod_zoc_move/veh_at are single-purpose engine mechanics, same
    // tier. map_target_incr is the `mapdata[{x,y}].target++`
    // bookkeeping mutator, same shape as former_consume.
    int32_t (*mod_stack_check)(int32_t veh_id, int32_t type, int32_t cond1, int32_t cond2,
        int32_t cond3);
    int32_t (*mod_zoc_move)(int32_t x, int32_t y, int32_t faction_id);
    int32_t (*has_orbital_drops)(int32_t faction_id);
    int32_t (*veh_at)(int32_t x, int32_t y);
    void (*map_target_incr)(int32_t x, int32_t y);
    // combat_move port, remaining engine surface (IMPLEMENTATION_
    // DETAILS.md 4.15): lands every host-API entry the full function
    // still needs beyond sub-stages A/B, ahead of assembling the
    // function itself -- same "engine surface before the dispatcher"
    // sequencing as every prior mover, just split out as its own step
    // here because combat_move's ~726 loc don't fit one sitting.
    // map_enemy_rank/map_flags extend the map_enemy/map_enemy_near/
    // map_enemy_dist PMTable family (sub-stage A). can_arty/arty_range/
    // tile_is_airbase/veh_mid_damage are single-purpose engine facts,
    // same tier as veh_high_damage/veh_need_heals. update_move_path/
    // net_action_destroy/mod_battle_fight/probe_action are mutators
    // (probe_action wraps probe.cpp's own `probe()` -- porting-order
    // item 5, kept opaque, same precedent as evaluate_attack calling
    // into an unported neighbor domain). combat_search_start/_next is a
    // *generic*, re-initializable TileSearch iterator -- unlike every
    // prior mover's single-purpose search pair (crawler_search_*,
    // colony_search_*, ...), combat_move re-inits and re-scans the same
    // TileSearch object under several different ts_type values within
    // one call, so the type is a runtime parameter here, not baked into
    // the wrapper. _next's prev_x/prev_y follow the route_search_naval_
    // pickup_next precedent (4.12) for exposing "the matched node's
    // path-parent coordinates" without exposing the raw PathNode array/
    // index to Lua. combat_search_has_zoc wraps TileSearch::has_zoc().
    int32_t (*map_enemy_rank)(int32_t x, int32_t y);
    int32_t (*map_flags)(int32_t x, int32_t y);
    int32_t (*can_arty)(int32_t unit_id, int32_t arty);
    int32_t (*arty_range)(int32_t unit_id);
    // combat_move port, sub-stage D (IMPLEMENTATION_DETAILS.md 4.15):
    // TableRange[] (path.h) is a plain const int[9] lookup table -- not a
    // struct field gen_ffi can emit and not worth exposing as a raw array
    // (the only call site is `TableRange[arty_range(unit_id)]`), so this
    // wrapper folds both steps into one, same "engine mechanic" tier as
    // can_arty/arty_range themselves.
    int32_t (*arty_table_range)(int32_t unit_id);
    int32_t (*tile_is_airbase)(int32_t x, int32_t y);
    int32_t (*veh_mid_damage)(int32_t veh_id);
    void (*update_move_path)(int32_t veh_id, int32_t tx, int32_t ty);
    int32_t (*net_action_destroy)(int32_t veh_id, int32_t flag, int32_t x, int32_t y);
    int32_t (*mod_battle_fight)(int32_t veh_id, int32_t offset, int32_t table_offset,
        int32_t option);
    int32_t (*probe_action)(int32_t veh_id, int32_t tgt_base_id, int32_t tgt_veh_id, int32_t toggle);
    // combat_move port, sub-stage D correction (IMPLEMENTATION_DETAILS.md
    // 4.15): sub-stage C's combat_search_start only wrapped TileSearch's
    // 3-arg init() overload, but combat_move's own final base-search scan
    // (move.cpp:3538) needs the 4-arg overload's ts_skip parameter ("skip
    // pole tiles" for TRIAD_LAND). Found while translating the function
    // body itself -- every other call site already behaves identically
    // passing ts_skip=0, since TileSearch::reset() (called by both init()
    // overloads) always zeroes y_skip first regardless.
    void (*combat_search_start)(int32_t veh_id, int32_t ts_type, int32_t ts_skip);
    void (*combat_search_next)(int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist,
        int32_t* prev_x, int32_t* prev_y);
    int32_t (*combat_search_has_zoc)(int32_t faction_id);
    int32_t (*main_sea_region)(int32_t faction_id);
    int32_t (*naval_airbase_x)(int32_t faction_id);
    int32_t (*naval_airbase_y)(int32_t faction_id);
    int32_t (*naval_scout_x)(int32_t faction_id);
    int32_t (*naval_scout_y)(int32_t faction_id);
    int32_t (*prioritize_naval)(int32_t faction_id);

    // Movement stage 7A (IMPLEMENTATION_DETAILS.md 4.16): land_raise_plan/
    // invasion_plan/update_main_region are the first Lua code to *write*
    // AIPlans fields -- every accessor above this point is read-only.
    // naval_beach_x/y had no getter yet either (nothing needed it before
    // combat_move); added here alongside its setter for symmetry with its
    // naval_start/naval_end/naval_airbase/naval_scout siblings.
    int32_t (*naval_beach_x)(int32_t faction_id);
    int32_t (*naval_beach_y)(int32_t faction_id);
    // Coordinate-pair fields are set together at every call site in the
    // C++ source (never independently), so one setter per pair rather than
    // per scalar -- same spirit as the one-field-per-wrapper rule, just at
    // the granularity the source itself actually uses.
    void (*set_main_region)(int32_t faction_id, int32_t region, int32_t x, int32_t y);
    void (*set_main_sea_region)(int32_t faction_id, int32_t region);
    void (*set_target_land_region)(int32_t faction_id, int32_t region);
    void (*set_prioritize_naval)(int32_t faction_id, int32_t value);
    void (*set_naval_scout)(int32_t faction_id, int32_t x, int32_t y);
    void (*set_naval_airbase)(int32_t faction_id, int32_t x, int32_t y);
    void (*set_naval_start)(int32_t faction_id, int32_t x, int32_t y);
    void (*set_naval_end)(int32_t faction_id, int32_t x, int32_t y);
    void (*set_naval_beach)(int32_t faction_id, int32_t x, int32_t y);
    // (Continents[] was already exposed directly, lua/api/map.lua's
    // `map.continent(region)` -- no new wrapper needed for it here.)

    // land_raise_plan/invasion_plan/update_main_region's own TileSearch
    // scans (move.cpp, IMPLEMENTATION_DETAILS.md 4.16). Same file-local-
    // static-TileSearch start/next pattern as combat_search_*
    // (IMPLEMENTATION_DETAILS.md 3.3) but a distinct instance: faction-
    // level planning runs strictly sequentially with movement dispatch
    // (never interleaved, same assumption g_mutation_issued already
    // relies on), so a second static TileSearch is safe. Two start
    // overloads because both a single origin point (update_main_region)
    // and a caller-built point list (land_raise_plan's second scan,
    // invasion_plan) are real call shapes in the source -- ts_dist<0 means
    // "use the 3-arg init()" the same way the two real C++ overloads
    // differ only in whether ts_skip is passed.
    void (*region_search_start)(int32_t x, int32_t y, int32_t ts_type, int32_t ts_dist);
    void (*region_search_start_multi)(int32_t count, int32_t* xs, int32_t* ys,
        int32_t ts_type, int32_t ts_dist);
    void (*region_search_next)(int32_t* valid, int32_t* tx, int32_t* ty, int32_t* dist,
        int32_t* prev_x, int32_t* prev_y);
    // get_route()'s full parent-chain -- unlike every prior TileSearch port
    // (which only ever needed the immediate get_prev(), exposed as prev_x/
    // prev_y out-params), land_raise_plan iterates the *entire* route to
    // place a goal at every tile along it, so the whole PointList has to
    // cross into Lua here. Capped at PathLimit (the same bound the engine
    // itself uses for a reconstructed route, path.h) -- out_count is the
    // real length actually written into xs/ys.
    void (*region_search_get_route)(int32_t* out_count, int32_t* xs, int32_t* ys,
        int32_t max_count);
    void (*region_search_adjust_roads)(int32_t value);

    // goal.cpp accessors needed by land_raise_plan (has_goal) and
    // invasion_plan (find_priority_goal). add_goal already existed
    // (combat_move's naval-pickup path). Both are pure queries over
    // Factions[faction_id].goals[] -- no mutation, unlike add_goal.
    int32_t (*has_goal)(int32_t faction_id, int32_t type, int32_t x, int32_t y);
    void (*find_priority_goal)(int32_t faction_id, int32_t type,
        int32_t* px, int32_t* py);

    // Movement stage 7B (IMPLEMENTATION_DETAILS.md 4.16): land_raise_plan's
    // own remaining dependencies. can_alter_level (move.cpp:408-430) is a
    // structural eligibility gate -- terraform-altitude arithmetic plus a
    // fixed-radius neighbor scan, no scoring/randomness -- same opaque tier
    // as can_bridge/has_base_sites.
    int32_t (*can_alter_level)(int32_t x, int32_t y, int32_t faction_id, int32_t raise);
    // mapdata[{x,y}].overlay is debug/visualization-only (read only by
    // move_upkeep's own UM_Visual block, never by AI decisions), but
    // land_raise_plan writes it unconditionally for every popped
    // shore-goal candidate -- kept for exact 1:1 fidelity anyway.
    void (*mapdata_set_overlay)(int32_t x, int32_t y, int32_t value);
    // land_raise_plan's own mapdata scan (move.cpp:598-619): finds land
    // tiles with PM_LandBaseRds, in y-bounds, non-ocean, coastal,
    // alterable, that have an adjacent ocean tile whose region is small
    // enough to fill -- all structural facts, no scoring, so the whole
    // filter (including the inner iterate_tiles break-on-first-match) is
    // one host-side iterator, same "opaque scan, Lua scores the yielded
    // candidates" split as every prior TileSearch-based mover. Walks the
    // real mapdata (an unordered_map) directly, same object and iteration
    // the original C++ used -- not reimplemented in Lua, so this can't
    // drift from upstream's own (formally unordered, but deterministic
    // for a given run) traversal. Yields (x, y) plus (nx, ny), the specific
    // matching ocean neighbor tile the score formula also reads.
    void (*land_raise_search_start)(int32_t max_size);
    void (*land_raise_search_next)(int32_t faction_id, int32_t* valid,
        int32_t* x, int32_t* y, int32_t* nx, int32_t* ny);
};

// Movement port, stage 0 (IMPLEMENTATION_DETAILS.md 4.12): Class 3
// (command/effect) hook dispatch. Unlike lua_ai_hook (Class 1) and
// lua_ai_shadow_call/_check (Class 1/2 shadow comparison, C++ always
// governs), Class 3 hooks let Lua mutate real engine state directly via
// the host API as they execute -- IMPLEMENTATION_PLAN.md Phase 4.1's own
// rule applies: once the first mutation is issued, there is no fallback
// to C++ for that invocation. If the Lua call errors after mutating,
// this function finishes the vehicle safely (mod_veh_skip) and reports
// "handled" so the caller does not re-run its own C++ body over an
// already-mutated state; if it errors before any mutation, it reports
// "not handled" and the caller's C++ body runs exactly as if the hook
// were absent. Every Class 3 hook shares this exact (veh_id) -> action
// code shape (colony_move/former_move/crawler_move/artifact_move/
// trans_move/nuclear_move/combat_move all take one veh_id and return one
// int), so this is a dedicated function rather than reusing lua_ai_hook's
// generic args-list contract.
bool lua_ai_command_hook(const char* name, int* out, int veh_id);

// Movement stage 7B (IMPLEMENTATION_DETAILS.md 4.16): the faction-level
// planning functions (land_raise_plan/invasion_plan) are Class 3 too --
// they mutate plans[]/goals[] directly as they run -- but their C++ shape
// is (faction_id) -> void, not (veh_id) -> int, so they don't fit
// lua_ai_command_hook's contract. Same no-fallback-after-first-mutation
// rule, but the recovery action differs: there is no single vehicle to
// mod_veh_skip once something has already been mutated, so an error after
// a mutation is just logged and reported "handled" (the caller's C++ body
// must not re-run over already-mutated plans[]/goals[] state, same
// reasoning as the veh_id version, just without a per-unit fallback
// action to take). Returns whether the hook ran (registered and callable),
// not a proposal to validate -- the caller has nothing left to do either
// way once this returns, unlike Class 2's propose-then-commit.
bool lua_ai_command_hook_faction(const char* name, int faction_id);

// Lazy-inits the Lua state on first call (skipped entirely if conf.lua_ai
// is 0), applies any pending reload request, then returns. No AI hooks are
// called from here yet (Phase 4) — this only owns the runtime lifecycle.
// Safe to call every turn; errors are contained per conf.lua_strict.
void lua_ai_turn_upkeep();

// Closes the Lua state, if any. Safe to call from DLL_PROCESS_DETACH.
void lua_ai_shutdown();

// Requests a reload of the Lua state at the next safe point (the start of
// the next lua_ai_turn_upkeep() call). Called from the Alt+U key handler;
// never reloads synchronously, since a keypress can land mid-callback.
void lua_ai_request_reload();

// Class 1 (pure query) hook dispatch (IMPLEMENTATION_PLAN.md Phase 4.1).
// Looks up `name` in the registry populated from lua/ai/init.lua's
// returned table at (re)load, calls it with `args` pushed as plain Lua
// numbers, and writes the result(s) to out[0..out_count-1]. Returns false
// ("not handled": caller must run its own C++ body instead) when lua_ai=0,
// the hook isn't registered, the Lua call returned nil/wrong-shaped, or it
// errored (Class 1 contract: always safe to fall back, since nothing is
// mutated before this returns) -- errors still go through the same
// dedup/lua_strict path as any other Lua error.
//
// out_count is the Consolidation gate's typed-descriptor generalization
// (2026-07-16): out_count == 1 expects the hook to return a single Lua
// number, unchanged from every hook written before this (mod_tech_val,
// find_proto, ...). out_count > 1 expects a 1-indexed Lua table of
// out_count numbers -- this is what makes facility_score/
// governor_priorities hookable (WItem is 5 ints; IMPLEMENTATION_DETAILS.md
// 4.9 found the old int-in/int-result-out contract couldn't express that).
// Still one function, not a zoo of `_i`/`_ii`/`_b`/`_witem` variants.
bool lua_ai_hook(const char* name, int* out, int out_count, std::initializer_list<int> args);

// Class 1/2 shadow-mode comparison (IMPLEMENTATION_PLAN.md Phase 5.1,
// Consolidation gate item b) -- the one generic mechanism that replaced
// five hand-rolled per-hook dual-run blocks (src/tech.cpp, src/faction.cpp
// x2, src/build.cpp x3). Usage at a hook site:
//
//   LuaShadowCall shadow = lua_ai_shadow_call("name", out_count, {args...});
//   ...C++ body computes its own result, unaffected -- RNG is
//   snapshotted/restored inside lua_ai_shadow_call itself...
//   lua_ai_shadow_check("name", shadow, cpp_out, out_count);
//   return cpp_value; // C++ always governs; shadow mode never acts on Lua
//
// conf.lua_shadow == 0: lua_ai_shadow_call returns immediately with
// active=false -- no Lua call, no RNG state touched, no further work in
// lua_ai_shadow_check either. Zero overhead beyond this one flag check.
// conf.lua_shadow == 1: snapshots game_rand_state()/random_state(),
// resolves and calls the hook exactly like lua_ai_hook() would, restores
// both streams (so the real C++ computation that follows sees the RNG
// exactly as if the Lua call never happened), and records how many draws
// from each stream the Lua call consumed (Phase 5.3.5's counters) for the
// divergence log line. Class 3 hooks are never shadow-run twice (plan
// 5.1) -- this pair is Class 1/2 only, by construction (no mutation
// happens between the two calls).
struct LuaShadowCall {
    bool active = false;
    bool handled = false;
    int out[5] = {};
    int args[8] = {};
    int arg_count = 0;
    uint32_t game_rand_draws = 0;
    uint32_t mod_rng_draws = 0;
};
LuaShadowCall lua_ai_shadow_call(const char* name, int out_count, std::initializer_list<int> args);
void lua_ai_shadow_check(const char* name, const LuaShadowCall& shadow,
    const int* cpp_out, int out_count);
