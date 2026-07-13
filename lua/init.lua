-- Lua AI runtime bootstrap (IMPLEMENTATION_PLAN.md, Phase 3.1).
-- Loaded lazily by thinker.dll at the first turn upkeep (never during DLL
-- attach), and reloaded whenever the host recreates the Lua state (Alt+U).
-- Runs inside the sandbox set up by src/luaai.cpp: base/table/string/math/
-- bit/ffi are open (plus io/os/debug/package in debug builds). package is
-- never open, so modules load each other with dofile/loadfile (base
-- library, always available), not require.
--
-- No AI hooks exist yet (Phase 4). This just wires up the binding layer
-- (Phase 3.1): validates the generated engine-struct cdefs against this
-- build's real LuaJIT layout, then smoke-tests the RNG bindings and the
-- integer-semantics helper every later AI module will depend on.

host_log("lua/init.lua loaded")

dofile("lua/ffi/validate.lua")
host_log("ffi layout validated against generated types.lua")

local rand = dofile("lua/api/rand.lua")
local cmath = dofile("lua/api/cmath.lua")

host_log(string.format(
    "smoke test: rand.game(10)=%d rand.map(0,10)=%d cmath.idiv(-7,2)=%d cmath.imod(-7,2)=%d",
    rand.game(10), rand.map(0, 10), cmath.idiv(-7, 2), cmath.imod(-7, 2)))
