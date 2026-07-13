#pragma once
/*
 * Embedded Lua AI runtime — Phase 2B production lifecycle.
 * Owns the single LuaJIT state. Initialization is lazy, triggered from
 * mod_turn_upkeep: it must never run in DllMain's attach path, which holds
 * the Windows loader lock (file I/O and JIT activation there are UB).
 */

#include <cstdint>

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
