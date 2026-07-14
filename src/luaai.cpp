/*
 * Phase 2B: production Lua AI runtime lifecycle.
 *
 * Builds on the Phase 2A feasibility spike (LuaJIT stable in-process under
 * mingw static-link + Wine, IMPLEMENTATION_PLAN.md Phase 2A). This file
 * replaces the spike's throwaway checklist code with the real runtime every
 * later phase depends on: config-gated init, a sandboxed VM, an error policy
 * (conf.lua_strict), deduplicated error logging, and safe-point hot reload.
 *
 * No AI hooks exist yet (Phase 4) and no LuaHostApi/FFI layer exists yet
 * (Phase 3) — this is infrastructure only. The only script-visible surface
 * is lua/init.lua and the sandboxed standard libraries.
 */

#include "main.h"
#include "luaai.h"
#include "random.h"
#include "faction.h"
#include "tech.h"
#include "map.h"

#include <string>
#include <unordered_set>
#include <unordered_map>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "luajit.h"
}

// Trivial passthrough for conf.tech_balance -- a captureless lambda
// converts implicitly to a plain function pointer, so this doesn't need
// a named free function the way revised_tech_cost() (real logic, already
// existed in tech.cpp) does.
static int host_tech_balance_enabled() {
    return conf.tech_balance;
}

// Social engineering (porting-order item 2, IMPLEMENTATION_DETAILS.md 4.5).
// social_calc/social_upheaval take a flat 4-int model array from Lua and
// build a local CSocialCategory to call the real engine function with --
// CSocialCategory is 4 consecutive int32_t (models[4]), so a memcpy is
// exact. CSocialEffect's values[11] union member means out_values can be
// written through directly via reinterpret_cast, no separate marshalling.
static void host_social_calc(const int32_t* models, int32_t faction_id, int32_t* out_values) {
    CSocialCategory cat;
    memcpy(cat.models, models, sizeof(cat.models));
    social_calc(&cat, reinterpret_cast<CSocialEffect*>(out_values), faction_id, 0, 0);
}

static int32_t host_society_avail(int32_t sf, int32_t sm, int32_t faction_id) {
    return society_avail(sf, sm, faction_id);
}

static int32_t host_social_upheaval(int32_t faction_id, const int32_t* models) {
    CSocialCategory cat;
    memcpy(cat.models, models, sizeof(cat.models));
    return social_upheaval(faction_id, &cat);
}

static bool host_has_project(int32_t item_id, int32_t faction_id) {
    return has_project((FacilityId)item_id, faction_id);
}

static bool host_has_free_facility(int32_t item_id, int32_t faction_id) {
    return has_free_facility((FacilityId)item_id, faction_id);
}

static bool host_has_aircraft(int32_t faction_id) {
    return has_aircraft(faction_id);
}

static int32_t host_mineral_factor(int32_t faction_id, int32_t se_industry) {
    return mineral_factor(faction_id, se_industry);
}

static bool host_un_charter() {
    return un_charter();
}

// plans[]/conf are Thinker-internal (not FFI-mapped, see
// IMPLEMENTATION_DETAILS.md 3.4/4.5) -- exposed as single-field accessors
// rather than pulling AIPlans/Config into the FFI generator.
static int32_t host_defense_modifier(int32_t faction_id) {
    return plans[faction_id].defense_modifier;
}

static int32_t host_keep_fungus(int32_t faction_id) {
    return plans[faction_id].keep_fungus;
}

static int32_t host_social_ai_bias() {
    return conf.social_ai_bias;
}

