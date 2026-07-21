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
    // want_convoy (move.cpp:1167-1221): pure scoring formula over tile
    // yields (mod_crop_yield/mod_mine_yield/mod_energy_yield) and base
    // state -- real engine mechanics, not AI choice (the choice itself
    // is a simple threshold comparison already inside the formula).
    // Mutates mapnodes in one early-return path (a dedup marker, not a
    // "decision"), so still flags g_mutation_issued like every other
    // wrapper that touches engine state.
    void (*want_convoy)(int32_t veh_id, int32_t x, int32_t y, int32_t* choice, int32_t* score);
    // The TileSearch scan itself (move.cpp:1253-1275) -- stays opaque
    // per Phase 4.3 (TileSearch never crosses into Lua), calls the real
    // C++ want_convoy internally per candidate tile, same "wrap the
    // whole scan+pick-best" precedent as has_base_sites/former_tile_tally.
    void (*crawler_find_convoy_site)(int32_t veh_id, int32_t best_score, int32_t limit,
        int32_t* found, int32_t* tx, int32_t* ty, int32_t* score);
    void (*mark_convoy_site)(int32_t x, int32_t y);
    int32_t (*set_convoy)(int32_t veh_id, int32_t res);
    int32_t (*move_to_base)(int32_t veh_id, int32_t ally);
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
