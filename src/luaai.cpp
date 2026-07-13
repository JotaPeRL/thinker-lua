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

#include <string>
#include <unordered_set>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "luajit.h"
}

// Populated once; game_randv/random_get already match the LuaHostApi
// pointer signatures exactly, so no wrapper functions are needed.
static LuaHostApi g_host_api = {
    /* api_version */ 1,
    /* rand_game   */ game_randv,
    /* rand_map    */ random_get,
};

static lua_State* L = NULL;
static FILE* lua_log = NULL;
static bool init_attempted = false;
static bool disabled_for_session = false;
static bool reload_requested = false;
static int generation = -1;
static std::unordered_set<size_t> logged_errors;

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