// Populated once; every entry already matches the LuaHostApi pointer
// signature exactly, so no wrapper/trampoline functions are needed
// (see src/luaai.h for why extern "C" doesn't matter here).
static LuaHostApi g_host_api = {
    /* api_version          */ 4,
    /* rand_game            */ game_randv,
    /* rand_map             */ random_get,
    /* is_human             */ is_human,
    /* has_treaty           */ has_treaty,
    /* climactic_battle     */ climactic_battle,
    /* mod_wants_to_attack  */ mod_wants_to_attack,
    /* has_tech             */ has_tech,
    /* tech_level           */ tech_level,
    /* mod_tech_avail       */ mod_tech_avail,
    /* tech_is_preq         */ tech_is_preq,
    /* bad_reg              */ bad_reg,
    /* revised_tech_cost    */ revised_tech_cost,
    /* tech_balance_enabled */ host_tech_balance_enabled,
    /* social_calc          */ host_social_calc,
    /* society_avail        */ host_society_avail,
    /* social_upheaval      */ host_social_upheaval,
    /* has_project          */ host_has_project,
    /* has_free_facility    */ host_has_free_facility,
    /* has_aircraft         */ host_has_aircraft,
    /* mineral_factor       */ host_mineral_factor,
    /* un_charter           */ host_un_charter,
    /* defense_modifier     */ host_defense_modifier,
    /* keep_fungus          */ host_keep_fungus,
    /* social_ai_bias       */ host_social_ai_bias,
};

static lua_State* L = NULL;
static FILE* lua_log = NULL;
static bool init_attempted = false;
static bool disabled_for_session = false;
static bool reload_requested = false;
static int generation = -1;
static std::unordered_set<size_t> logged_errors;

// Class 1 hook registry: hook name -> LUA_REGISTRYINDEX ref, resolved once
// per (re)load (register_hooks(), called from create_lua_state()) so
// per-turn dispatch is a single lua_rawgeti, never a per-call string
// lookup (IMPLEMENTATION_PLAN.md Phase 4.1).
static std::unordered_map<std::string, int> hook_refs;

// Runtime logging: its own file, always available (debug.txt only exists in
// debug builds), mirrored to debug.txt when that log is open.
static void lua_logf(const char* fmt, ...) {
    va_list args;
    if (lua_log) {
        va_start(args, fmt);
        vfprintf(lua_log, fmt, args);
        va_end(args);
        fflush(lua_log);
    }
    if (debug_log) {
        va_start(args, fmt);
        fprintf(debug_log, "lua: ");
        vfprintf(debug_log, fmt, args);
        va_end(args);
    }
}

static int traceback_handler(lua_State* LS) {
    const char* msg = lua_tostring(LS, 1);
    luaL_traceback(LS, LS, msg, 1);
    return 1;
}

static int host_log(lua_State* LS) {
    lua_logf("%s\n", luaL_checkstring(LS, 1));
    return 0;
}

// Verbose counterpart, gated the same way the C++ side's debug_ver() macro
// is: only writes when conf.debug_verbose is set (the Alt+M toggle,
// src/gui.cpp). Kept as its own host function rather than a flag checked
// in Lua so the AI code never needs to know about conf directly.
static int host_log_ver(lua_State* LS) {
    if (conf.debug_verbose) {
        lua_logf("%s\n", luaL_checkstring(LS, 1));
    }
    return 0;
}

static int forbidden_math_random(lua_State* LS) {
    return luaL_error(LS, "math.random/randomseed is forbidden in Lua AI"
        " scripts; determinism requires the engine RNG bindings (rand.*,"
        " Phase 3)");
}

// Opens only the libraries the AI needs (IMPLEMENTATION_DETAILS.md 2.8).
// io/os/debug/package(require) are development-build only: BUILD_DEBUG
// script authors get the escape hatch, shipped scripts never do. `ffi` is
// opened unconditionally as of Phase 3.1 (lua/ffi and lua/api need it) --
// LuaJIT has no per-module sandboxing, so "lua/ai/ never touches ffi"
// stays a lint/review convention (Phase 4.4/6's luacheck pass), not a
// runtime wall; every build has `package`/`require` disabled, so lua/
// modules load each other via the base-library `dofile`/`loadfile`
// instead (those stay available in every build).
// LuaJIT's own luaL_openlibs (lib_init.c) opens a library by pushing the
// opener as a C function with the module name as its sole argument and
// calling it — there is no luaL_requiref in this LuaJIT version (it
// predates that Lua 5.2 addition). Mirror that exact pattern here so only
// the chosen subset ends up in _G.
static void open_lib(lua_State* LS, const char* name, lua_CFunction fn) {
    lua_pushcfunction(LS, fn);
    lua_pushstring(LS, name);
    lua_call(LS, 1, 0);
}

