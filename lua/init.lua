-- Lua AI runtime bootstrap (IMPLEMENTATION_PLAN.md, Phase 2B).
-- Loaded lazily by thinker.dll at the first turn upkeep (never during DLL
-- attach), and reloaded whenever the host recreates the Lua state (Alt+U).
-- Runs inside the sandbox set up by src/luaai.cpp: only base/table/string/
-- math/bit are open (plus io/os/debug/package in debug builds).
--
-- This is intentionally minimal: no AI hooks exist yet (Phase 4) and no
-- FFI/host API exists yet (Phase 3). Its job today is just to prove the
-- runtime lifecycle (sandbox, error policy, dedup logging, reload) works.

host_log("lua/init.lua loaded")
