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
};

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
// numbers, and writes the result to *out. Returns false ("not handled":
// caller must run its own C++ body instead) when lua_ai=0, the hook
// isn't registered, the Lua call returned nil, or it errored (Class 1
// contract: always safe to fall back, since nothing is mutated before
// this returns) -- errors still go through the same dedup/lua_strict
// path as any other Lua error. One function instead of a family of
// `_i`/`_ii`/`_b` variants, per the plan's explicit rule -- every hook
// needed so far is int-args-in, int-result-out.
bool lua_ai_hook(const char* name, int* out, std::initializer_list<int> args);