// luaopen_ffi is different from the libraries above: LuaJIT lists it in its
// own "preload" table rather than the eagerly-global-registering set (see
// lib_ffi.c's luaopen_ffi, which literally comments "no global 'ffi'
// created!" and instead returns the module table for require() to place
// wherever it likes). Since package/require is never open in this sandbox,
// open_lib()'s 0-result call would silently discard that table -- request
// 1 result instead and set the global ourselves.
static void open_ffi(lua_State* LS) {
    lua_pushcfunction(LS, luaopen_ffi);
    lua_pushstring(LS, LUA_FFILIBNAME);
    lua_call(LS, 1, 1);
    lua_setglobal(LS, LUA_FFILIBNAME);
}

static void open_sandbox(lua_State* LS) {
    static const luaL_Reg sandboxed_libs[] = {
        {"", luaopen_base},
        {LUA_TABLIBNAME, luaopen_table},
        {LUA_STRLIBNAME, luaopen_string},
        {LUA_MATHLIBNAME, luaopen_math},
        {LUA_BITLIBNAME, luaopen_bit},
        {NULL, NULL}
    };
    for (const luaL_Reg* lib = sandboxed_libs; lib->func; lib++) {
        open_lib(LS, lib->name, lib->func);
    }
    open_ffi(LS);
#if DEBUG
    static const luaL_Reg dev_only_libs[] = {
        {LUA_IOLIBNAME, luaopen_io},
        {LUA_OSLIBNAME, luaopen_os},
        {LUA_DBLIBNAME, luaopen_debug},
        {LUA_LOADLIBNAME, luaopen_package},
        {NULL, NULL}
    };
    for (const luaL_Reg* lib = dev_only_libs; lib->func; lib++) {
        open_lib(LS, lib->name, lib->func);
    }
#endif
    lua_getglobal(LS, LUA_MATHLIBNAME);
    lua_pushcfunction(LS, forbidden_math_random);
    lua_setfield(LS, -2, "random");
    lua_pushcfunction(LS, forbidden_math_random);
    lua_setfield(LS, -2, "randomseed");
    lua_pop(LS, 1);

    lua_register(LS, "host_log", host_log);
    lua_register(LS, "host_log_ver", host_log_ver);
}

// Applies conf.lua_strict and the once-per-(hook,turn,traceback) dedup rule.
// `hook_name` identifies the call site for the log line; with no AI hooks
// registered yet (Phase 4), the only caller today is the init.lua load step.
static void handle_lua_error(const char* hook_name, const char* traceback) {
    std::string key = std::string(hook_name) + "|" + std::to_string(*CurrentTurn)
        + "|" + (traceback ? traceback : "(no message)");
    size_t h = std::hash<std::string>{}(key);
    if (logged_errors.insert(h).second) {
        lua_logf("error in '%s' (turn %d): %s\n", hook_name, *CurrentTurn,
            traceback ? traceback : "(no message)");
    }
    if (conf.lua_strict == 1) {
        disabled_for_session = true;
        lua_logf("lua_strict=1: Lua AI disabled for the rest of the session\n");
    } else if (conf.lua_strict == 2) {
        lua_logf("lua_strict=2: aborting (development use only)\n");
        if (lua_log) {
            fclose(lua_log);
        }
        abort();
    }
}

