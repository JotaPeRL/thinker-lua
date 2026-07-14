-- Lua AI runtime bootstrap (IMPLEMENTATION_PLAN.md, Phase 3.1/3.2).
-- Loaded lazily by thinker.dll at the first turn upkeep (never during DLL
-- attach), and reloaded whenever the host recreates the Lua state (Alt+U).
-- Runs inside the sandbox set up by src/luaai.cpp: base/table/string/math/
-- bit/ffi are open (plus io/os/debug/package in debug builds). package is
-- never open, so modules load each other with dofile/loadfile (base
-- library, always available), not require.
--
-- This wires up the binding layer: validates the generated engine-struct
-- cdefs against this build's real LuaJIT layout before anything else
-- trusts them. lua/api/* (rand, cmath, faction, tech, map, game, log) and
-- lua/ffi/funcs.lua (the LuaHostApi handshake) are loaded on demand by AI
-- code, not eagerly here.
--
-- AI hooks (lua/ai/*) are NOT loaded from here: src/luaai.cpp's
-- register_hooks() loads lua/ai/init.lua directly, as a separate step
-- right after this file finishes, and reads its returned table into the
-- C++-side registry (IMPLEMENTATION_PLAN.md Phase 4.1).

host_log("lua/init.lua loaded")

-- dofile_once: some modules (lua/ffi/types.lua's ffi.cdef, lua/ffi/funcs.lua's
-- LuaHostApi cdef) can only run once per Lua state -- a second bare dofile
-- would re-register the same cdef and error. package/require stays
-- disabled outside debug builds (see above), so this is the minimal
-- memoization dofile itself doesn't provide.
local loaded = {}
function dofile_once(path)
    if loaded[path] == nil then
        loaded[path] = dofile(path)
    end
    return loaded[path]
end

dofile_once("lua/ffi/validate.lua")
host_log("ffi layout validated against generated types.lua")