// Loads lua/ai/init.lua (if present) and registers every entry of the
// table it returns as a Class 1 hook. Runs after lua/init.lua so the
// sandbox and every lua/api/* module it may need are already usable.
// Absence of the file (no AI hooks ported yet) is not an error -- an
// empty hook_refs just means lua_ai_hook() always reports "not handled".
static void register_hooks() {
    hook_refs.clear();

    lua_pushcfunction(L, traceback_handler);
    int errfunc = lua_gettop(L);
    if (luaL_loadfile(L, "lua/ai/init.lua") != 0 || lua_pcall(L, 0, 1, errfunc) != 0) {
        const char* msg = lua_tostring(L, -1);
        handle_lua_error("lua_ai_hooks_init", msg);
        lua_settop(L, errfunc - 1);
        return;
    }
    if (lua_istable(L, -1)) {
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            // key at -2, value at -1
            if (lua_type(L, -2) == LUA_TSTRING && lua_isfunction(L, -1)) {
                const char* name = lua_tostring(L, -2);
                lua_pushvalue(L, -1); // luaL_ref pops its argument
                int ref = luaL_ref(L, LUA_REGISTRYINDEX);
                hook_refs[name] = ref;
            }
            lua_pop(L, 1); // pop value, keep key for lua_next
        }
    }
    lua_settop(L, errfunc - 1);
    // TEMPORARY M4 diagnostic: confirm hooks actually registered (lua.log
    // only records errors, so silence elsewhere doesn't prove this ran).
    lua_logf("register_hooks: %d hook(s) registered\n", (int)hook_refs.size());
}

// (Re)creates the Lua state: opens the sandbox, then loads lua/init.lua.
// Used both for the first lazy init and for every later reload, so a
// failed/erroring init.lua behaves identically in both cases.
static void create_lua_state() {
    generation++;

    L = luaL_newstate();
    if (!L) {
        lua_logf("luaL_newstate failed\n");
        return;
    }
    open_sandbox(L);

    lua_pushlightuserdata(L, &g_host_api);
    lua_setglobal(L, "__host_api_ptr");

    lua_pushcfunction(L, traceback_handler);
    int errfunc = lua_gettop(L);
    if (luaL_loadfile(L, "lua/init.lua") != 0 || lua_pcall(L, 0, 0, errfunc) != 0) {
        const char* msg = lua_tostring(L, -1);
        handle_lua_error("lua_ai_init", msg);
        lua_close(L);
        L = NULL;
        return;
    }
    lua_settop(L, 0);
    register_hooks();
    lua_logf("Lua AI runtime initialized (gen %d)\n", generation);
}

static void ensure_log_open() {
    if (!lua_log) {
        lua_log = fopen("lua.log", "w");
    }
}

void lua_ai_turn_upkeep() {
    if (!conf.lua_ai || disabled_for_session) {
        return;
    }
    ensure_log_open();
    if (reload_requested) {
        reload_requested = false;
        init_attempted = true;
        if (L) {
            lua_close(L);
            L = NULL;
        }
        create_lua_state();
    } else if (!init_attempted) {
        init_attempted = true;
        create_lua_state();
    }
}

void lua_ai_shutdown() {
    hook_refs.clear();
    if (L) {
        lua_close(L);
        L = NULL;
    }
    if (lua_log) {
        fclose(lua_log);
        lua_log = NULL;
    }
}

void lua_ai_request_reload() {
    reload_requested = true;
}

bool lua_ai_hook(const char* name, int* out, std::initializer_list<int> args) {
    if (!conf.lua_ai || disabled_for_session || !L) {
        return false;
    }
    auto it = hook_refs.find(name);
    if (it == hook_refs.end()) {
        return false;
    }

    lua_pushcfunction(L, traceback_handler);
    int errfunc = lua_gettop(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, it->second);
    for (int arg : args) {
        lua_pushinteger(L, arg);
    }
    if (lua_pcall(L, (int)args.size(), 1, errfunc) != 0) {
        const char* msg = lua_tostring(L, -1);
        handle_lua_error(name, msg);
        lua_settop(L, errfunc - 1);
        return false;
    }

    bool handled = false;
    if (lua_isnumber(L, -1)) {
        *out = lua_tointeger(L, -1);
        handled = true;
    }
    lua_settop(L, errfunc - 1);

    // TEMPORARY M4 diagnostic: confirm each hook is actually being
    // *invoked*, not just registered (register_hooks() only proves the
    // latter). Logged once per hook name so this doesn't spam lua.log --
    // mod_tech_val can be called hundreds of times per turn.
    static std::unordered_set<std::string> logged_first_call;
    if (handled && logged_first_call.insert(name).second) {
        lua_logf("lua_ai_hook: '%s' invoked and handled (result=%d)\n", name, *out);
    }
    return handled;
}
