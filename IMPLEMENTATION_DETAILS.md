# Implementation Details — tactical notes per phase

Companion to `IMPLEMENTATION_PLAN.md` (rev 2). The plan says *what* and *why*;
this file pins down *where* and *how*, with facts verified against the codebase
(line numbers as of commit `15418b2`; re-verify after upstream merges). It also
records corrections to earlier assumptions (see 3.1 and 3.4). Session-by-session
narrative — bug hunts, dead ends, the story of how a design was reached — lives
in `DEVELOPMENT_DIARY.md`, cross-referenced by date from the relevant section
below; this file keeps only what's needed to understand or resume the work.

---

## Phases 0–1 — done (2026-07-10), reference only

- Remotes: `origin` = `JotaPeRL/thinker-lua` (SSH), `upstream` =
  `induktio/thinker`. Branch: `lua-ai`.
- Toolchain that produced clean builds: mingw GCC 16.1.0, CMake 4.3.4,
  Ninja 1.13.2. Arch's mingw links against UCRT (fine in Wine and Win10+).
- Game: `~/.wine-smac/drive_c/Games/SMAC`, GOG installer run with
  `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LANG=english
  '/DIR=C:\Games\SMAC'`. `terranx.exe` SHA-1
  `4b19c1fe3266b5ebc4305cd182ed6e864e3a1c4a` (the exact binary Thinker checks).
- Wine ≥ 11 on Arch is WoW64-only; never use `WINEARCH=win32`.
- `tools/deploy.sh` copies dll/exe + `docs/modmenu.txt` (required by every
  Thinker dialog) + `docs/basenames/`; debug builds also get
  `libgcc_s_dw2-1.dll`, `libstdc++-6.dll`, `libwinpthread-1.dll` from
  `/usr/i686-w64-mingw32/bin/`.

---

## Phase 2 — embedding LuaJIT

### 2.1 Vendoring and cross-compile

```sh
git submodule add https://github.com/LuaJIT/LuaJIT third_party/luajit
git -C third_party/luajit checkout v2.1   # rolling branch — PIN THE COMMIT
# Pinned (2026-07-12): 3c4f9fe2052b8d08a917ac0d5f38563f0297b5a3

# host tools (minilua/buildvm) must match target pointer size => 32-bit host cc
# multilib prerequisite VERIFIED working on this machine (gcc -m32 compiles)
make -C third_party/luajit/src HOST_CC="gcc -m32" \
     CROSS=i686-w64-mingw32- TARGET_SYS=Windows BUILDMODE=static libluajit.a
```

Artifacts: `third_party/luajit/src/libluajit.a` + public headers `lua.h`,
`lauxlib.h`, `lualib.h`, `luajit.h` in the same directory.

### 2.2 CMake integration

In `CMakeLists.txt` (keep it a self-contained block, upstream-friendly):

```cmake
set(LUAJIT_DIR ${CMAKE_SOURCE_DIR}/third_party/luajit/src)
add_custom_command(OUTPUT ${LUAJIT_DIR}/libluajit.a
    COMMAND make -C ${LUAJIT_DIR} HOST_CC=\"gcc -m32\"
            CROSS=i686-w64-mingw32- TARGET_SYS=Windows BUILDMODE=static libluajit.a
    COMMENT "Cross-compiling LuaJIT")
add_custom_target(luajit DEPENDS ${LUAJIT_DIR}/libluajit.a)
add_dependencies(thinkerlib luajit)
target_include_directories(thinkerlib PRIVATE ${LUAJIT_DIR})
target_link_libraries(thinkerlib PRIVATE ${LUAJIT_DIR}/libluajit.a)
```

Caveats: LuaJIT's makefile is not parallel-safe across configs sharing the same
source dir — `debug` and `develop` share one `libluajit.a`, which is fine
(LuaJIT is always built optimized). `make clean` in the submodule when switching
LuaJIT versions.

### 2.3 Init point — outside the loader lock (rev 2 correction)

**Never initialize Lua in `DllMain`** (`src/main.cpp:446`): it runs under the
Windows loader lock; file I/O, CRT/runtime init and JIT activation there are
deadlock/UB territory. Instead:

- **Lazy init from an already-patched engine callback.** Verified candidate:
  `mod_turn_upkeep()` (`src/game.cpp:1010`), patched over the engine's
  `control_turn`/`net_control_turn` calls at `patch.cpp:656-657`. It runs at
  the start of every turn, well after process init, and already contains
  once-per-game logic (`*CurrentTurn == 0` → `init_world_config()`).
  A 1–2 line seam at its top calls `lua_ai_init_once()`.
- `DllMain`'s `DLL_PROCESS_DETACH` may call `lua_ai_shutdown()` (closing a
  `lua_State` is safe there; nothing is loaded/created).
- New files: `src/luaai.h` / `src/luaai.cpp` owning the single `lua_State*`:
  - `void lua_ai_init_once()` — idempotent; create state, open libs, run
    `lua/init.lua` from the game's working directory (the game always runs
    with cwd = game folder; use a relative path).
  - `void lua_ai_shutdown()`; Phase 2B adds `lua_ai_reload()` and the
    safe-point reload flag.
  - Hook callers (Phase 4): `lua_ai_hook(...)`.
- The CMake source glob (`src/*.cpp`) picks new files up automatically.

### 2.4 Phase 2A spike — concrete checklist

Spike contents (plan Phase 2A), mapped to this codebase:

1. Submodule + static `libluajit.a` linked into `thinker.dll` (2.1/2.2).
2. `lua_ai_init_once()` called from the `mod_turn_upkeep` seam (2.3).
3. `lua/init.lua` loaded via `lua_pcall` + traceback handler; result logged.
4. Host function returning the current turn: reads `*CurrentTurn`
   (`engine.cpp:51`, address `0x9A64D4`).
5. Host function returning a simple base value: validate `id < *BaseCount`
   (`engine.cpp:36`) then read from `Bases[id]`.
6. C→Lua call into a pure Lua function defined in `init.lua`; result logged.
7. Deliberate Lua error contained by pcall; game continues; traceback logged.
8. 100+ autoplayed turns without a crash. **No autoplay facility exists**
   (`test.cpp`/`extra_setup()` is an empty scaffold) — the spike needs either a
   throwaway auto-end-turn hack in `mod_turn_upkeep` or manual/observer play.
9. Everything run twice: `jit.off()` first, then JIT on (toggle in `init.lua`).

Spike logging can rely on `debug()`/debug builds; the real logging design is
2.6. Not in the spike: hot reload, cdef generator, high-level API, shadow,
packaging, CI.

### 2.5 Config options

Three places per option (follow any existing option as template, e.g.
`social_ai`, `src/main.h:232`):

1. Field in `struct Config`, `src/main.h` (~line 203+, defaults inline).
2. Parse branch in `option_handler`, `src/main.cpp` (`MATCH("lua_ai")` etc.).
3. Documented default in `docs/thinker.ini` (deploy only copies it when absent).

Options: `lua_ai=1`, `lua_shadow=0`, `lua_strict=0` — strict levels per plan
2B: 0 = disable failing hook + fallback where the class permits; 1 = disable
all Lua AI for the session + popup; 2 = deliberate abort (development only).

### 2.6 Logging reality check

`debug()` / `debug_ver()` (`src/main.h:35-48`) compile to **nothing** outside
`BUILD_DEBUG`, and `debug_log` is only opened under `DEBUG` (`src/main.cpp:450`).
Decision (recorded): Lua's `log.*` writes to its own `lua.log` (always
available, since script users won't run debug builds), and *additionally*
mirrors to `debug.txt` when `debug_log` exists. Prefix `lua:`, honor the Alt+M
verbose toggle, keep an `fflush` policy like `flushlog()`.

### 2.7 Hot reload key (Phase 2B)

Keyboard handling lives in `src/gui.cpp` inside the window procedure, as a chain
of `else if (msg == WM_CHAR && wParam == '<key>' && alt_key_down())` starting
around line 695 (Alt+R/T) with debug-only entries guarded by `debug_cmd` from
line ~721. Add Alt+U (unused), available in all builds — script authors are the
target audience. **The keypress only sets a flag**; the actual reload runs at a
safe point (start of `mod_turn_upkeep`, before any AI phase), never inside a
Lua callback. Increment the generation counter on reload; reject stale handles.

### 2.8 Sandboxing (Phase 2B)

Open only `base`, `table`, `string`, `math` (with `math.random`/
`math.randomseed` replaced by raising stubs, see 3.5), `bit`. `io`, `os`,
`debug` and arbitrary `require` paths only in development builds. `ffi` is
required by `lua/ffi/` and `lua/api/` internally and never exposed to `ai/`.

---

## Phase 3 — binding layer

Rev 2 principle — read/write asymmetry: **reads** of engine state are direct
FFI inside `api/`; **all writes and all engine-function calls** go through
`extern "C"` wrappers in `LuaHostApi`. Raw pointers never leave `ffi/`;
persistent references are numeric IDs, validated by every wrapper before
dereferencing.

### 3.1 Correction: engine structs are C++, not C — generate cdefs from the compiler

`engine_veh.h`, `engine_base.h` etc. define structs with **inline C++ methods**
(e.g. `VEH::triad()` at `engine_veh.h:401` and dozens of `is_*()` helpers
through ~line 480; fields themselves start in the `struct VEH` line 482 region).
LuaJIT `ffi.cdef` accepts only C. Rev 2 replaces the earlier libclang-parsing
idea with a **generator compiled by the build's own compiler**:

- `tools/gen_ffi.cpp` `#include`s the same engine headers with the same
  defines/packing as the real build and *prints* `lua/ffi/types.lua`
  (field-only C declarations + fixed global addresses) plus a validation
  table: `sizeof`/`alignof` per struct and `offsetof` for **every exposed
  field**, enum widths, `sizeof(bool)`, pointer size (must be 4).
- Compile it with `i686-w64-mingw32-g++` and run it under Wine when needed —
  identical ABI to `thinker.dll` by construction. No C++ header parser.
- The headers have *no* `static_assert(sizeof...)` to lean on; the generated
  validation table is the source of truth. `init.lua` asserts every entry via
  `ffi.sizeof`/`ffi.alignof`/`ffi.offsetof`; any mismatch → Lua AI refuses to
  enable, loud log, C++ runs.
- Inline C++ helpers dropped by field-only generation are re-exposed in the
  Lua `api/` layer (3.6), porting their one-line bodies manually as needed.

### 3.2 Engine globals: two kinds, two mechanisms

See `src/engine.cpp:6-270`:

- **Fixed-address constants** — `BASE** const CurrentBase = (BASE**)0x90EA30;`,
  `UNIT* Units = (UNIT*)0x9AB868;`, `CRules* Rules = (CRules*)0x949738;` etc.
  Safe to emit as generated `ffi.cast` constants.
- **Mutable pointers** — e.g. `VEH* Vehs` defaults to `0x952828` but the mod can
  re-point it (`VehsMod`/`ArrayVehs`, `engine.cpp:204-213`); same for `Bases`.
  **Never hardcode these addresses in Lua.** Expose them via the host API as
  pointers-to-pointers (`VEH** vehs`), and dereference on access in the Lua
  wrapper, so re-pointing is always seen.

### 3.3 `LuaHostApi` — writes, calls, retained primitives

- One versioned `extern "C"` struct of function pointers (`struct LuaHostApi`
  in `luaai.h`), passed to `init.lua` as lightuserdata + cdef. Includes
  `api_version`; bump on any layout change; `init.lua` asserts it.
- Covers: (a) every engine function the AI calls — engine calls in C++ follow
  the pattern `fp_none game_rand = (fp_none)0x64601D;` (`engine.cpp:311`) with
  `__cdecl`/`__thiscall` typedefs (`engine.h:205-213`, `engine.h:561`) — the
  wrappers are compiled by the same toolchain, so the ABI cannot be
  hand-declared wrong; (b) every mutation of engine state; (c) retained C++
  primitives (pathfinding, `TileSearch`, `PMTable` — see 3.4 and plan 4.3).
- Every wrapper validates IDs/coordinates before dereferencing (stale handles
  after unit death / base capture).
- Do **not** declare engine function signatures in Lua FFI for calling — that
  is exactly the dangerous FFI use the asymmetry rule eliminates.

### 3.4 Correction: PMTable/NodeSet are STL — not FFI-accessible

`PMTable` is `std::unordered_map<Point, PInfo>` and `NodeSet` is
`std::set<MapNode>` (`engine.h:196-197`). Any statement that Lua reads
`mapdata`/`mapnodes` "via FFI" is wrong as written. Access goes through
host-API accessor functions instead, e.g.:

```c
PInfo* mapdata_get(int x, int y);        // returns pointer into the map entry
int    mapnodes_check(int x, int y, int type);
void   mapnodes_add(int x, int y, int type);
```

`PInfo` itself is a plain struct — returning a pointer to it lets Lua read/write
fields via FFI with one call per tile. If profiling later shows this is hot,
consider replacing PMTable in C++ with a flat array (upstream-divergent, so only
with measurements in hand). `plans[]` (`AIPlans`, plain struct at
`main.h:357`) has no such problem: pass `&plans[0]` through the host API.

### 3.5 RNG bindings (exact functions)

- Engine stream: `game_rand` (engine fn at `0x64601D`), wrapped by
  `game_randv(n)` (`random.cpp:9`); state readable via `game_rand_state()`
  (`random.cpp:4` — reads word 5 of the CRT per-thread data at `0x6491C3`).
  For shadow mode a **setter** is also needed: write the saved word back
  (`((uint32_t*)getptd())[5] = saved`) — implement `game_rand_restore(v)` next
  to `game_rand_state()` in `random.cpp`.
- Mod LCG: `random(n)` / `random_state()` / `random_reseed(v)` (`random.cpp`),
  plus `map_rand` (`GameRandom`) used by mapgen — not AI-relevant.
- Expose as `rand.game(n)`, `rand.mod(n)`, and (host-API only, for the shadow
  wrapper, not for `lua/ai/`) the state get/restore pair.
- In `init.lua`, replace `math.random`/`math.randomseed` with functions that
  `error()` — enforcement, not convention.

### 3.6 High-level API notes

- Mirror helper semantics from `veh.h`/`base.h`/`map.h` — port their inline
  bodies, don't reinvent. `map.tile(x, y)` must reproduce `mapsq()` exactly,
  including the odd/even x+y parity rule and X wrapping.
- Iterators must be index-ordered (`for i = 0, VehCount-1`), never `pairs` over
  hash tables, per the determinism rule.
- Build the API as a vertical slice per milestone M3A — only what the current
  port target needs; `api/` objects may be FFI metatypes (LuaJIT is a hard
  dependency now), as long as `ai/` never touches the `ffi` module itself.

### 3.7 Integer semantics (project rule, rev 2)

C truncates integer division toward zero; Lua floors. In scoring code this
diverges silently on negatives. Rules:

- `api/cmath.lua` provides `idiv(a, b)` / `imod(a, b)` with C semantics.
- Bare `/` and `%` banned in integer expressions in `lua/ai/` (code review +
  a grep-based lint pass alongside luacheck).
- Bitwise work uses the `bit` library; where C++ relies on 32-bit wrap or
  truncation, replicate explicitly with `bit.tobit`.

---

## Phase 4 — porting

### 4.1 Hook plumbing

- **Hook classes** (plan 4.1): Class 1 pure query (value in, value out),
  Class 2 transactional (propose-then-commit — Lua returns a proposal table,
  C++ validates and applies), Class 3 command/effect (Lua mutates via host
  API; **no fallback after the first mutation** — on late error, finish the
  unit safely, e.g. `veh_skip`, and log). Record the class per function in
  `docs/LUA_PORTING.md`.
- **Registry-based resolution:** hooks are resolved once at (re)load from the
  central `ai.hooks` table into registry references (`luaL_ref`); per call it
  is one `lua_rawgeti` + `lua_pcall`. No per-call string lookup; cache
  invalidated on reload (generation counter).
- Avoid a zoo of `lua_ai_hook_i/_ii/_b/_v` variants: a small set of typed
  argument/result descriptors keeps call sites uniform. Social AI needs pointer
  args (`CSocialCategory*` — pass as lightuserdata, cast with FFI inside
  `api/`).
- Return protocol: hook returns `nil` → "not handled" → C++ fallback runs
  (subject to the class rules). Any non-nil is the decided value/proposal.
- Shared state during the transition: `plans[]`, `mapdata`, `mapnodes` remain
  canonical in C++ (accessed per 3.3/3.4), so half of a domain can be ported
  without desync.

### 4.2 Seam locations (verified)

| Hook | Function | File:line region |
|---|---|---|
| Research value | `mod_tech_val` | `tech.cpp` |
| Research pick | `mod_tech_ai` | `tech.cpp` |
| Social engineering | `mod_social_ai` | `faction.cpp:87` (decl) |
| War decisions | `mod_wants_to_attack` | `faction.cpp:88` (decl) |
| Production | `select_build` | `build.cpp` (decl `build.h:18`) |
| Hurry | `mod_base_hurry` | `build.cpp` (decl `build.h:5`) |
| Unit design | `design_units` | `plan.cpp` (decl `plan.h:45`) |
| Strategic upkeep | `plans_upkeep` | `plan.cpp` (decl `plan.h:47`) |
| Unit dispatch | `mod_enemy_move` | `veh_turn.cpp:137` (per-class dispatch at 164–189) |
| Per-class movers | `colony_move` … `combat_move` | `move.cpp` (decls `move.h:56-63`) |
| Move upkeep | `move_upkeep` | `move.cpp` (decl `move.h:40`) |

Hook the **per-class movers**, not `mod_enemy_move` itself: its body also
handles player-unit automation, alien factions (`mod_alien_move`) and the
`enemy_move` engine fallback with an anti-infinite-loop guard
(`veh_turn.cpp:191-198`) — that orchestration stays in C++.

### 4.3 Porting workflow per module

1. Read the C++ function; list every helper it calls; decide each: port to Lua
   now, expose via host API, or already available. Confirm the hook class
   ("pure" must be verified, not assumed — a scoring function that updates a
   cache is Class 2).
2. Port 1:1, keeping the C++ control flow recognizable; add machine-readable
   provenance (`port.source = { file, func, upstream_commit }`, plan 4.4).
3. Golden traces pass (5.2), then shadow mode (`lua_shadow=1`) until
   divergences are zero at the class-appropriate level across the plan's 5.x
   test matrix.
4. Flip default, move on. Never port two modules in shadow simultaneously —
   divergence attribution gets muddy.

After every upstream merge, run the drift report (`tools/port_drift.py`, plan
4.4) and re-run `gen_ffi` + layout asserts.

### 4.4 Movement-specific notes

- `move_upkeep(faction_id, mode)` (`move.cpp`) is both *computation* (fills
  `mapdata`, `mapnodes`, region info — stays in C++ per plan 4.3) and *decision
  prep* (invasion/naval planning). Split it when porting: keep the table fills
  as host primitives; port the planning that consumes them.
- `combat_move` interleaves decisions with engine actions (`set_move_to`,
  attack orders) — canonical Class 3. Shadow-compare only its pure scoring
  helpers (`battle_priority`-style functions); validate the whole system via
  determinism runs (plan 5.3).

### 4.5 Social-engineering port (porting-order item 2) — in-game verified clean

**Status: ✅ in-game verified clean (2026-07-14).** `social_score()` + the
`sf`/`sm2` selection loop ported to `lua/ai/social.lua`, `mod_social_ai`
hooked; `LuaHostApi` bumped to `api_version=4` (11 new entries, listed
below). Zero mismatches across ~145 dual-run calls covering both
`pop_boom` values and both a no-op and a real proposed-and-applied social
model change. Formally closed by the Consolidation gate
(`IMPLEMENTATION_PLAN.md`). Session narrative, exact call counts and the
scope corrections found while implementing: `DEVELOPMENT_DIARY.md`,
2026-07-14.

**Scope decided (narrower than "port `mod_social_ai` + `mod_wants_to_attack`
verbatim"):**

1. Port `social_score()` (`src/faction.cpp:1297`, static helper) and the
   selection loop inside `mod_social_ai()` (`src/faction.cpp:1441`, the
   `for (i in categories) for (j in models)` block choosing `sf`/`sm2`).
   This is the actual AI decision.
2. **Deferred to C++, not ported:** the `pop_boom`/`want_pop`/`pop_total`
   computation at the top of `mod_social_ai` (`faction.cpp:1458-1480`) —
   it loops `Bases[]`, and no `BASE` struct exists in the FFI yet (only
   `Faction`/`MFaction`/tech-related structs are generated so far). Keep
   this block in the C++ seam exactly as-is; pass its result (`pop_boom`,
   a 0/1 int) as an extra hook argument alongside `faction_id` — this fits
   the existing `lua_ai_hook(name, int* out, {args...})` signature with
   zero changes to the hook mechanism itself.
3. **Deferred entirely:** `mod_wants_to_attack()` (`faction.cpp:1708`, via
   `evaluate_attack`, ~180 loc) — a separate, self-contained function.
   Treat as porting-order item 2b, after `mod_social_ai` is verified clean.
4. Verification: same temporary dual-run pattern as item 1 (M4) —
   C++ stays authoritative, Lua's proposal is only compared and logged on
   mismatch (`lua/cpp mod_social_ai mismatch: ...`), until confidence is
   established.

**Key insight that simplifies the FFI side:** `CSocialCategory` (4 ints,
`engine_types.h:785`) and `CSocialEffect` (11 ints, `engine_types.h:797`)
are *not* separate struct fields on `Faction` — the C++ code overlays them
via pointer cast onto runs of plain `int32_t` fields already in `Faction`
(e.g. `auto pending = (CSocialCategory*)&f->SE_Politics;`, exploiting that
`SE_Politics, SE_Economics, SE_Values, SE_Future` are four consecutive
`int32_t` fields matching `CSocialCategory::models[4]` field-for-field, and
similarly `SE_economy..SE_research` — eleven consecutive fields — match
`CSocialEffect::values[11]`). **So the FFI side needs no new struct types,
only new named `int32_t` fields on the existing `Faction`/`MFaction` cdefs**
(`tools/gen_ffi.cpp`'s `FIELD(...)` macro) — Lua reads the named fields
directly and assembles a 4- or 11-element local array itself when it needs
`models[sf]`-style indexing.

**New `Faction` fields needed** (add to the `FIELD(Faction, ...)` list,
`tools/gen_ffi.cpp:244`): `energy_credits`, `SE_Politics`, `SE_Economics`,
`SE_Values`, `SE_Future`, `SE_Politics_pending`, `SE_upheaval_cost_paid`,
`SE_economy`, `SE_effic`, `SE_support`, `SE_talent`, `SE_morale`,
`SE_police`, `SE_growth`, `SE_planet`, `SE_probe`, `SE_industry`,
`SE_research`. (All already declared as plain `int32_t` in
`engine_types.h:293-378`.)

**New `MFaction` fields needed** (`tools/gen_ffi.cpp:233`):
`soc_priority_category`, `soc_priority_model`, `soc_priority_effect`,
`thinker_last_mc_turn`, `rule_drone`, `rule_talent`.

**New `counts` needed** (`tools/gen_ffi.cpp`, `printf("  counts = {\n")`
block, values from `main.h:146-158`): `MaxSocialCatNum = 4`,
`MaxSocialModelNum = 4`, `MaxSocialEffectNum = 11`, `GrowthPopBoom = 6`.

**New `enums` needed** (already in `engine_enums.h`, just add `printf`
lines): `FAC_CHILDREN_CRECHE = 2`, `FAC_PUNISHMENT_SPHERE = 23`,
`FAC_COMMAND_NEXUS = 71`, `FAC_LONGEVITY_VACCINE = 84`,
`FAC_CYBORG_FACTORY = 87`, `FAC_CLONING_VATS = 94`,
`FAC_TELEPATHIC_MATRIX = 100`, `DIFF_LIBRARIAN = 3`,
`SOCIAL_C_ECONOMICS = 1`, `SOCIAL_M_FRONTIER = 0`, `SOCIAL_M_SIMPLE = 0`,
`SOCIAL_M_PLANNED = 2`, `SOCIAL_M_GREEN = 3`. (`FAC_HUNTER_SEEKER_ALGORITHM`
already added for the tech pilot, reused here too.)

**New `globals` needed** (addresses confirmed in `src/engine.cpp`, same
provenance-by-comment convention as the existing table):
`SunspotDuration = 0x9A6800`, `DiffLevel = 0x9A64C4`,
`MapAreaSqRoot = 0x949888`. (`FactionRankings = 0x9A64EC` also confirmed,
needed only for the deferred `mod_wants_to_attack`, item 2b — add then, not
now.)

**New `LuaHostApi` wrappers needed** (`src/luaai.h`/`src/luaai.cpp`, same
pattern as `revised_tech_cost`/`tech_balance_enabled`) — these are engine
*mechanics*, not AI policy, so they stay C++, exposed read-only:

- `social_calc(const int32_t models[4], int32_t faction_id, int32_t out_values[11])`
  — wraps `social_calc(CSocialCategory*, CSocialEffect*, int, BOOL, BOOL)`
  (`faction.h:81`) with the two trailing `BOOL` flags hardcoded to `0, 0`
  (the only pattern `social_score` uses, `faction.cpp:1320`). Builds a
  local `CSocialCategory` from `models[4]`, and since `CSocialEffect` is a
  `union { struct {...}; int32_t values[11]; }` (`engine_types.h:797`),
  `reinterpret_cast<CSocialEffect*>(out_values)` is safe to write through
  directly — no separate struct marshalling needed.
- `society_avail(int32_t sf, int32_t sm, int32_t faction_id)` → wraps
  `society_avail` (`faction.h:85`).
- `social_upheaval(int32_t faction_id, const int32_t models[4])` → builds a
  local `CSocialCategory` from `models[4]`, wraps `social_upheaval`
  (`faction.h:84`), returns the cost.
- `has_project(int32_t item_id, int32_t faction_id)` → wraps the 2-arg
  overload (`faction.h:15`).
- `has_free_facility(int32_t item_id, int32_t faction_id)` → `base.h:77`.
- `has_aircraft(int32_t faction_id)` → `faction.h:12`.
- `mineral_factor(int32_t faction_id, int32_t se_industry)` → `base.h:22`.
- `un_charter()` → `game.h:11`.
- `defense_modifier(int32_t faction_id)` → new small wrapper returning
  `plans[faction_id].defense_modifier`. `AIPlans`/`plans[]` is a
  Thinker-internal struct (`main.h:360`), not part of the portable
  `engine_types.h`/`engine_base.h`/`engine_veh.h` headers `gen_ffi.cpp`
  parses — expose the one field needed as a host-API accessor rather than
  pulling `AIPlans` into the FFI generator (`main.h` drags in the
  `<windows.h>` dependency chain `gen_ffi.cpp` deliberately avoids, per
  Phase 3.1's status note).
- `social_ai_bias()` → new small wrapper returning `conf.social_ai_bias`
  (`main.h:233`), same rationale as `tech_balance_enabled` (`conf` is a
  Thinker-internal `Config` struct, not FFI-mapped).

**Class-2 proposal encoding — no new hook-dispatch plumbing needed.** The
existing `lua_ai_hook(name, int* out, {args...})` (int-args-in,
single-int-out) is enough: have the Lua hook return a packed int
`sf * MaxSocialModelNum + sm2` (range 0-15) when it proposes a category
change, or `-1` when it evaluated and found no change worth making (a
legitimate outcome, distinct from "hook errored/unregistered" which is
`nil`/`false` under the existing contract). C++ decodes: `-1` → no
proposal; otherwise `sf = val / 4, sm2 = val % 4`. Matches the plan's
explicit rule against a hook-signature zoo (plan 4.1) — no need to extend
`lua_ai_hook` for this.

**Files to touch when resuming:** `tools/gen_ffi.cpp` (fields/counts/enums/
globals above), `src/luaai.h` + `src/luaai.cpp` (new `LuaHostApi` entries,
`api_version` bump to 4), `src/faction.cpp` (seam in `mod_social_ai`,
dual-run instrumentation mirroring `src/tech.cpp`'s `mod_tech_val`/
`mod_tech_ai` pattern), `lua/api/faction.lua` (accessors for the new
fields + the new host-API wrappers), `lua/ai/social.lua` (new file: ported
`social_score` + selection loop, provenance metadata pointing at
`src/faction.cpp` / `mod_social_ai` / the same `upstream_commit` used by
`lua/ai/tech.lua`), `lua/ai/init.lua` (register `mod_social_ai`).

---

### 4.6 War-decision port (porting-order item 2b) — in-game verified clean

**Status: ✅ in-game verified clean (2026-07-14).** `evaluate_attack` ported
to `lua/ai/war.lua`, `mod_wants_to_attack` hooked (seam added around the
existing call to `evaluate_attack` rather than threaded through every
return point inside it, since the seam lives in the small wrapper function,
not the sprawling one). Zero mismatches across 123 calls, both outcomes
exercised. Formally closed by the Consolidation gate
(`IMPLEMENTATION_PLAN.md`). Session narrative: `DEVELOPMENT_DIARY.md`,
2026-07-14.

`LuaHostApi` bumped to `api_version=5` with 4 new entries
(`great_beelzebub`, `great_satan`, `has_agenda`, `hq_region`). `game.lua`
gained a `faction_ranking(i)` accessor for `FactionRankings` (an
`int[MaxPlayerNum]` array, not a scalar, so it doesn't fit the existing
bare-scalar-global accessors already there).

`evaluate_attack` (`src/faction.cpp:1539-1718`, ~180 loc, static helper) +
`mod_wants_to_attack` (`faction.cpp:1720-1726`, the logging wrapper Thinker
calls). **Class 1 (pure query)** — simpler contract than item 2's Class 2:
no mutation, no `random()` calls found anywhere in the function body, so no
RNG snapshot/restore needed for the dual-run check (unlike `mod_tech_ai`).
Same dual-run verification pattern as items 1 and 2: temporary instrumentation
in the `faction.cpp` seam, C++ stays authoritative, Lua's value is only
compared and logged on mismatch, until confidence is established.

**Already available, no new work:** `has_treaty`, `is_human`,
`climactic_battle`, `game.rules()` (`*GameRules`), `MaxPlayerNum`,
`MaxRegionLandNum` (`counts`), and on `Faction`: `AI_fight`,
`region_total_bases`, `best_weapon_value`.

**New `Faction` fields needed** (`tools/gen_ffi.cpp`'s `FIELD(Faction, ...)`
list): `best_armor_value`, `region_force_rating` (array, indexed by region),
`region_total_combat_units` (array), `tech_commerce_bonus`,
`integrity_blemishes`, `SE_morale_pending`, `major_atrocities`,
`player_flags`. Read-only field access, no new `FieldShape` handling
expected (all plain scalars or 1D arrays, same shape as `region_total_bases`
already has).

**New `MFaction` field needed:** `rule_morale`.

**Three helpers deliberately kept opaque (host wrappers, not ported)** —
same precedent as `social_calc` in 4.5, engine mechanics rather than the
attack decision itself:
- `great_beelzebub(faction_id, is_aggressive)` / `great_satan(faction_id,
  is_aggressive)` (`faction.cpp:834,853`) — "who is the dominant AI threat"
  heuristics; pull in `diff_level`, `DIFF_TRANSCEND`/`DIFF_LIBRARIAN`,
  `aah_ooga()`, `climactic_battle()`. Porting the whole tree isn't worth it
  for two boolean reads.
- `has_agenda(faction_id_1, faction_id_2, status)` (`faction.cpp:388`) is
  trivial (`Factions[f1].diplo_agenda[f2] & status`) — could go either way
  (port as an FFI field read on a new `diplo_agenda[9]` field, or keep as a
  wrapper like `is_human`/`has_treaty` already are). Default: wrapper, for
  consistency with the rest of this module; revisit only if it turns out to
  matter.

**HQ region lookup — new single-purpose wrapper, `BASE` FFI deliberately
deferred:** the function needs the map region each faction's HQ base sits
in (`faction.cpp:1628-1638`: loops `Bases[]`, checks
`has_fac_built(FAC_HEADQUARTERS, i)`, then `region_at(x, y)`). `BASE` is not
in the FFI yet (same gap noted in 4.5) and item 3 (production/plans) will
need it for real, across many fields — exposing one field's worth here
just to unblock this port would likely need redoing once item 3 starts.
Instead: one new host wrapper, `hq_region(faction_id) -> region_id | -1`,
doing `find_hq()` (`faction.h:35`, already exists) + coordinate lookup +
`region_at()` (`map.cpp:269`) entirely in C++. Matches the
`defense_modifier`/`keep_fungus` precedent (single-field accessors) from
4.5.

**New globals/enums:** `FactionRankings` (`engine.h:452`, already flagged
in 4.5 as "needed only for item 2b, add then" — now's the time),
`RULES_INTENSE_RIVALRY`, `AGENDA_UNK_200`, plus whatever `DIPLO_*` flags
`evaluate_attack`'s `has_treaty()` calls use that aren't already in the
enum table (check against the existing list before assuming any are
missing).

**Integration wrinkle worth knowing about, not a blocker:**
`lua/ai/tech.lua:270,273` already calls `faction.mod_wants_to_attack(...)`
(asking C++'s answer as an input to its own scoring). Once the dual-run
seam is added inside `mod_wants_to_attack` itself, those two call sites
will transitively trigger the new Lua hook and dual-run logging too, nested
inside tech scoring — expected, not a sign of a wiring bug if the log looks
busier than a naive per-turn call count would suggest.

**Files to touch when implementing:** `tools/gen_ffi.cpp` (fields/enums/
globals above), `src/luaai.h` + `src/luaai.cpp` (new `LuaHostApi` entries:
`great_beelzebub`, `great_satan`, `has_agenda` or the field instead,
`hq_region`; `api_version` bump to 5), `src/faction.cpp` (seam in
`mod_wants_to_attack`, dual-run instrumentation mirroring the existing
pattern), `lua/api/faction.lua` (accessors for the new fields + wrappers),
`lua/ai/social.lua` or a new `lua/ai/war.lua` (port `evaluate_attack`,
provenance metadata pointing at `src/faction.cpp` / `evaluate_attack` /
the same `upstream_commit` used elsewhere), `lua/ai/init.lua` (register
the hook).

---

### 4.7 Production/plans port, first slice (porting-order item 3) — in-game verified clean

**Status: ✅ in-game verified clean (2026-07-14).** `unit_score` + `find_proto`
ported to `lua/ai/build.lua`, `find_proto` hooked, RNG snapshot/restore
around the Lua call since it consumes `random(128)` (= `rand.map(0, 128)`,
same LCG as everything else). `LuaHostApi` bumped to `api_version=6` (12 new
entries), `BASE`'s first-ever `emit_struct` block (11 fields). Zero
mismatches across 769 calls, all 7 AI factions, broad branch coverage
(`defend` both true/false, 6 triad-flag combinations, 5 weapon modes).
Formally closed by the Consolidation gate (`IMPLEMENTATION_PLAN.md`).
Session narrative, the scope gaps found while transcribing the function
line-by-line: `DEVELOPMENT_DIARY.md`, 2026-07-14.

**Two durable traps worth keeping straight for future edits:**
- **`UNIT::offense_value()`/`defense_value()` vs `proto_offense()`/
  `proto_defense()` are real distinct functions, not a naming accident.**
  The tech pilot's `proto_offense_value`/`proto_defense_value`
  (`lua/api/tech.lua`) are `UNIT::offense_value()`/`defense_value()` — the
  raw `Weapon`/`Armor` field, no reactor multiplier. `unit_score`'s own
  `proto_offense`/`proto_defense` (`veh.cpp:3166-3182`, also in `tech.lua`)
  apply the reactor multiplier and a planet-buster special case. Both
  needed, kept separate — don't collapse them into one "helper."
- **`defend`'s int-vs-boolean trap.** `lua_ai_hook` passes bool-shaped args
  as a raw `0`/`1` int (Lua's `0` is truthy, unlike C's), so `find_proto`/
  `unit_score` both normalize `defend` to a real Lua boolean on entry —
  same class of bug `lua/ai/social.lua`'s `pop_boom` routes around with
  explicit `~= 0` checks, centralized here into one conversion instead of
  scattering `~= 0` across every use site.

`UNIT`'s new inline-method re-exposures (`proto_is_missile`,
`proto_is_planet_buster`, `proto_is_psi_unit`, `proto_is_colony`,
`proto_is_prototyped`, `proto_triad`, `proto_range`) and
`proto_offense`/`proto_defense` landed in the existing `lua/api/tech.lua`
rather than a new `unit.lua` — it already owns every `CChassis`/
`CWeapon`/`UNIT` accessor they need. New `lua/api/base.lua`: `BASE` is a
mutable, re-pointable pointer (like `Vehs`, 3.2), so `get()` re-fetches it
via `LuaHostApi.bases_ptr()` on every access instead of caching one
`ffi.cast`.

`build.cpp` + `plan.cpp` are the biggest item in the porting order (the plan
calls it "the heart of the single-player challenge") and, unlike items 1/2/2b,
have **no cheap entry point**: every function here touches `BASE`, which has
had zero FFI exposure so far (deliberately deferred through items 1/2/2b).
Sizes found by reading the actual functions (not the earlier rough estimate):
`select_build` ~470 loc (also reads `Vehs[]` directly — needs `VEH` too, not
just `BASE`), `mod_base_hurry` ~309 loc (no per-base args at all — a
whole-game sweep, called once from `base.cpp:4056`), `design_units` ~308 loc,
`plans_upkeep` ~160 loc, `find_project` ~156 loc, `unit_score` ~105 loc,
`select_combat` ~94 loc, `governor_priorities` ~88 loc, `find_proto` ~62 loc,
`select_colony` ~44 loc, `former_plans` ~21 loc, `facility_score` 7 loc.

**Call graph matters more than size here.** Of all these, only two are ever
called from outside `build.cpp`/`plan.cpp`: `select_build(base_id)` (4 call
sites: `base.cpp` x3, `map.cpp`) and `find_proto(base_id, triad, mode,
defend)` (one call site outside the `select_*` chain: `base.cpp:1203`).
Everything else — `facility_score`, `governor_priorities`, `unit_score`,
`select_colony`, `select_combat` — is a private helper only ever reached
through one of those two. `select_build` needs `VEH` (a vehicle-counting
loop over `Vehs[]`) on top of `BASE`, so it's not a good first slice.
`find_proto` is: Class 1 pure query, real external caller, and its only
dependency chain (`unit_score` + a handful of small helpers) turned out to
be mostly cheap once actually read.

**Scope decided for this first slice: `unit_score` + `find_proto` only.**
`governor_priorities`/`facility_score`/`select_build` itself are left for a
later slice once `BASE`'s FFI footprint from this pass is already in place.

**New `BASE` fields (first exposure ever)** (`tools/gen_ffi.cpp`'s
`FIELD(BASE, ...)`, a new `emit_struct` block): `faction_id`,
`governor_flags`, `production_id_last`, `mineral_surplus`,
`minerals_accumulated`, `mineral_consumption`, `specialist_adjust`,
`state_flags`, `nerve_staple_turns_left`, `drone_total`, `talent_total`.

**New `UNIT` fields:** `plan`, `ability_flags`, `cost`.
**New `CChassis` fields:** `triad`, `range`, `missile`.
**New `CWeapon` field:** `mode`.
**New `CRules` fields:** `retool_penalty_prod_change`, `retool_exemption`,
`extra_cost_prototype_sea`, `extra_cost_prototype_air`,
`extra_cost_prototype_land`.
**New `Faction` fields:** `player_flags_ext`, `diff_level`,
`SE_support_pending`.

**New enums** (all already visible to `gen_ffi.cpp` via the headers it
already includes — `engine_veh.h`/`engine_base.h`, not `engine_enums.h`,
so no new `#include` needed, just `printf` lines): `PLAN_PLANET_BUSTER`,
`PLAN_COLONY`, `BSTATE_PRODUCTION_DONE`, `RETOOL_ALWAYS_FREE`,
`RETOOL_FREE_PROJECT`, `RFLAG_FREEPROTO`, `GOV_MAY_PROD_NATIVE`,
`GOV_MAY_PROD_PROTOTYPE`, `GOV_MAY_PROD_AIR_COMBAT`,
`GOV_MAY_PROD_AIR_DEFENSE`, `FAC_BROOD_PIT`, `FAC_BIOLOGY_LAB`,
`FAC_CENTAURI_PRESERVE`, `FAC_TEMPLE_OF_PLANET`, `FAC_SKUNKWORKS`,
`FAC_PUNISHMENT_SPHERE`, `TRFLAG_LAND`, `TRFLAG_SEA`, `TRFLAG_AIR`,
`WMODE_COMBAT`, `WMODE_COLONY`, `WMODE_PROBE`, `WMODE_TERRAFORM`,
`WMODE_SUPPLY`, `WMODE_TRANSPORT`, `PFLAG_EXT_STRAT_LOTS_MISSILES`,
`PFLAG_EXT_STRAT_LOTS_ARTILLERY`, and the 17 `ABL_*` flags `unit_score`'s
`specials` table and a few other branches read directly (`ABL_AAA`,
`ABL_AIR_SUPERIORITY`, `ABL_ALGO_ENHANCEMENT`, `ABL_AMPHIBIOUS`,
`ABL_DROP_POD`, `ABL_EMPATH`, `ABL_TRANCE`, `ABL_SLOW`, `ABL_TRAINED`,
`ABL_COMM_JAMMER`, `ABL_ANTIGRAV_STRUTS`, `ABL_BLINK_DISPLACER`,
`ABL_DEEP_PRESSURE_HULL`, `ABL_SUPER_TERRAFORMER`, `ABL_ARTILLERY`,
`ABL_POLICE_2X`, `ABL_CLEAN_REACTOR`).

**Kept opaque (host wrappers), not ported — engine mechanics/eligibility
gates, not AI policy, same precedent as `social_calc`/`great_beelzebub`:**
- `mod_veh_avail(unit_id, faction_id, base_id)` — unit-buildable eligibility
  gate; ~15 arbitrary `WPN_*`/`ABL_*`/expansion-pack special cases plus a
  map query (`is_coast`), not worth porting for a boolean gate.
- `has_abil(unit_id, ability)` — capability check with an alien-race special
  case (`ABL_DEEP_RADAR`).
- `has_fac_built(item_id, base_id)` — new, **generic** (any facility, any
  base), unlike the existing `has_project`/`has_free_facility` which are
  faction-level. Needed by `find_proto` (4x, psi-native techs) and
  `unit_score` (`FAC_SKUNKWORKS`) and `base_can_riot` (`FAC_PUNISHMENT_
  SPHERE`) — cheap enough as a single wrapper reused across all three
  rather than porting `BASE::has_fac_built()`'s bitmask logic three times.
- `conf` accessors (Thinker-internal, not FFI-mapped, same pattern as
  `tech_balance_enabled`/`social_ai_bias`): `ignore_reactor_power()`,
  `long_range_artillery()`, `modify_unit_support()`.
- `AIPlans` accessors (same pattern as `defense_modifier`/`keep_fungus`):
  `psi_score(faction_id)`, `missile_units(faction_id)`,
  `median_limit(faction_id)`, `max_offense_value(faction_id)`,
  `max_defense_value(faction_id)`.

**Ported directly to Lua** (all turned out to be cheap once read — mostly
one-line `BASE`/`UNIT` inline methods dropped by field-only cdef generation,
same category as the tech pilot's `proto_offense_value`/`proto_defense_value`/
`proto_speed`):
- `UNIT` inline methods: `is_missile`, `is_planet_buster`, `is_psi_unit`,
  `is_colony`, `is_prototyped`, `triad`, `range` — all 1-3 line field
  comparisons (`engine_veh.h:401-470`).
- `BASE` inline methods: `gov_config()` (`is_human(faction_id) ? governor_
  flags : ~0u`), `SE_police(pending)`, `plr_owner()` (`is_human(faction_id)`).
- Free functions `proto_offense(unit_id)`/`proto_defense(unit_id)`
  (`veh.cpp:3166-3182`) — **not** the same computation as the tech pilot's
  `proto_offense_value`/`proto_defense_value` (those are `UNIT::offense_
  value()`/`defense_value()`, i.e. the raw weapon/armor field with no
  reactor multiplier; these apply the reactor multiplier and a
  planet-buster special case). Different functions, same name pattern —
  worth flagging so nobody assumes the tech pilot already covered this.
- `need_police`, `unit_support_plan`, `check_retool` (currently a `static`
  helper local to `build.cpp`, used by both `unit_score` and, later,
  `select_build`), `proto_extra_cost`, `prototype_factor`, `base_can_riot`,
  `unit_is_better`.
- `unit_score(base_id, unit_id, psi_score, psi_atk, psi_def, defend)` —
  the scoring function itself.
- `find_proto(base_id, triad, mode, defend)` — the hook.

**RNG:** `find_proto` calls the mod's own LCG once per candidate,
`random(128)` — confirmed (`src/random.cpp:41-58`) to be the exact same
`random_seed` stream as `random_get`/`rand.map`, just with `low=0`
(`random(limit)` is arithmetically `random_get(0, limit)`), so this is
`rand.map(0, 128)` in Lua, no new binding needed. Because it consumes RNG,
the dual-run seam needs the same snapshot/restore dance as `mod_tech_ai`
(`random_state()` before the Lua call, `random_reseed()` before the real
C++ body runs), not the simpler snapshot-free pattern `mod_wants_to_attack`
got away with.

**Files to touch when implementing:** `tools/gen_ffi.cpp` (new `BASE`
`emit_struct` block + the other fields/enums above), `src/luaai.h` +
`src/luaai.cpp` (8 new `LuaHostApi` entries, `api_version` bump to 6),
`src/build.cpp` (seam in `find_proto`, RNG snapshot/restore), a new
`lua/api/base.lua` (BASE accessors, mirroring `lua/api/faction.lua`'s
shape), `lua/api/tech.lua` or a new module for the `UNIT` methods above
(needs a decision: extend the tech pilot's existing UNIT re-exposures or
start a separate `lua/api/unit.lua` — the tech pilot's are proto-value
methods reused by scoring generally, not tech-specific, so a shared
`unit.lua` may be the cleaner home now that a second consumer exists),
`lua/ai/build.lua` (new file: `unit_score` + `find_proto`, provenance
pointing at `src/build.cpp`), `lua/ai/init.lua` (register the hook).

---

### 4.8 Production/plans port, second slice: `select_colony`/`select_combat` — in-game verified clean

**Status: ✅ in-game verified clean (2026-07-14).** Both ported to
`lua/ai/build.lua`, hooked. `LuaHostApi` bumped to `api_version=7` (17 new
entries — one more than originally scoped, `ocean_colony_land_site` for a
`select_colony` tile scan the scoping pass missed). `check_probe`
(`build.cpp`) lost its `static` to be reachable from `luaai.cpp`. First
in-game run found a real bug (`BASE.x`/`BASE.y` missing from the FFI); fixed,
second run confirmed clean — zero mismatches on all three hooks. Formally
closed by the Consolidation gate (`IMPLEMENTATION_PLAN.md`). Both consume
RNG conditionally in several places (short-circuit `||`/`&&` chains gating
`random()` calls) — careful call-order preservation held up under live
exercise, but stays easy to get subtly wrong with more volume; a `b2n(bool)`
local helper was added to `build.lua` since this pair has far more C
boolean-to-int arithmetic than `unit_score`/`find_proto` did. Session
narrative and the bug hunt: `DEVELOPMENT_DIARY.md`, 2026-07-14.

Intermediate step between the first slice (4.7) and `select_build` itself:
`select_build` (454 loc, ~45 `build_order` items, a `std::priority_queue`
output mechanism, dozens of helper calls) is too large to scope and
implement in one pass the way every prior item was — see the status note
left in place of a 4.9 draft when this was surveyed. `select_colony`
(build.cpp:689-731, ~43 loc) and `select_combat` (build.cpp:733-803, ~71
loc) are two of its internal helpers: not independently called from
outside `build.cpp` either (same as `facility_score`/`governor_priorities`),
but each already calls `find_proto`, which now exists in Lua — porting
them extends the helper library `select_build` will eventually need,
without yet requiring `select_build`'s own scope (`VEH` exposure, the
priority queue).

**Validation still works despite no external caller.** The dual-run seam
doesn't care who calls the hooked C++ function — `select_build` (still
pure C++) calls `select_colony`/`select_combat` on every real production
decision, so hooking them directly (same pattern as `find_proto`) still
gets exercised live and dual-run-compared during ordinary play, the same
as if they had an external caller.

**New territory this slice touches that no prior item has: map/tile
queries.** Every prior FFI addition was a struct field. `select_colony`/
`select_combat` call several functions that reach into `TileSearch`/`MAP`
(`has_base_sites`, `is_ocean`, `map_range`) or `VEH` (`check_probe`,
build.cpp's own static helper, loops `Vehs[]`) — none of which this
project has opened up yet (`TileSearch`/`MAP` per plan 4.3 stay in C++
entirely; `VEH` is deferred to `select_build` itself). Kept opaque
(host wrappers), same "engine mechanics, not AI policy" precedent as
`mod_veh_avail`/`great_beelzebub`:
- `has_base_sites(x, y, faction_id, triad)` — wraps `path.cpp:429`,
  constructs its own local `TileSearch` internally (Lua never touches
  `TileSearch`, per plan 4.3).
- `is_ocean(base_id)` — wraps the `BASE*` overload (`map.h:23`).
- `map_range(x1, y1, x2, y2)` — tile-distance formula (odd/even parity,
  wraparound); kept opaque rather than re-derived, to not risk a subtle
  map-geometry bug for a function this cheap to just call.
- `check_probe(base_id, triad)` — wraps `build.cpp`'s existing `static`
  helper (loops `Vehs[]`), rather than opening `VEH` for one boolean.
- `has_wmode(faction_id, mode)`, `has_pact(faction1, faction2)`,
  `at_war(faction1, faction2)`, `best_reactor(faction_id)` — simple
  existing Thinker functions, same tier as `has_treaty`/`is_human`.

**New `BASE` fields:** `defend_range`, `mineral_intake_2`.

**New `AIPlans` accessors** (same pattern as `defense_modifier`/
`psi_score`): `air_combat_units`, `transport_units`, `probe_units`,
`sea_combat_units`, `land_combat_units`, `contacted_factions`.

**New `conf` accessor:** `expansion_autoscale()`.

**New enums:** `PFLAG_EXT_STRAT_LOTS_COLONY_PODS`,
`PFLAG_EXT_STRAT_LOTS_SEA_BASES`, `DIFF_CITIZEN`,
`PFLAG_EMPHASIZE_AIR_POWER`, `PFLAG_EMPHASIZE_SEA_POWER`,
`PFLAG_EMPHASIZE_LAND_POWER`, `PFLAG_EXT_STRAT_LOTS_PROBE_TEAMS`,
`GOV_MAY_PROD_PROBES`, `GOV_MAY_PROD_TRANSPORT`,
`GOV_MAY_PROD_LAND_COMBAT`, `GOV_MAY_PROD_LAND_DEFENSE`,
`GOV_MAY_PROD_NAVAL_COMBAT`, `RFLAG_AQUATIC`.

**Ported directly:** `MFaction::is_aquatic()` (`rule_flags & RFLAG_AQUATIC`,
one-liner, same tier as `war.lua`'s local `is_alien` helper — kept local
to `build.lua` rather than added to `faction.lua`'s shared surface, same
precedent).

**RNG:** both functions call `random()` (`rand.map`) directly, same as
`find_proto` — both seams need the snapshot/restore treatment.

**Files to touch when implementing:** `tools/gen_ffi.cpp` (2 `BASE`
fields, 13 enums), `src/luaai.h` + `src/luaai.cpp` (16 new `LuaHostApi`
entries — 8 opaque wrappers, 6 `AIPlans` accessors, 1 `conf` accessor, 1
already covered — `api_version` bump to 7), `src/build.cpp` (seams in
`select_colony` and `select_combat`, mirroring `find_proto`'s), `lua/api/
faction.lua` or `base.lua` (wrapper accessors), `lua/ai/build.lua`
(extend: `select_colony`, `select_combat`, local `is_aquatic`),
`lua/ai/init.lua` (register both hooks).

---

### 4.9 Production/plans port, third slice: `governor_priorities`/`facility_score`

**Status: ✅ superseded (2026-07-16).** Originally shipped 2026-07-14 as
plain unhooked Lua functions, "validated by inspection" only (see below for
why). The Consolidation gate's typed hook-descriptor refactor (5.1.1) later
generalized `lua_ai_hook`'s contract to fix this gap — both functions are
shadow-hooked in `src/plan.cpp` today, confirmed live with zero divergences,
and have golden-trace fixtures (5.2.1). The reasoning below (why the
original hook contract couldn't express these two) is kept as the record of
why the refactor was needed.

The last two `select_build` helpers cheap enough to be worth doing before
`select_build` itself. Both are tiny: `facility_score` (`plan.cpp:8-13`, 6
loc) needs nothing new — every `CFacility` field it reads (`AI_fight`,
`AI_growth`, `AI_power`, `AI_tech`, `AI_wealth`) has been in the FFI since
the tech pilot. `governor_priorities` (`plan.cpp:15-31`, 17 loc) needs one
new `BASE` field (`defend_goal`) and four enums
(`GOV_PRIORITY_EXPLORE`/`DISCOVER`/`BUILD`/`CONQUER`) — everything else
(`governor_flags`, `is_human`, `Faction.AI_growth/AI_tech/AI_wealth/
AI_power/AI_fight`) is already exposed.

**Neither can be hooked — this is the load-bearing difference from every
prior item.** `find_proto`/`select_colony`/`select_combat` all return a
single `int`, fitting `lua_ai_hook`'s int-args-in/int-result-out contract
exactly, even with no external caller. `facility_score` returns `int` but
takes a `WItem&` *input*; `governor_priorities` is `void` and writes into
a `WItem&` *output* (5 fields: `AI_growth`, `AI_tech`, `AI_wealth`,
`AI_power`, `AI_fight`). Packing 5 small ints into one for the sake of a
temporary dual-run check would need a new hook shape — exactly the
"zoo of `lua_ai_hook_i/_ii/_b/_v` variants" the plan (4.1) rules out.

**Consequence: these two ship as plain, unhooked Lua library functions,
validated by inspection now, not by a live dual-run.** They'll get real
in-game exercise transitively once `select_build` itself is ported and
hooked (it calls both), or via Phase 5.2's golden-trace/replay runner once
that exists — neither of which changes today. This is a deliberate,
narrower kind of "done" than every other function in this file: implemented
and syntax-checked, not dual-run-verified. Low risk given the size (23 loc
combined, no RNG, no branching deeper than one `if`/`else`), but worth
stating plainly rather than letting the usual "in-game verified clean"
header imply something that didn't happen this time.

**`WItem` representation in Lua:** a plain table (`{AI_growth=.., AI_tech=..,
AI_wealth=.., AI_power=.., AI_fight=..}`), not an FFI struct — `lua/ai/`
never touches `ffi` and there's no engine-memory backing to justify one
here; `WItem` only ever exists as a short-lived scoring accumulator both in
C++ and now in Lua.

**Files to touch when implementing:** `tools/gen_ffi.cpp` (`BASE.
defend_goal`, 4 `GOV_PRIORITY_*` enums), `lua/ai/build.lua` (extend:
`facility_score`, `governor_priorities`, both unhooked), no `LuaHostApi`/
`luaai.cpp`/`luaai.h` changes needed (nothing new to wrap — both are pure
field reads once the two additions above land), no `lua/ai/init.lua`
change (nothing to register).

---

### 4.10 `select_build` itself (porting-order item 3, final piece) — steps 1-4 implemented, live verification of step 4 is the resume point

**Current state:** steps 1-2 done and live-verified; step 3 (the
`build_order` loop) is entirely done — shared prologue (4.10.12),
`DefendUnit`/`CombatUnit`'s early-return decision (4.10.13), the loop
skeleton + 14 no-branch facilities (4.10.14), and the full facility- and
unit-type branch catalog, all 47 `build_order[]` entries (4.10.15–4.10.30,
consolidated into one lean section below). **Step 4 — wiring the real
`select_build` hook — is implemented** (4.10.31): the first hook in the
project whose return value actually drives the game, build-verified,
**live verification is the resume point**; see `IMPLEMENTATION_PLAN.md`
item 3 for current status. Sections 4.10.1-4.10.9 below are the original
2026-07-14 scoping pass — still useful background on `VEH`/field
locations, but check any specific "already exposed" claim against
`lua/ffi/types.lua` directly before trusting it; later sessions found it
wrong more than once. Session narrative and bug hunts for steps 1-3.4:
`DEVELOPMENT_DIARY.md`, 2026-07-14/16.

Full read of `select_build` (`src/build.cpp:867-1334`, 467 loc — the
number quoted when this was first surveyed, 454, was a rough estimate;
this is the exact span) plus its last unscoped dependency, `push_item`
(`build.cpp:845-865`, its only caller). This section is meant to be
sufficient on its own to start implementing next session without
re-reading `select_build` from scratch — it's long because the function
is long, not because the individual pieces are hard.

#### 4.10.1 `VEH` — first exposure, scope confirmed narrow

`VEH` is touched in exactly one place in `select_build`: the vehicle-count
loop at `build.cpp:913-955`, iterating `Vehs[]` once to compute `formers`,
`pods`, `landprobes`/`seaprobes`, `transports`, `allow_supply`,
`scouts`, `defenders`, `near_formers`, `artifacts`, `all_crawlers`,
`need_ferry`. Nowhere else in the function reads `Vehs[]`/`VEH` directly.
That means `VEH`'s FFI footprint for this port is genuinely small — the
size risk in `select_build` is everywhere else (see 4.10.2-4.10.4), not
here.

**New `VEH` fields** (first `emit_struct` block for `VEH`, mirroring how
`BASE` was introduced in 4.7): `faction_id` (`uint8_t`), `unit_id`
(`int16_t` — needed to delegate to the already-exposed `UNIT`/`tech.lua`
accessors, see below), `home_base_id` (`int16_t`), `x`/`y` (`int16_t`,
same trap already hit once for `BASE` — don't repeat it), `order`
(`uint8_t`, compared against `ORDER_CONVOY = 3`, `engine_veh.h:259`).

**`VEH`'s inline methods used here all delegate to already-exposed `UNIT`
methods, except two.** `engine_veh.h:595-631`:
- `veh:is_former()` / `is_probe()` / `is_supply()` / `is_transport()` /
  `is_artifact()` / `is_colony()` → pure delegation to
  `Units[unit_id].is_X()`. `is_colony` is already `tech.proto_is_colony`
  (4.7). The other four are new one-liners on `UNIT` (`plan ==
  PLAN_TERRAFORM/PLAN_PROBE/PLAN_SUPPLY/PLAN_NAVAL_TRANSPORT/PLAN_ARTIFACT`
  respectively, `engine_veh.h:468-479`) — same tier as the `tech.proto_is_*`
  functions already in `tech.lua`, add alongside them:
  `proto_is_former`, `proto_is_probe`, `proto_is_supply`,
  `proto_is_transport`, `proto_is_artifact`. `PLAN_SUPPLY`/`PLAN_PROBE`/
  `PLAN_TERRAFORM` are already exposed (4.7, `unit_support_plan`);
  `PLAN_NAVAL_TRANSPORT` already exposed (M4-era); new: `PLAN_ARTIFACT`
  (`engine_veh.h:143`).
- `veh:triad()` (`engine_veh.h:517`) → identical formula to
  `UNIT::triad()`, i.e. reuse `tech.proto_triad(veh.unit_id)` directly,
  no new function needed.
- `veh:is_combat_unit()` (`engine_veh.h:595-597`) is **not** pure
  delegation: `Units[unit_id].is_combat_unit() && unit_id != BSC_FUNGAL_TOWER`.
  Needs a new `UNIT`-level `proto_is_combat_unit(unit_id)` in `tech.lua`
  (`Weapon[weapon_id].offense_value ~= 0`, `engine_veh.h:449-450`) plus
  the `BSC_FUNGAL_TOWER` (`= 19`) enum, then the `veh`-level wrapper adds
  the exclusion.
- `veh:is_garrison_unit()` (`engine_veh.h:598-600`) → delegates to
  `Units[unit_id].is_garrison_unit()` = `(plan <= PLAN_RECON || (plan ==
  PLAN_PROBE && is_armored())) && triad() == TRIAD_LAND`
  (`engine_veh.h:455-457`), which itself needs a new `UNIT`-level
  `proto_is_armored(unit_id)` (`Armor[armor_id].defense_value ~= 1`,
  `engine_veh.h:446-447`). `PLAN_RECON`/`TRIAD_LAND` already exposed.
- `veh:eval_garrison()` (`engine_veh.h:690-692`) = `(triad()==TRIAD_LAND
  ? 2:1) + is_combat_unit() + is_armored()` — portable once the two
  pieces above exist; note this one needs `is_armored()` at the **VEH**
  level too, which is pure delegation to the new `proto_is_armored` above.

None of this needs new host wrappers — every piece is a field read or a
one-line boolean already backed by tables `tech.lua` has open.

#### 4.10.2 The other `iterate_tiles`/`MAP` loop — same treatment as 4.8's

Separate from `select_colony`'s land-site scan (4.8), `select_build` has
its own tile loop for `FormerUnit` scoring (`build.cpp:1117-1124`):
iterates `iterate_tiles(base->x, base->y, 1, 21)`, reads `m.sq->owner`,
`base->worked_tiles`, `m.sq->items`, calls `select_item(m.x, m.y,
faction_id, FM_Auto_Full, m.sq)` (`move.h:43`, itself takes a raw `MAP*`)
and `is_ocean(m.sq)`, accumulating two counters (`num`, `sea`). Same
reasoning as `ocean_colony_land_site`: not worth opening `MAP`/
`iterate_tiles`/`FormerMode` to Lua for one loop. Plan: a new opaque
wrapper, e.g. `former_tile_scan(base_id) -> {num, sea}` (two return
values, or pack as `num*1000+sea`-style if `LuaHostApi`'s int-only
return becomes awkward — decide at implementation time), replicating
`build.cpp:1117-1124` verbatim in C++.

#### 4.10.3 New fields (straightforward — one `emit_struct`/`FIELD` line each)

**`BASE`** (extending 4.7-4.9's block): `pop_size` (`int8_t`),
`nutrient_surplus`, `energy_surplus`, `energy_inefficiency`,
`mineral_intake`, `eco_damage`, `specialist_total`, `worked_tiles`
(all `int32_t`), `assimilation_turns_left` (`uint8_t`), `queue_items`
(`int32_t[10]`, only `queue_items[0]` read here — via the `item()`/
`item_is_project()` methods below).

**`BASE` inline methods to re-port** (same tier as `gov_config`/
`se_police`, `engine_base.h:221-234`): `item()` (`queue_items[0]`),
`item_is_project()` (`queue_items[0] <= -SP_ID_First`),
`drone_riots_active()` (`state_flags & BSTATE_DRONE_RIOTS_ACTIVE`),
`drone_riots()` (`drone_total > talent_total`, both fields already
exposed).

**`Faction`** (extending prior blocks): `SE_effic_pending`,
`SE_growth_pending`, `SE_alloc_labs`, `SE_alloc_psych`, `SE_planet_pending`,
`clean_minerals_modifier` (all `int32_t`).

**`AIPlans`** (new accessors, same one-field-per-wrapper pattern as
`psi_score`/`defense_modifier`; note two of these are genuinely `float`,
not `int` — see 4.10.5): `project_limit` (int), `enemy_mil_factor`
(**float**), `enemy_base_range` (**float**), `enemy_bases` (int),
`main_region` (int), `target_land_region` (int), `naval_start_x` (int),
`naval_start_y` (int), `energy_limit` (int).

**`CRules`**: `drones_induced_genejack_factory` (new). `artillery_max_rng`
is already exposed (added in 4.7 for `unit_score`'s artillery scoring) —
noted here only so it isn't mistakenly re-added.

**`ResInfo` (`CResourceInfo`, `engine_types.h:599`, global at
`Rules.h`-adjacent address `ResInfo`)**: only
`ResInfo->recycling_tanks.{energy,nutrient,mineral}` is read
(`FAC_RECYCLING_TANKS` scoring). This is a **new global struct**, not a
field addition to an existing one — smallest reasonable slice is exposing
just the `recycling_tanks` sub-struct (3 ints) rather than all of
`CResourceInfo` (144 bytes per the existing `static_assert`,
`engine.h:228` — almost certainly has many more resource-type sub-structs
unrelated to this one score term).

#### 4.10.4 New enums (all already visible via the four headers `gen_ffi.cpp` includes)

`FAC_ORBITAL_DEFENSE_POD`, `SP_ID_First`, `SP_ID_Last`, `Fac_ID_Last`
(bounds used in `push_item`/the facility loop), `PLAN_ARTIFACT`,
`BSC_FUNGAL_TOWER`, `ORDER_CONVOY`, `GOV_MAY_PROD_FACILITIES`,
`GOV_MAY_PROD_SP`, `GOV_ALLOW_COMBAT`, `GOV_MAY_PROD_EXPLORE_VEH`,
`GOV_MAY_FORCE_PSYCH`, `GOV_MAY_PROD_COLONY_POD`, `RULES_SCN_NO_TECH_ADVANCES`
(already have), `BIT_FOREST`, `BIT_SIMPLE`, `BIT_ADVANCED` (tile-item
flags — only needed if 4.10.2's tile-scan wrapper is written in a way
that re-derives them; likely stays entirely inside the opaque wrapper and
never needs a Lua-side enum at all), `FAC_VIRTUAL_WORLD`,
`FAC_CLONING_VATS` (already have), `FAC_TREE_FARM`/`FAC_HYBRID_FOREST`/
`FAC_RECREATION_COMMONS`/`FAC_HOLOGRAM_THEATRE`/`FAC_RESEARCH_HOSPITAL`/
`FAC_PARADISE_GARDEN`/`FAC_NETWORK_NODE`/`FAC_GENEJACK_FACTORY`/
`FAC_ROBOTIC_ASSEMBLY_PLANT`/`FAC_NANOREPLICATOR`/`FAC_QUANTUM_CONVERTER`/
`FAC_COMMAND_CENTER`/`FAC_NAVAL_YARD`/`FAC_BIOENHANCEMENT_CENTER`/
`FAC_PERIMETER_DEFENSE`/`FAC_TACHYON_FIELD`/`FAC_GEOSYNC_SURVEY_POD`/
`FAC_FLECHETTE_DEFENSE_SYS`/`FAC_PSI_GATE` — every `build_order` facility
ID branched on by name in the scoring loop; most are only used as `int`
constants for `t == FAC_X` comparisons and don't need special handling
beyond appearing in the enum table once each. **Don't try to pre-verify
every one of these against `engine_enums.h` by hand before starting** —
follow the established discipline (3.1): let the generator/compiler catch
a typo'd or missing name as a build error, same as every prior slice.

#### 4.10.5 Opaque host wrappers needed (engine mechanics, not AI policy — established precedent)

`mod_base_making(item_id, base_id)` (`base.h:23`), `can_build(base_id,
item_id)` (`base.h:68`), `can_build_unit(base_id, unit_id)` (`base.h:69`),
`has_ships(faction_id)` (`faction.h:13`), `adjacent_region(x, y, owner,
threshold, ocean)` (`map.h:29` — another `MAP`-touching function, stays
opaque like `map_range`/`is_ocean`), `allow_expand(faction_id)`
(`faction.h:31`), `mod_psych_check(faction_id, &content_pop, &base_limit)`
(`base.h:42` — **two int32_t out-params**; wrapper needs to return both,
e.g. pack into one `int32_t` return via two 16-bit halves, or add a second
`LuaHostApi` entry — decide at implementation time, same open question as
4.10.2's tile scan), `facility_count(item_id, faction_id)` (`faction.h:17`),
`mineral_output_modifier(base_id)` (`base.h:55`),
`base_unused_space(base_id)` (`base.h:50`), `need_scouts(base_id, triad)`
(`build.h:12`), `find_satellite(base_id)` (`build.h:9` — not read yet,
budget time to check its body before assuming it's a clean wrapper
candidate), `find_project(base_id, Wgov)` (`build.h:11` — **not** yet
read either; takes a `WItem&` like `facility_score`/`governor_priorities`
in 4.9, so it has the same "doesn't fit the hook contract" question, but
unlike those two it might get called from a hooked `select_build`, which
changes the calculus — read this one first when resuming).

**Portable directly (small, already-legible, no new engine surface):**
- `skip_facility(base, item_id)` (`build.cpp:6-9`, `static`): `base->
  plr_owner() && item_id >= 1 && item_id <= 64 && conf.skip_gov_facility
  & (1 << (item_id - 1))`. Needs a `conf.skip_gov_facility` host accessor
  (same tier as `conf.ignore_reactor_power` etc.) since `conf` is
  Thinker-internal.
- `has_retool(base_id, item_id, retool)` (`build.cpp:30-32`, `static`):
  `retool != -1 && retool != 0 && retool != mod_base_making(item_id,
  base_id)` — trivial once `mod_base_making` is wrapped (above).
- `push_item`'s own scoring body (`build.cpp:845-865`) — not a hook, a
  plain helper the eventual `select_build` port calls locally to build up
  its candidate list (see 4.10.6).

#### 4.10.6 The priority queue has a simpler Lua equivalent than it looks

`score_max_queue_t` (`std::priority_queue<SItem, ..., std::less<SItem>>`,
`plan.h:5-34`) reads as "maintain a heap of scored candidates" but
`select_build` only ever calls `.size()` and `.top()` **once**, at the
very end (`build.cpp:1326-1328`) — never `.pop()`, never iterates.
`SItem::operator<` breaks ties by `item_id` (`plan.h:9-12`). That means
the C++ priority queue is doing no more work than a running
"best-so-far" tracker would — exactly the `best_id`/`best_val` pattern
`find_proto` (4.7) already uses. **No heap/priority-queue data structure
needs porting to Lua at all**: track `(best_item_id, best_score)` across
every `push_item`-equivalent call, updating on `score > best_score or
(score == best_score and item_id > best_item_id)`, and that's
`builds.top()`.

#### 4.10.7 Float arithmetic — the first time it matters in this project

`Wbase`/`Wthreat` (`build.cpp:963-975`) are genuine C `float` computations
(`1.0f`, `4.0f`, `0.05f` literals; `AIPlans.enemy_mil_factor`/
`enemy_base_range` are themselves `float` fields, 4.10.3). Every prior
port has been integer arithmetic requiring `idiv`/`imod` specifically
*because* Lua's native `/` floors instead of truncating — but for this
block the **C code itself is doing float division**, not integer
truncation, so plain Lua `/` is the *correct* translation here, not
`idiv`. Double-check each division in this specific block against
whether the C operands are `float`/`int` before reflexively reaching for
`idiv` — using `idiv` on a genuinely-float expression would be the wrong
kind of bug (introducing integer truncation where the original had
none), the mirror image of every previous integer-division trap this
project has documented.

#### 4.10.8 Hook shape

Class 2 per the plan's own table (`build.cpp` / `select_build` is the
plan's canonical Class 2 example, `IMPLEMENTATION_PLAN.md` 4.1). Multiple
early-return points (`build.cpp:1080`, `1089`, `1095`, plus the final
`builds.top()`/fallback/`select_combat` returns) — needs the
`report_and_return` lambda pattern (`mod_tech_val`, `select_colony`/
`select_combat`), not `find_proto`'s single-exit pattern. Consumes RNG in
several places (`random(32)` per `build_order` item, plus more inside
individual branches) — snapshot/restore around the Lua call, same as
every RNG-consuming hook so far. `select_build` itself already calls
`plans_upkeep(faction_id)` unconditionally when `base->plr_owner()`
(`build.cpp:875`) — that stays in C++ untouched (`plans_upkeep` is not in
scope for this slice, still a `void` orchestration function with no
hook-compatible shape, same family of problem as 4.9).

#### 4.10.9 Recommended approach for next session

Given the size (467 loc, ~50 new fields/enums/wrappers cataloged above),
**don't attempt this as one sitting the way `unit_score`+`find_proto` was.**
A reasonable split, in order:
1. `VEH` `emit_struct` + the vehicle-count loop, as a standalone
   correctness check (port just `build.cpp:867-961` into a scratch
   function, print the counters, compare against the C++ `debug(
   "select_build %3d %3d %3d %3d def: %d frm: %d ..."` line already in
   the original at `build.cpp:977-981` — this line is a gift, it already
   logs most of the loop's outputs, so a mismatch is localized before
   the harder scoring loop is even touched).
2. `push_item` + the running-best tracker (4.10.6) + `has_retool`/
   `skip_facility`.
3. The `build_order` scoring loop itself (`build.cpp:1047-1325`), which
   is realistically its own multi-session effort given ~45 distinct
   `t == FAC_X` branches each with their own small scoring formula.
4. Wire the hook last, once 1-3 are individually confidence-checked —
   the dual-run mismatch log localizes *that* something's wrong, not
   *where*, and with this much surface a first-mismatch session could
   otherwise turn into a long, unfocused hunt.

---

### 4.10.10 Step 1 session record (2026-07-14) — implemented; live-verified 2026-07-16 (see 4.10's status block above)

Implements exactly step 1 of 4.10.9's plan: `VEH`'s first-ever FFI exposure
plus a standalone correctness check for `select_build`'s own vehicle-count
loop (`build.cpp:913-955`). **Not a hook** — `select_build` itself is still
pure C++, unhooked (still true as of this writing; steps 2-3's work,
4.10.11-4.10.15, only ever added shadow/diagnostic comparisons, never
wired a real decision hook — that's step 4, still open).

**Why this isn't wired through the usual dual-run mismatch pattern:**
every other seam in this project (`find_proto`, `select_colony`,
`select_combat`, ...) compares a single `int` result via `lua_ai_hook`'s
int-args-in/int-result-out contract. The vehicle-count loop produces ~12
separate counters (`formers`, `pods`, `landprobes`, `seaprobes`,
`transports`, `allow_supply`, `scouts`, `defenders`, `near_formers`,
`artifacts`, `need_ferry`, `all_crawlers`), and packing all of them into
one comparable int would be exactly the kind of fragile ad hoc encoding the
project avoids. Since `select_build` itself already emits
`debug("select_build %3d %3d %3d %3d def: %d frm: %d prb: %d crw: %d
pods: %d ... scouts: %d ...")` (`build.cpp:977-981`, covering six of the
twelve: `def`/`frm`/`prb`(landprobes+seaprobes)/`crw`(all_crawlers)/
`pods`/`scouts`), the cheapest correct check is: have the Lua port log the
same six fields (plus the other six as bonus coverage) in its own line,
and diff the two log files by eye for the same `(turn, base_id)` — no new
comparison machinery, at the cost of it being a manual check instead of an
automated mismatch line. This is a deliberately narrower kind of
verification than every other item in this file (same category as 4.9's
"validated by inspection", not 4.7/4.8's live dual-run).

**Files touched:**

- `tools/gen_ffi.cpp`: `VEH`'s first `emit_struct` block —
  `x`/`y`/`unit_id`/`faction_id`/`order`/`home_base_id` only (the loop's
  entire direct-field footprint, per 4.10.1's scan). New enums
  `PLAN_ARTIFACT`/`BSC_FUNGAL_TOWER`/`ORDER_CONVOY`/
  `GOV_MAY_PROD_TERRAFORMERS` (all already visible via the already-included
  `engine_veh.h`/`engine_base.h`, no new `#include`). New fixed-address
  global `VehCount = 0x9A64C8` (`int* const`, same tier as `BaseCount` —
  `Vehs` itself stays out of `globals` since it's mutable/re-pointable,
  3.2).
- `src/luaai.h` / `src/luaai.cpp`: one new `LuaHostApi` entry, `vehs_ptr()`
  (mirrors `bases_ptr()` exactly — returns `Vehs`' current pointer value,
  re-fetched by Lua on every access rather than cached). `api_version`
  7 → 8.
- `lua/ffi/funcs.lua`: matching cdef entry + binding for `vehs_ptr`,
  `HOST_API_VERSION` bumped to 8.
- `lua/api/tech.lua`: 8 new `UNIT`-level predicates, re-porting more of
  `engine_veh.h`'s inline methods the same way `proto_offense_value`/etc.
  already do — `proto_is_former`/`proto_is_probe`/`proto_is_supply`/
  `proto_is_transport`/`proto_is_artifact` (plain `plan == PLAN_X`
  comparisons), `proto_is_combat_unit` (`Weapon[weapon_id].offense_value ~=
  0`), `proto_is_armored` (`Armor[armor_id].defense_value ~= 1`), and
  `proto_is_garrison_unit` (composes the two: `(plan <= PLAN_RECON or
  (plan == PLAN_PROBE and proto_is_armored)) and proto_triad ==
  TRIAD_LAND`) — exactly the dependency chain 4.10.1 traced through
  `VEH::is_garrison_unit()` → `UNIT::is_garrison_unit()`.
- `lua/api/veh.lua` (new file): `count()`/`get(veh_id)` (re-fetching
  `Vehs` via `vehs_ptr()` on every call, same pattern as
  `lua/api/base.lua`'s `get()`), plus `VEH`'s own inline methods
  (`is_former`, `is_colony`, `is_probe`, `is_supply`, `is_transport`,
  `is_artifact`, `triad`) as pure delegation to the `tech.lua` predicates
  above on `veh.unit_id`, and the two non-delegating ones per 4.10.1:
  `is_combat_unit` (delegates, then additionally excludes
  `BSC_FUNGAL_TOWER`) and `eval_garrison` (`(triad==TRIAD_LAND and 2 or 1)
  + is_combat_unit + is_armored`).
- `lua/ai/build.lua`: new `vehicle_counts_check(base_id, sea_base)`,
  replicating `build.cpp:913-955` field-for-field (same
  if/elseif structure, same three independent conditions per vehicle —
  the home-base classification, the distance-based counters, and the
  sea-base ferry check). `sea_base` is passed in from C++ rather than
  recomputed, since it depends on `region_at()`, not wrapped for Lua yet
  (deferred alongside `adjacent_region`/`allow_expand`, 4.10.5); the
  initial value of `allow_supply` *is* computed in Lua though (`not
  sea_base and gov & GOV_MAY_PROD_TERRAFORMERS`), since that only needed
  the already-exposed `base_api.gov_config` plus one new enum — cheap
  enough not to defer. Logs one line via `log.debug` with the six fields
  the existing C++ debug line already has (`def`, `frm`, `prb`, `crw`,
  `pods`, `scouts`) plus six bonus fields (`lprb`/`sprb` split,
  `trn`/`near_frm`/`art`/`ferry`/`supply`) not in the original line but
  cheap to include since the loop computes them anyway. Uses `idiv` for
  the `(defenders+2)/8` truncating division per the project's integer
  rule, even though `defenders` is always non-negative here (so floor and
  truncate coincide) — consistent with the rule rather than relying on
  that coincidence.
- `lua/ai/init.lua`: registers `vehicle_counts_check` as a hook (needed
  so `register_hooks()` resolves it into `hook_refs` and
  `lua_ai_hook("vehicle_counts_check", ...)` can find it — it's not a real
  AI decision hook, just reusing the existing dispatch plumbing to get a
  Lua function called from C++ with zero new C++ infrastructure).
- `src/build.cpp`: one `lua_ai_hook("vehicle_counts_check", &dummy,
  {base_id, sea_base})` call inserted right after the vehicle-count loop
  closes, before `WItem Wgov; governor_priorities(...)`. The result is
  discarded (`dummy`) — this call exists purely for its side effect (the
  Lua-side `log.debug` call), not for a value C++ uses.

**Status: ✅ implemented and live-verified** (986/986 `vehicle_counts`/
`select_build` pairs matched exactly against a real `--golden-trace`
autoplay capture; `VEH`'s offsets hand cross-checked against
`engine_veh.h` and match exactly). Session narrative: `DEVELOPMENT_DIARY.md`,
2026-07-14/16.

**Once `select_build` is eventually fully ported and hooked, this temporary
seam should be removed** — the `lua_ai_hook("vehicle_counts_check", ...)`
call in `build.cpp`, its registration in `lua/ai/init.lua`, and arguably
`vehicle_counts_check` itself were only ever a scaffolding check for this
one step, not permanent AI logic — same fate as the other temporary
dual-run instrumentation elsewhere in this file.

### 4.10.11 Step 2 session record (2026-07-16) — implemented and live-verified, one real bug found and fixed

**Status: ✅ done.** `port_drift.py` clean at 14 tracked functions.
Live-verified against real autoplay data: first run found a real bug in the
diagnostic hook's own placement (not the port itself — double-applied score
adjustments); fixed, second run confirmed clean, 859/859. Session
narrative: `DEVELOPMENT_DIARY.md`, 2026-07-16.

Implements exactly step 2 of 4.10.9's order: `push_item`
(`build.cpp:816-836`) plus its two small dependents `has_retool`
(`build.cpp:32-34`) and `skip_facility` (`build.cpp:6-9`), ported to Lua
as standalone building blocks — **`select_build` itself is still
unported/unhooked**, steps 3-4 untouched.

**What was already exposed held up under direct re-checking, not just
trusted from the original scoping pass:** `BASE.minerals_accumulated`/
`mineral_surplus`, `UNIT.cost` (via `tech.proto(unit_id).cost`),
`CFacility.cost`/`.maint` (via `tech.facility(id).cost`/`.maint` — the
existing `facility()` accessor already returns the whole `CFacility`
cdata, not just the `AI_*` fields `facility_score` reads, so this needed
zero new FFI work) were all already exposed. Only new surface needed:

- **4 enums** (`FAC_ORBITAL_DEFENSE_POD`, `SP_ID_First`, `SP_ID_Last`,
  `Fac_ID_Last`), already visible via `engine_enums.h` (`gen_ffi.cpp`
  already includes it) — 4 `printf` emit lines, no new `#include`,
  confirmed via `git show`/direct header read before writing any code
  rather than assuming 4.10.4's claim.
- **2 new opaque `LuaHostApi` wrappers** (`src/luaai.h`/`.cpp`,
  `api_version` 9 → 10): `mod_base_making(item_id, base_id)` (real
  retool-category engine logic — Skunkworks/FREEPROTO exemptions — not
  AI policy, already non-`static` in `base.cpp`); `skip_gov_facility_bit
  (item_id)`, a **deliberate deviation** from 4.10.5's original "same
  tier as `conf.ignore_reactor_power`" sketch — `conf.skip_gov_facility`
  is a `uint64_t` bitmask, and splitting that through `LuaHostApi`'s
  `int32_t`-only convention into two halves would be awkward for no
  benefit, so this wraps the single-bit boolean query `skip_facility`
  actually needs instead of the raw config value.

**`has_retool`/`skip_facility`/`push_item` ported to Lua directly** (per
4.10.5's own "portable directly, small, already-legible" call) —
`build.cpp`'s originals are untouched, no reason to un-`static` them
since nothing calls the C++ versions from `luaai.cpp` (unlike
`check_probe`'s precedent, which *is* called from both sides).
`push_item`'s scoring math was split into a pure `push_item_score`
function so the temporary diagnostic hook (below) can reuse it without
needing a tracker.

**Running-best tracker (4.10.6) confirmed correct against
`SItem::operator<` (`plan.h:9-12`), not just assumed:** `score_max_queue_t`
is `std::priority_queue<SItem, ..., std::less<SItem>>` — a max-heap by
`operator<`'s ordering, so `.top()` returns the highest score, ties
broken by highest `item_id`. `select_build` only ever calls `.top()`/
`.size()` once, at the very end, never `.pop()`/iterates — so this really
is just "keep the best (score, item_id) pair seen so far," no heap
needed. Lua's `new_build_tracker()`/`push_item()` tie-break replicates
that ordering exactly.

**Temporary diagnostic hook, same precedent as step 1's
`vehicle_counts_check`.** `push_item()` already logs its own final
adjusted score via `debug("push_item %d %d %d %s\n", score, retool,
item_id, ...)` (`build.cpp:835`, now `843` after the new hook call) on
every one of its ~10 calls per `select_build` invocation
(`build.cpp:1044-1305`) — a gift, same as step 1's `select_build` debug
line. Added `push_item_check` (`lua/ai/build.lua`): computes
`push_item_score` independently and logs it via `log.debug`, registered
in `lua/ai/init.lua` the same way `vehicle_counts_check` is (reuses
existing hook dispatch, zero new C++ infrastructure beyond the one call
site in `build.cpp`). `has_retool` gets indirect coverage through
`push_item_score`; `skip_facility` isn't called by `push_item` at all
(used elsewhere in `select_build`'s still-unported main body) — left
"validated by inspection" for now, same category 4.9 originally used,
closed for real once step 4 wires the actual hook.

**`port.source` entries added** for `has_retool`/`skip_facility`/
`push_item` (same pinned commit as everything else in this file) —
`push_item_check` isn't tracked, it has no C++ equivalent (diagnostic-only,
no upstream function it ports). `tools/port_drift.py` confirms 14 clean,
0 drifted.

`push_item`/`push_item_score`/`has_retool` confirmed correct against real
captured data (859/859 clean after the fix above), not just build-clean
code. `skip_facility` still untested (not called by `push_item`) — closes
with step 4's real hook.

**Files touched:** `tools/gen_ffi.cpp` (4 enum emit lines), `src/luaai.h`/
`.cpp` (2 new `LuaHostApi` entries + wrappers, `api_version` bump),
`lua/ffi/funcs.lua` (matching cdef + wrappers, `HOST_API_VERSION` bump),
`lua/ai/build.lua` (`has_retool`, `skip_facility`, `push_item_score`,
`new_build_tracker`, `push_item`, `push_item_check`, three new
`port.source` entries), `lua/ai/init.lua` (registers `push_item_check`),
`src/build.cpp` (one hook call inside `push_item()`).

### 4.10.12 Step 3 sub-step 1 session record (2026-07-16) — the shared prologue, implemented and live-verified

**Status: ✅ done.** `port_drift.py` clean at 15 tracked functions,
live-verified: 556/556 lines match exactly (after fixing an ordering bug,
not a math bug — see `DEVELOPMENT_DIARY.md`, 2026-07-16, for the hunt).

**Scope, and why it's narrower than "step 3" sounds.** Read the full
current `select_build` body (`build.cpp:847-1324`, 478 lines) before
planning anything, rather than trusting 4.10.1-4.10.9's 2026-07-14
scoping pass at face value — it turns out to be accurate about the
overall shape but hadn't actually enumerated the branches. After the
prologue, the `build_order[]` loop has **9 special unit-type branches**
(`Satellites`/`SecretProject`/`DefendUnit`/`CombatUnit`/`FormerUnit`/
`SeaProbeUnit`/`CrawlerUnit`/`FerryUnit`/`ColonyUnit`) followed by **~35
individual `t == FAC_X` facility branches**, each with its own bespoke
formula — genuinely as large as 4.10.9 warned; the "~35"/"confirmed by
counting" here still overclaimed precision — the actual count (4.10.15,
done programmatically) is 15 code blocks covering 24 facility IDs, not
~35 of either. This session ported only the shared
**prologue through `Wbase`/`Wthreat`** (`build.cpp:847-965`) — nothing
that depends on it (no unit branches, no facility branches) is touched.
This unblocks everything downstream and was independently verifiable the
same way steps 1-2 were: `select_build` already has a `debug(...)` line
printing exactly `min`/`res`/`limit`/`mil`/`threat` plus the six vehicle-
count fields step 1 already covers.

**New engine surface, checked against current source directly (not the
old scoping notes):** 2 new `BASE` fields (`pop_size`, `nutrient_surplus`,
for `allow_pods`); 1 new `types.counts` entry (`MaxEnemyRange = 50`,
hardcoded literal — `gen_ffi.cpp` doesn't include `main.h`, same
precedent `MaxRegionLandNum` already used); 8 new opaque `LuaHostApi`
wrappers (`api_version` 10 → 11): `region_at`/`allow_expand` (real engine
mechanics), and 6 `AIPlans` per-faction accessors matching the existing
`psi_score`/`median_limit` tier exactly — `project_limit`/`main_region`/
`target_land_region`/`enemy_bases` (int) and **`enemy_mil_factor`/
`enemy_base_range` (float)**, this project's first `float`-returning
`LuaHostApi` entries (LuaJIT's FFI handles `float` natively, no blocker).

**Caught a real planning gap before it became a bug:** the plan's first
pass filed `MaxEnemyRange` under "deferred to `DefendUnit`/`CombatUnit`",
but it's actually needed by the prologue itself (`defend_range`'s default,
and `Wbase`'s own clamp condition) — found and fixed while implementing,
before any build/run.

**`lua/ai/build.lua`**: extracted the vehicle-count loop (previously
inline in `vehicle_counts_check`, step 1) into a reusable
`count_vehicles(base_id, sea_base)` so `select_build_prologue` doesn't
duplicate ~40 already-verified lines — `vehicle_counts_check` becomes a
thin wrapper over it, unchanged output. `select_build_prologue(base_id)`:
1:1 port of `build.cpp:847-965`, deliberately skipping
`retool`/`project_change`/`allow_units`/`allow_supply`/`allow_ships`/
`drone_riots`/`drones` (none feed `Wbase`/`Wthreat` or the debug line,
they belong to the deferred branches). `Wbase`/`Wthreat` use plain Lua
`/`, not `idiv` (4.10.7's rule — genuine C float arithmetic here).
`select_build_prologue_check(base_id)`: temporary, verification-only,
same precedent as `vehicle_counts_check`/`push_item_check`.

**Not touched, deferred to a future session's first task:**
`can_build`/`can_build_unit`/`has_ships`/`adjacent_region`/`need_scouts`/
`find_satellite`/`find_project`/`has_wmode`/`mineral_output_modifier`/the
`FormerUnit` tile-scan wrapper (4.10.2)/`ResInfo`, `GOV_ALLOW_COMBAT`/
`GOV_MAY_PROD_EXPLORE_VEH` and every `FAC_*`/`GOV_*` enum the ~44
remaining branches reference — cataloging these precisely (not trusting
the 2026-07-14 pass, same discipline this session used) is the natural
next step, likely starting with `DefendUnit`/`CombatUnit` since they
reuse the most already-ported infrastructure (`find_proto`,
`select_combat`, `has_retool`, `push_item`, all done).

**Files touched:** `tools/gen_ffi.cpp` (2 `BASE` fields, 1 `counts`
entry), `src/luaai.h`/`.cpp` (8 new `LuaHostApi` entries + wrappers,
`api_version` bump), `lua/ffi/funcs.lua` (matching cdef + wrappers,
`HOST_API_VERSION` bump), `lua/ai/build.lua` (`count_vehicles` extracted,
`select_build_prologue`, `select_build_prologue_check`, one new
`port.source` entry), `lua/ai/init.lua` (registers
`select_build_prologue_check`), `src/build.cpp` (one hook call).

### 4.10.13 Step 3 sub-step 2 session record (2026-07-16) — `DefendUnit`/`CombatUnit`'s early-return decision, implemented and live-verified

**Status: ✅ done.** `port_drift.py` clean at 18 tracked functions,
live-verified: all three hooks (`defend_unit_land_defense`/
`defend_unit_explore_veh`/`combat_unit_early_return`) at zero mismatches
(after fixing a shadow-hook placement bug — see `DEVELOPMENT_DIARY.md`,
2026-07-16, which also lists all four distinct bug classes found across
steps 2-3.4).

**Cataloged `DefendUnit`/`CombatUnit` before planning**, not trusting the
2026-07-14 pass. Both reuse `find_proto`/`select_combat` — already ported
and shadow-verified with zero divergences over 3 real games — so the new
logic is genuinely just the gating conditions around calls to
already-proven building blocks. **Scope cut, deliberate:** only the
early-return decision sites — `DefendUnit`'s two `return choice`
branches, `CombatUnit`'s `random(256) < ...` check. `CombatUnit`'s
fallback (`push_item` with the loop's own per-item `score`) needs the
`build_order[]` skeleton, not ported yet — deferred to whenever that
skeleton gets built, not bundled in here. The other 7 special branches
and all ~35 facility branches remain untouched.

**Design departure from steps 1-3.1: real shadow hooks, not another
throwaway diagnostic one.** Every prior step used a temporary
`lua_ai_hook` call piggybacking on a debug line that already existed.
That doesn't fit here — `DefendUnit`'s second branch and `CombatUnit`'s
check both consume RNG (`random(8)`, `random(256)`), and neither has an
existing debug line to diff against (early returns — `select_build`
exits immediately, no per-item logging is ever reached). A plain
`lua_ai_hook` call has no RNG snapshot/restore, so a Lua-side call
drawing from `rand.map` would permanently desync the real RNG stream for
the rest of the turn. `lua_ai_shadow_call`/`_check` (Consolidation gate
item b) already exists to prevent exactly this, and gives comparison
logging for free — so these are 3 real Class 1/2 shadow hooks, same
mechanism as `find_proto`/`mod_tech_ai`, not a new one-off. Granularity:
one hook per literal `return choice` site (not one per branch), so
neither `DefendUnit`'s nor `CombatUnit`'s existing early-return control
flow needed restructuring into the `report_and_return` pattern — at the
cost of not verifying the "neither condition holds" case (accepted,
narrower-but-simpler trade-off).

**New engine surface**, checked against current source: `GOV_ALLOW_COMBAT`
(computed constant — `GOV_MAY_PROD_LAND_COMBAT | GOV_MAY_PROD_NAVAL_COMBAT
| GOV_MAY_PROD_AIR_COMBAT`, mirrored from `base.h:5-6` rather than
hardcoded) and `GOV_MAY_PROD_EXPLORE_VEH` (already in `engine_base.h`,
just an emit line); 3 new opaque `LuaHostApi` wrappers (`api_version`
11 → 12): `need_scouts`, `has_ships`, `adjacent_region`. **Real trap
found while cataloging:** `adjacent_region`'s C++ signature takes `bool
ocean`, not a `Triad` — call sites pass `TRIAD_SEA`/`TRIAD_LAND` relying
on their exact values (`1`/`0`, confirmed in `types.enums`) implicitly
converting to `true`/`false`. The wrapper takes a plain `int32_t`; Lua
callers pass `1`/`0` (or `E.TRIAD_SEA`/`E.TRIAD_LAND` directly, same
effect) — documented explicitly so a future port doesn't pass
`TRIAD_AIR` here and get a silently-wrong `true`. `select_build_prologue`
(3.1) extended with `retool` (1:1 port of `build.cpp:852-861`, skipping
`plans_upkeep`'s mutating side effect — already runs for real regardless)
and `allow_ships` (`has_ships` + `adjacent_region`).

**Files touched:** `tools/gen_ffi.cpp` (2 enum emit lines), `src/luaai.h`/
`.cpp` (3 new `LuaHostApi` wrappers, `api_version` bump), `lua/ffi/funcs.lua`
(matching cdef + wrappers, `HOST_API_VERSION` bump), `lua/ai/build.lua`
(extended `select_build_prologue`; `defend_unit_land_defense`,
`defend_unit_explore_veh`, `combat_unit_early_return`, three new
`port.source` entries), `lua/ai/init.lua` (registers the three real
hooks), `src/build.cpp` (3 shadow call-site pairs).

### 4.10.14 Step 3 sub-step 3 session record (2026-07-16) — the `build_order` loop's per-item base score, implemented and live-verified

**Status: ✅ done.** `port_drift.py` clean at 19 tracked functions,
live-verified: 587 mismatches on the real autoplay run, every single one on
a facility with a real, not-yet-ported branch — **zero mismatches on any of
the 14 no-branch facilities**, confirmed by checking there is no overlap
between the mismatched item_ids and the 14 expected-clean ones.

**Cataloged the loop skeleton before planning.** Of `build_order[]`'s 36
facility entries, ~14 have no dedicated `if (t == FAC_X)` scoring branch
at all (`FAC_PRESSURE_DOME`, `FAC_HEADQUARTERS`, `FAC_HAB_COMPLEX`,
`FAC_AEROSPACE_COMPLEX`, `FAC_HABITATION_DOME`, `FAC_FUSION_LAB`,
`FAC_QUANTUM_LAB`, `FAC_ENERGY_BANK`, `FAC_NANOHOSPITAL`,
`FAC_COVERT_OPS_CENTER`, `FAC_EMPTY_FACILITY_42`-`45`) — they only pass
through the shared energy bonus and `GOV_MAY_FORCE_PSYCH` gates before
`push_item`. For exactly those, the shared per-item base-score formula
is a *complete* computation. **Scope, per explicit choice**: only that
shared formula + energy gate — not `allow_units`/`project_change`/
`can_build_unit` (which gate whether *unit*-type entries even get
visited), avoiding `queue_items[0]` (an array field; whether
`gen_ffi.cpp`'s `FIELD()` macro handles a single array slot hasn't come
up yet, deferred rather than resolved ad hoc).

**One shadow hook, `build_order_item_score(base_id, item_id)`,
unconditional per loop iteration — a deliberate, reasoned placement, not
another instance of 3.2's bug.** Must snapshot *before* C++'s own
`random(32)` draw, which happens before any of the 9 special unit-type
branches — so the call fires every iteration, unit entries included.
`lua_ai_shadow_call`'s own restore is what makes this safe regardless of
downstream branching: it undoes whatever Lua drew (or didn't) before
C++'s real `random(32)` runs. The **check**, by contrast, sits only in
the facility path, immediately before the pre-existing
`push_item(builds, base_id, -t, retool, score, --Wt)` call — never
reached for unit entries (`continue`d earlier) or energy-gated
facilities (`continue`d before push_item), no special-casing needed on
either side. Re-verified by hand before requesting a run (this session's
now-standard discipline after 3.2's bug): confirmed none of the 24
branch-having facilities' `if (t == FAC_X)` blocks themselves call
`random()` — the only RNG draw
between snapshot and check is the one `random(32)`, so mismatches on
branch-having facilities are purely missing score components, not a
second RNG-alignment bug in disguise.

**`lua/ai/build.lua`**: `select_build_prologue` (3.1-3.2) gains
`wenergy` (`build.cpp:1044-1045`) and now also returns `wgov` (previously
computed internally but not exposed — needed here for the base formula's
`AI_growth`/`AI_tech`/`AI_wealth`/`AI_power` weights). `BUILD_ORDER`: a
1:1 transcription of `build.cpp:983-1041`'s `build_order[]`, **all 47
entries** (9 unit sentinels as plain negative literals matching those
local consts exactly — not FFI enums, `select_build`'s own locals —
plus 38 facilities; recounted programmatically later, 4.10.15's note —
the "build_order[] has ~45 entries, 36 facilities" figure quoted around
this session was a rough estimate from 2026-07-14's original scoping
pass, never recounted precisely until 4.10.15) keyed by `item_id`, not
just the 14 this slice can fully evaluate — the actual data step 4 will
need regardless, one mechanical low-risk pass (same precedent as batch
enum additions: let the shadow-check comparison catch a transcription
error, don't hand-verify every row). Verified this approach doesn't
paper over the transcription risk it introduces: since the *result* of
a mistranscription would show up as a mismatch, it's still checked, just
at read-run time rather than build time — accepted because the
alternative (hand-checking 47 rows against a source listing) is exactly
the kind of manual verification this project's own discipline (4.10.4)
says to skip in favor of letting real execution catch it.
`build_order_item_score(base_id, item_id)`: returns `-1` immediately for
unit entries or unknown ids (never reached for comparison purposes
anyway); otherwise replicates the `can_build`/`GOV_MAY_PROD_FACILITIES`
skip, `skip_facility` (already ported, step 2), the base formula, and
the energy gate only — explicitly not the `GOV_MAY_FORCE_PSYCH` gate
(irrelevant to the 14; only gates `FAC_PUNISHMENT_SPHERE`/
`FAC_GENEJACK_FACTORY`) or any of the real per-facility branches.

**New engine surface**: `GOV_MAY_PROD_FACILITIES` enum + 27 `FAC_*` item
IDs referenced in `build_order[]` not yet exposed (batch, all resolved
clean via `gen_ffi`'s own compile step — no typos); 2 new opaque
`LuaHostApi` wrappers (`api_version` 12 → 13): `can_build`, `energy_limit`
(`AIPlans`, same tier as `project_limit` etc.); 2 new `BASE` fields:
`energy_surplus`, `energy_inefficiency`.

**Files touched:** `tools/gen_ffi.cpp` (27 enum emit lines, 2 `BASE`
fields), `src/luaai.h`/`.cpp` (2 new `LuaHostApi` wrappers, `api_version`
bump), `lua/ffi/funcs.lua` (matching cdef + wrappers, `HOST_API_VERSION`
bump), `lua/ai/build.lua` (`select_build_prologue` gains `wenergy`/
`wgov`; `BUILD_ORDER` table; `build_order_item_score`; one new
`port.source` entry), `lua/ai/init.lua` (registers the real shadow
hook), `src/build.cpp` (one shadow-call site, one shadow-check site).

### 4.10.15–4.10.30 Facility- and unit-branch catalog — complete (2026-07-16 through 2026-07-20)

**Status: ✅ done.** Every `build_order[]` entry — all 38 facilities (15
code blocks) and all 9 unit-type branches — has a real Lua implementation
in `build_order_item_score`/its branch functions. Both presets build
clean; `port_drift.py` clean. Live-exercise evidence (via the methodology
below): 33/38 facilities and 8/9 unit branches confirmed with 0
mismatches across several `--lua-shadow` autoplay runs (up to 220 turns).
Remaining unconfirmed — not known defects, all late-tier prereq tech or
narrow eligibility gates, deprioritized by explicit user direction
(2026-07-20), revisit opportunistically rather than as scheduled work:
facilities `FAC_ROBOTIC_ASSEMBLY_PLANT`/`FAC_NANOREPLICATOR`/
`FAC_QUANTUM_CONVERTER` (share `FAC_GENEJACK_FACTORY`'s branch code,
partial evidence only)/`FAC_PARADISE_GARDEN`/`FAC_PSI_GATE`; unit branch
`Satellites`.

**Corrected count** (verified programmatically, not by eye):
`build_order[]` has 47 entries — 9 unit sentinels + 38 facilities, of
which 14 use only the base formula (3.3) and 24 are branched here across
15 code blocks.

**Facility branches implemented:** `FAC_COMMAND_CENTER`/`FAC_NAVAL_YARD`
(two separately gated blocks — see the split-block lesson below)/
`FAC_BIOENHANCEMENT_CENTER`; `FAC_PERIMETER_DEFENSE`/`FAC_TACHYON_FIELD`/
`FAC_GEOSYNC_SURVEY_POD`/`FAC_FLECHETTE_DEFENSE_SYS` (shared
`MaxEnemyRange` block); `FAC_BIOLOGY_LAB`/`FAC_CENTAURI_PRESERVE` (also
split-block); `FAC_RECREATION_COMMONS`/`FAC_HOLOGRAM_THEATRE`/
`FAC_RESEARCH_HOSPITAL`/`FAC_PARADISE_GARDEN` (shared `mod_psych_check`
block); `FAC_PSI_GATE` (its own base-scan loop); `FAC_PUNISHMENT_SPHERE`
(shared `GOV_MAY_FORCE_PSYCH` gate); `FAC_CHILDREN_CRECHE`;
`FAC_TREE_FARM`/`FAC_HYBRID_FOREST`; `FAC_GENEJACK_FACTORY`/
`FAC_ROBOTIC_ASSEMBLY_PLANT`/`FAC_NANOREPLICATOR`/`FAC_QUANTUM_CONVERTER`
(shared block); `FAC_NETWORK_NODE`; `FAC_RECYCLING_TANKS`.

**Unit-type branches implemented:** `DefendUnit`/`CombatUnit` (4.10.13,
predates this catalog); `ColonyUnit`/`CrawlerUnit`/`FerryUnit`/
`SeaProbeUnit`/`Satellites`; `SecretProject` (via a full port of
`find_project`, cheaper than its ~112 loc suggested since it reuses many
already-ported pieces — `facility_score`/`check_retool`/`prod_count`/
`unit_score`/`can_build`/`has_fac_built`/`has_tech`/`at_war`/`is_alive`/
`defense_modifier` — plus 4 small new helpers: `find_missile`/
`faction_might`/`has_pact`/`redundant_project`); `FormerUnit`.

**`FormerUnit`/`select_item` scope decision.** `FormerUnit`'s own
dependency, `move.cpp`'s `select_item` plus its 12 `can_*` helpers,
totals ~472 loc with zero engine surface exposed — comparable in size to
the entire facility-branch catalog. Scoped concretely and presented to
the user as a choice: port it now (the project's usual "1:1, mechanical"
default), or recognize that within `select_build`, `select_item`'s return
value is only ever used as a `>= 0` eligibility check, never scored.
User chose the latter: the whole tile-quality tally (`iterate_tiles` +
`select_item(...) >= 0` + `worked_tiles`/`sea` counts) was wrapped as one
opaque host call, `former_tile_tally(base_id) -> {num, sea}` (same tier
as `has_base_sites`), and only the outer branch logic was ported.
Porting `select_item` itself as real AI policy is deferred to Movement's
`former_move` (Phase 4.2 item 4), where its terraform-choice value
actually matters — a different, Class 3 shadow-verification shape.

**New engine surface added across this whole stretch** (`api_version`
grew 13→22): `BASE.queue_items[10]`/`eco_damage`/`specialist_total`/
`assimilation_turns_left`/`mineral_intake`; `Faction.SE_planet_pending`/
`SE_growth_pending`/`SE_effic_pending`/`SE_alloc_labs`/`SE_alloc_psych`/
`clean_minerals_modifier`/`satellites_nutrient`/`_mineral`/`_energy`/
`_ODP`/`planet_busters`/`diplo_status[8]`/`pop_total`;
`CRules.drones_induced_genejack_factory`; a new `ResInfoRecyclingTanks`
global (computed address, not hand-transcribed — `FIELD()`/`FieldShape`
only handles scalar/array-of-scalar members, not a nested sub-struct, so
its address is computed from `offsetof` at generation time instead);
`MapAreaTiles` global; host wrappers `base_unused_space`, `nearby_items`,
`mineral_output_modifier`, `clean_minerals`, `unknown_factions`,
`has_facility`, `is_alive`, `enemy_odp`, `enemy_sat`,
`satellite_goal_setting`, `max_satellites`, `mil_strength`,
`former_tile_tally`, `mod_psych_check`, `naval_start_x`/`naval_start_y`,
`biology_lab_bonus`; plus ~20 new `FAC_*`/`GOV_*`/`PFLAG_*`/`DIPLO_*`/
`BSTATE_*`/`BIT_*` enums (see `lua/ai/build.lua` and `tools/gen_ffi.cpp`
for the exhaustive list, not reproduced here).

**Design lessons from this stretch** (full incident narrative:
`DEVELOPMENT_DIARY.md`, 2026-07-16 through 2026-07-20):

- **RNG-hazard hook-argument threading.** `select_build_prologue` is
  recomputed fresh on every shadow-called per-item hook (up to 38× per
  real `select_build` call). A local that consumes RNG when derived
  (`allow_units`, via `can_build_unit`) cannot be re-derived inside the
  prologue — it must be computed once in C++ and threaded through as a
  hook argument, same precedent as `mod_social_ai`'s `pop_boom` (4.5).
  Locals that are pure/RNG-free (`drone_riots`, `drones`,
  `mod_psych_check`, `main_region`, `target_land_region`) are safe to
  re-derive per item instead.
- **Split-block facilities.** A single facility ID can be gated by more
  than one separate `if (t == FAC_X)` block in `build.cpp` (found for
  `FAC_NAVAL_YARD` and `FAC_BIOLOGY_LAB`). Porting only one block leaves
  the facility silently half-implemented — check for a second block
  before calling any facility "done".
- **Verification methodology correction (2026-07-17, raised by the
  user): absence of a `mismatch` line is not evidence of correctness.**
  `lua_shadow`'s per-item hook only fires if the surrounding C++ loop
  already decided the item is eligible (`can_build`, gated on prereq
  tech). An unreached branch and a correctly-handled one produce
  identical "no mismatch" output. Fix: cross-check `push_item`'s own
  debug line (`push_item %d %d %d %s` → nonzero count of the specific
  facility/unit name) as independent evidence the branch was actually
  exercised. Both `lua.log`/`debug.txt` truncate on every launch, so this
  must be checked per-run, not retroactively. Documented as a standing
  rule in `IMPLEMENTATION_PLAN.md`'s Phase 5 handoff note.
- **Two real bugs caught by review before they could ship:**
  `faction.has_project(...) ~= 0` is always `true` — `has_project` is
  declared `bool` in `LuaHostApi`, and LuaJIT auto-converts a C `_Bool`
  return to a genuine Lua boolean, which is never `~= 0`-comparable the
  way a raw `int32_t` host call is (caught by re-reading other call
  sites before trusting new code). `C.SP_ID_First`/`C.SP_ID_Last` don't
  exist — those enums are under `E.` (`enums`), not `C.` (`counts`); a
  `nil` table lookup doesn't error until the code path actually runs, so
  this would have passed a clean build and only failed at runtime.
- **A real, pre-existing gap found while wiring unit branches (not a bug
  in new code):** `select_build_prologue`'s `need_ferry`/`allow_supply`
  exposed `count_vehicles`'s raw loop-accumulated values, but real C++
  applies a post-loop refinement (`build.cpp:948-950`) never ported —
  invisible until `CrawlerUnit`/`FerryUnit` became the first consumers,
  since the pre-existing `vehicle_counts_check` diagnostic runs *before*
  the refinement in the C++ source too. Fixed in `select_build_prologue`,
  not `count_vehicles`, to leave that diagnostic's own comparison point
  unchanged.

**This closes the entire `build_order[]` catalog.**

### 4.10.31 Step 4: wiring the real `select_build` hook (2026-07-20) — done, live-verified

**Status: ✅ done.** Both presets build clean, every touched file
passes a native-`luajit` syntax check. This is the first hook in the
whole project wired via `lua_ai_hook` rather than `lua_ai_shadow_call`
— every earlier "closed" domain (tech pilot, social, and all of
`select_build`'s own sub-pieces above) only ever fed a shadow-mode
comparison log; C++ always computed and returned its own value
regardless. From this point, `lua_ai=1` actually changes which item a
base builds, not just what gets logged. Confirmed with the user before
implementing, given the stakes (first-ever behavior-affecting hook,
5 facilities + `Satellites` still without direct exercise evidence) —
chosen approach: wire it as documented (Phase 4.1's Class 2
propose-then-commit), keep the existing per-piece `lua_ai_shadow_call`/
`_check` instrumentation intact in the C++ fallback body (still useful
whenever `lua_ai=0`), gated behind the same `lua_ai=1` flag already used
for all testing.

**C++ side (`src/build.cpp`):** `plans_upkeep(faction_id)` hoisted to run
once, unconditionally, before the hook attempt — it's a mutating side
effect independent of which side decides the return value, so it can't
live inside the (now fallback-only) retool-computation block anymore.
`select_build` gains `if (lua_ai_hook("select_build", &value, 1,
{base_id})) return value;` immediately after, matching the plan's own
Class 2 example. The three temporary, verification-only diagnostics that
predated real hooks on their call sites (`vehicle_counts_check`,
`push_item_check`, `select_build_prologue_check`) are removed, per their
own long-standing "deleted once step 4 wires the real hook" comments —
their underlying ported logic (`count_vehicles`, `push_item`/
`push_item_score`, `select_build_prologue`) stays, only the thin
log-only wrapper functions and hook registrations are gone.

**Lua side (`lua/ai/build.lua`):** a new top-level `select_build(base_id)`
reimplements `build.cpp`'s `build_order[]` loop (`BUILD_ORDER_LIST`, the
47 entries in their exact original order — RNG draws happen per item in
this order, so it must match exactly, not just the final chosen
item_id), dispatching to already-ported/shadow-verified pieces directly:
`select_build_prologue` for the shared locals, `build_order_item_score`
for the whole facility path (already computes the base score + all 38
branches internally), and the 7 push-a-candidate unit branches (colony/
crawler/ferry/sea_probe/satellites/secret_project/former) verbatim —
each takes the shared per-item base score as an argument and returns
`{choice, score}`. This is safe because `select_build_prologue` itself
is RNG-free (proven by every earlier shadow-verification session calling
it fresh per item with 0 mismatches), so letting each branch re-derive it
costs nothing but redundant work. `DefendUnit`/`CombatUnit` get inline
logic instead of reusing their existing early-return-only hooks:
`CombatUnit`'s hook (`combat_unit_early_return`) only ever covered the
immediate-return half, and calling it plus separately recomputing
`select_combat` for the push_item fallback would invoke `select_combat`
twice — drawing RNG twice instead of C++'s single call — so `CombatUnit`
is inlined to call `select_combat` exactly once, matching
`build.cpp:1121-1151`. A small shared helper, `base_item_score(w, wgov)`,
factors out the `rand.map(0,32) + Wgov-weighted sum` computation that
both `build_order_item_score` and the new per-item loop need; this draw
happens for *every* item that passes the two outer gates, unit or
facility alike, even when the result is discarded (`DefendUnit` never
scores or pushes anything) — skipping it for "irrelevant" items would
desync every later item's RNG draws against C++.

**New engine surface:** `project_change`/`allow_units` (`build.cpp:
868-872`), computed once per real `select_build` call now that this is
the top-level hook (previously threaded through as a hook argument from
C++, since re-deriving `allow_units` inside the *per-item* shadow-called
`build_order_item_score` would have drawn RNG up to 38× instead of once
— that hazard doesn't apply here, since the whole per-item loop is now a
single Lua call). `can_build_unit(base_id, -1)`'s body (`base.cpp:4813`)
reduces, for `unit_id == -1`, to one `conf.max_veh_num`-gated expression
— ported directly rather than via a generic 2-argument wrapper, needing
only a new `max_veh_num()` host accessor (`LuaHostApi` bumped to
`api_version=23`, same tier as `biology_lab_bonus`/`clean_minerals`).
`project_change` itself needed no new surface (`item_is_project`/
`can_build`/`state_flags`/`minerals_accumulated`/`retool_exemption` were
all already exposed).

**Live-verified same day, via the handoff protocol.** A 60-turn
`--lua-shadow` autoplay session (`bases` grew 0→108, `vehs` 34→315,
game still running normally at cutoff, not crashed): `register_hooks: 22
hook(s) registered` confirms `select_build` registered; `lua_ai_hook:
'select_build' invoked and handled` confirms the first real call
succeeded. Went further than "no errors" per this section's own note
above — checked whether the hook is actually *governing*, not just
callable: `mod_base_build`'s `BUILD NEW` debug line (fires immediately
before every real `select_build` call) shows **698 calls across all 7
factions**; `push_item`/the `select_build %3d ...` debug line (both only
reachable from the C++ *fallback* body, after the hook check) show
**zero occurrences** — meaning all 698 calls were handled by the Lua
hook, none fell back to C++. Zero `error in` lines, zero `mismatch`
lines anywhere (the still-shadow-verified hooks elsewhere stayed clean
too). The resulting `choice: <id> <name>` lines span every branch
category with plausible names and no repeated/garbage values (`Scout
Patrol`/`Colony Pod`/`Formers`/`Probe Team` for units; `Recycling
Tanks`/`Children's Creche`/`Network Node`/`Recreation Commons` for
facilities, among others) — this is the first time in the project this
kind of check (does the AI's output look sane, not just error-free)
actually matters, since it's the first hook whose output is no longer
purely diagnostic. **This closes `select_build` and porting-order item 3
is fully done.**

---

### 4.11 Port drift detection (2026-07-16) — Consolidation gate item e, done

**Status: ✅ done**, verified against all three real outcomes (clean,
drifted, error), not just a smoke test — see below. Session narrative:
`DEVELOPMENT_DIARY.md`, 2026-07-16.

`tools/port_drift.py` (new, Python 3 stdlib only — no third-party deps,
consistent with this project's existing tooling and this session's own
choices for the Lua/C++ sides). For every `port.source` entry across
`lua/ai/*.lua` (Plan 4.4's provenance metadata, present since the tech-AI
pilot but never read by anything until now), extracts the named C++
function's body via `git show <ref>:<path>` at both the pinned
`upstream_commit` and the current tip of `upstream/master` (falling back
to `master` with a warning if that remote isn't fetched — see
`CLAUDE.md`'s remote layout), normalizes whitespace and comments, hashes
both with SHA-256, and reports drift.

**Extraction is regex + brace/paren balancing, not a real C++ parser** —
same pragmatic-tooling precedent as `tools/gen_ffi.cpp`. Function
*definitions* are distinguished from prototypes and call sites by
requiring the parameter list's balanced closing paren to be followed by
`{` (a call site is followed by `;`, a prototype likewise) — verified
this matters directly: `mod_tech_val`'s definition
(`src/tech.cpp:366`, `int __cdecl mod_tech_val(...) {`) sits below its own
call site (`tech.cpp:618`, `mod_tech_val(i, faction_id, false);`), and a
naive "find the name, grab the next `{...}`" approach would have latched
onto unrelated code. Comment/string handling for normalization uses the
standard "comment-or-string-literal" alternation regex trick so a `//`
or `/*` inside a string literal isn't misread as a comment start.

**Verified against three real scenarios, not just a smoke test:**
- **Clean (real run):** `upstream/master`'s current tip *is* the pinned
  commit (`15418b28...`, "Rewrite faction and movement code") for every
  existing entry — nothing has landed upstream since this port started.
  Reports **11 clean, 0 drifted, 0 errors**, exit 0.
- **Drifted (synthetic — pointed `--base-ref` at a commit 5 commits
  before the pin):** correctly reports **6 clean, 3 drifted** — the 3
  flagged (`select_colony`, `social_score`, `mod_social_ai`) are exactly
  the functions actually touched by the intervening "Rewrite faction and
  movement code" commit, and the other 8 (genuinely untouched by that
  rewrite) correctly report clean. This is real evidence the diff
  detection works, not just that the script runs.
- **Error (bogus `--base-ref`):** all entries correctly report as errors
  (`cannot read <file> at <ref>`), exit 1, rather than crashing or
  silently reporting false negatives.

**Closed a real gap found while scoping this, not left for later:**
`facility_score`/`governor_priorities` (5.2.1's golden-trace slice, also
`src/plan.cpp`) had no `port.source` entry at all — 4.9 predates the
provenance-metadata convention being applied retroactively to them. Added
both to `lua/ai/build.lua`'s existing `source` table, same pinned commit
(confirmed via `git log -1 15418b28...:src/plan.cpp` that `plan.cpp` was
last touched by an earlier commit, `6d37d82` "Add probe functions" — so
the same pin point is still the correct baseline). Tracked-function count
is now 11, not the 9 that existed before this session.

**`docs/LUA_PORTING.md`** (new): human-readable index of all 11 ported
functions (domain, Lua module, C++ origin, pinned commit), usage docs
for `tools/port_drift.py`, and the convention for adding a new entry when
porting a new function. Explicitly documented as *not* the source of
truth (that's the `port.source` tables themselves, which the script
actually reads) — a curated index that needs manual upkeep, same
trade-off as this file's own session-record structure.

**Files touched:** `tools/port_drift.py` (new), `docs/LUA_PORTING.md`
(new), `lua/ai/build.lua` (two new `port.source` entries).

---

### 4.12 Movement port (porting-order item 4) — stages 0-3 done and live-verified, stage 4 (former_move) next

**Status: ✅ stages 0-3 done, live-verified.** Real function sizes
read directly from `move.cpp`/`veh_turn.cpp`/`goal.cpp` (3657/887/183
loc) rather than estimated — the one-liner in `IMPLEMENTATION_PLAN.md`
predates this pass. Complements 4.4's earlier high-level notes
(`move_upkeep`'s split, `combat_move`'s Class 3 shape); this section is
the concrete staging.

**Dispatch shape confirmed:** `mod_enemy_move` (`veh_turn.cpp:147`)
routes each vehicle to exactly one mover by type — `colony_move`/
`former_move`/`crawler_move`/`artifact_move`/`trans_move` (sea triad
with cargo)/`nuclear_move` (planet busters)/`combat_move` (everything
else). Each mover is Class 3 in the plan's own sense: it calls host
mutators directly (`set_move_to`, `mod_veh_skip`, `mod_study_artifact`,
...) and returns an action code (`VEH_SYNC`/`VEH_SKIP`) the C++ caller
uses as-is — confirmed by reading `artifact_move` end to end, the
smallest one. This means each mover is independently hookable, matching
the plan's own per-function staging intent.

**Real sizes (loc), smallest to largest:** `artifact_move` ~23,
`crawler_move` ~67, `colony_move` ~125, `former_move` ~157, `nuclear_move`
~163, `trans_move` ~253, `move_upkeep` ~354, `combat_move` ~726 (by far
the largest single function in the whole project so far). Faction-level
planning: `land_raise_plan` ~115, `invasion_plan` ~106,
`update_main_region` ~61. `goal.cpp` (add_goal/wipe_goals/clear_goals/
del_site/has_goal/find_priority_goal) ~180 total, small state-management
helpers consumed by the planning functions, not the movers themselves.

**Out of scope, by explicit user decision (2026-07-20):** native life
(fauna/aliens — `mod_alien_move`/`mod_alien_base`/`mod_alien_fauna`/
`mod_do_fungal_towers`, `veh_turn.cpp:261-887`, ~640 loc). Not strategic
faction AI; revisit later only if it turns out to matter.

**Staged plan (agreed with the user, adjusts the plan's original
per-function order by merging two adjacent isolated movers):**

- **Stage 0 — Class 3 hook infrastructure (prerequisite, no mover yet).**
  Every hook so far (Class 1/2) lets C++ fall back cleanly at any point,
  since nothing is mutated before the fallback decision. Class 3 is
  different: once Lua issues its first host-mutator call, there is no
  fallback to C++ for that invocation — an error after that point must
  finish the unit safely (`veh_skip` via host API) and log, not re-run
  the C++ body (`IMPLEMENTATION_PLAN.md` 4.1's own rule, not yet
  implemented anywhere). Verification is also structurally different:
  no per-call shadow comparison (nothing to compare against once
  mutations happen) — a decision trace (unit, options considered,
  scores, chosen action) logged from both sides in *separate* runs,
  diffed after the fact; whole-system fidelity comes from the
  determinism harness (5.3) toggling `lua_ai` between runs, not
  per-call snapshot/restore.
- **Stage 1 — `artifact_move` (~23 loc) as the pilot. ✅ done,
  live-verified.** Smallest, simplest mover; proved the Class 3
  mechanism end-to-end (new host wrappers: `search_route`,
  `set_move_to`, `mod_veh_skip`, `mod_study_artifact`; `TileSearch`
  itself stays opaque, per 4.3).

**Stage 0+1 implementation (2026-07-20).** `lua_ai_command_hook`
(`src/luaai.h`/`.cpp`) is structurally close to `lua_ai_hook` (same
registry lookup, pcall/traceback shape) but adds a `g_mutation_issued`
flag, set by every mutating host wrapper as its first action and reset
at hook entry: if Lua errors after issuing a mutation, the hook finishes
the vehicle safely (`mod_veh_skip`) and reports "handled" rather than
letting the caller re-run its own C++ body over already-mutated state;
if it errors before any mutation, it reports "not handled" and the
caller's C++ body runs unchanged. No RNG snapshot/restore, unlike
Class 1/2 — Class 3 never runs both sides, so there's nothing to keep
aligned. Wired at `artifact_move`'s one call site in `mod_enemy_move`
(`veh_turn.cpp`).

New engine surface: `VEH.iter_count`/`waypoint_x`/`waypoint_y`/
`waypoint_count` (back `VEH::at_target()`, ported to `lua/api/veh.lua`);
enums `ORDER_NONE`/`ORDER_HOLD` (already-visible via `engine_veh.h`) and
`VEH_SYNC`/`VEH_SKIP`/`PM_SAFE` — the latter three hand-transcribed
(`0`/`1`/`-20`) rather than read via `#include`, since their home headers
(`veh_turn.h`/`move.h`) pull in `main.h` → `windows.h` transitively,
which the natively-compiled (non-mingw) `gen_ffi` host tool can't
process; same tier as this file's other hand-transcribed globals
predating the computed-address technique (4.10.26). Seven new
`LuaHostApi` entries (`api_version` bumped 23→24): `base_at`/
`can_link_artifact`/`map_safety` (pure reads — `map_safety` reads
`mapdata`, a `std::unordered_map`, so stays opaque per 4.3, exposed only
as this one-field read), `search_route` (wraps its own local
`TileSearch`, also opaque, 3 out-params: found/tx/ty), and the first
three *mutating* wrappers in the project (`mod_study_artifact`/
`set_move_to`/`mod_veh_skip` — Phase 3's read/write asymmetry rule
finally has a write side). New `lua/api/path.lua` (the first
path-domain module, per Phase 3.2's planned shape).

**Files touched:** `tools/gen_ffi.cpp`, `src/luaai.h`/`.cpp`,
`src/veh_turn.cpp` (seam + `#include "luaai.h"`), `lua/ffi/funcs.lua`,
`lua/api/veh.lua` (`at_target`), `lua/api/map.lua` (`base_at`/`safety`),
`lua/api/base.lua` (`can_link_artifact`), `lua/api/path.lua` (new),
`lua/ai/move.lua` (new, `artifact_move`), `lua/ai/init.lua`
(registration).

**Live-verified (2026-07-21).** First run (~52 turns) found no artifact
units at all — inconclusive by construction (a hook with zero
invocations proves nothing about the mechanism), same "exercise
evidence, not absence" discipline as `select_build`'s 4.10.20 note. A
second run with an early artifact confirmed it for real: 5 real
`artifact_move` invocations, **all 5 lines in `debug.txt` prefixed
`lua:`** (the mirror-from-Lua marker) — meaning every single call was
handled by the Class 3 hook, zero fell back to the C++ body. 0 errors.
The logged coordinates form a coherent multi-turn trajectory for what is
clearly the same unit continuing its journey turn over turn (`30 44 ->
33 41` at one point, `33 41 -> 35 37` later — the second call's start
matches the first's destination), not just error-free noise. The
`artifact_link` branch (studying at a base) never fired this run — not
concerning, just means no artifact reached a friendly base under the
right conditions yet; revisit opportunistically like the handful of
still-unexercised `select_build` branches, not a blocker. **Stage 0+1
closed.**
- **Stage 2 — `crawler_move`. ✅ done, live-verified.** (~67 loc, but with
  real complexity of its own: `want_convoy`'s tile-yield scoring, a
  bounded `TileSearch` scan picking the best candidate, `mapnodes` — a
  mutable `NodeSet` — as shared state).
**Stage 2 implementation (2026-07-21).** Two whole decision blocks
(`move.cpp:1229-1239`/`1240-1246`) wrapped as opaque host calls
(`crawler_home_base_check`/`crawler_at_target_check`, each returning
`{applicable, action}`) rather than exposing the individual MAP-tile/
VEH-field touches they need (`sq->is_base()`/`->owner`, a direct
`veh->order` write) — same "no real judgment in the block" reasoning as
`former_tile_tally`. New mutating wrappers: `mark_convoy_site` (marks
`mapnodes`), `set_convoy`, `move_to_base`.

**Reworked same day, before live verification, per explicit user
direction:** the first pass wrapped `want_convoy` (`move.cpp:1167-1221`)
and the whole `TileSearch` scan as opaque calls, on the same "engine
mechanics, not AI policy" reasoning used for `former_tile_tally`/
`has_base_sites` elsewhere. The user flagged this as wrong for this
specific case — crawlers are the single biggest economic lever in the
game and this project's stated priority area, so `want_convoy`'s scoring
*formula* (which resource to harvest, how good a tile is) is real AI
policy, not engine mechanics, even though it consumes engine yield
calculators as inputs. Reworked: `want_convoy`'s full formula now lives
in Lua (`lua/ai/move.lua`); only the three yield calculators
(`mod_crop_yield`/`mod_mine_yield`/`mod_energy_yield`, genuine engine
mechanics) and single-field tile reads (`tile_is_base`/`tile_owner`/
`tile_is_base_radius` — `MAP*` still can't cross the FFI boundary) stay
as host wrappers. The `TileSearch` scan itself still can't cross into
Lua (Phase 4.3), but instead of one opaque "whole scan" call, it's now
an **incremental iterator** (`crawler_search_start`/`crawler_search_next`,
a file-local static `TileSearch` between calls — safe because movement
dispatch is strictly sequential, same assumption `g_mutation_issued`
already relies on): Lua drives the loop and scores every candidate with
the real Lua `want_convoy`, so the "which tile is the best crawl target"
judgment is genuinely in Lua now, not baked into a host wrapper. This is
a new pattern for the project — the first host primitive exposed as a
start/next pair rather than one bounded call — worth reusing if a future
mover needs the same shape (a C++-side search whose per-candidate
judgment should live in Lua). Two small new pieces: `project_base`
(`faction.cpp:70-74`, a one-line array lookup) and `base_growth_goal`
ported directly to Lua instead of wrapped (`clamp(24 - pop_size, 0,
base_unused_space(base_id))`, cheap enough once actually read, same
precedent as `facility_count`). `ResType`/`ORDER_MOVE_TO`/
`FAC_SUPERCOLLIDER`/`FAC_THEORY_OF_EVERYTHING` newly exposed enums, all
already visible via existing `#include`s. `want_convoy` had no header
declaration at all (file-local to `move.cpp` but not `static`) — added
to `move.h` next to `crawler_move`, then removed again once the C++-side
`want_convoy` wrapper it was needed for was itself removed; the C++
fallback body still calls the real `want_convoy` internally, which
needs no forward declaration since it's defined earlier in the same
file. `LuaHostApi` bumped to `api_version=26`. Both presets build clean,
every touched file passes a native-`luajit` syntax check.

**Live-verified (2026-07-21).** The first run only proved "no crash" —
`crawler_move`/`want_convoy` had no decision-trace logging at all
(unlike `artifact_move`), so a clean run gave no evidence the *decisions*
(which resource, which tile) were sane, for the area the user has
explicitly flagged as this project's highest-priority correctness
target. Fixed by adding `crawl_score`/`crawl_move`/`crawl_convoy` debug
lines at `crawler_move`'s three real decision points (mirroring the
granularity `move.cpp`'s own now-removed `crawl_score` line had). Second
run: **730 decision lines, 0 errors** — 122 `crawl_score` (a better
candidate found mid-search), 67 `crawl_move` (final move to the best
tile), 541 `crawl_convoy` (immediate conversion at the current tile).
All three `ResType` choices fire, including the narrowly-gated energy
branch (`res=3`, needs `FAC_NETWORK_NODE`/`FAC_TREE_FARM`/one of two
secret projects on top of the score threshold) — confirms every formula
branch is reachable, not just the common mineral case. Scores stay in
plausible bounded ranges (9–55), `crawl_move` coordinate deltas are
short and local (e.g. `44 42 -> 40 46`), and at least 44 distinct
starting positions were touched across the run — broad, not a single
repeating case. **Stage 2 closed.**

**The "search + score" function family (found 2026-07-21, before starting
stage 3).** Reading `colony_move` before implementing it (per the user's
own request, after the `want_convoy` correction) found the *same*
opaque-scoring mistake already shipped in stage 1: `path.search_route`
(used by `artifact_move`, already "done, live-verified") wraps
`route_score`, a real scoring formula with an artifact-specific special
case (`path.cpp:759`), not engine mechanics. The user asked for a full
sweep of `move.cpp`/`path.cpp` before touching any more movers. Found a
whole family of standalone `*_score(...)` functions, each consumed by a
`TileSearch` scan tracking a `best_score`:

- **Group A — blocks stage 3 or already shipped, addressed now:**
  `route_score` (`search_route`, deferred to its own stage — see below),
  `escape_score` (`search_escape`/`search_base`), `base_tile_score`
  (`colony_move`'s own site scoring).
- **Group B — belongs to movers not yet scoped, deferred to their own
  stage rather than ported blind without full context:** `former_tile_score`
  (`former_move`, stage 4), `teleport_score`/`flank_score`/`cover_score`/
  `target_priority`/`battle_calc`/`battle_eval`/`battle_priority` (all
  `combat_move`/`choose_defender`, stage 6). Both groups also feed
  `move_upkeep`'s `PMTable.overlay` cache fill (stage 7) — a
  precomputation for other systems to read cheaply, not itself a
  decision; revisit when stage 7 is scoped.

**`route_score`/`search_route` split into its own stage, not fixed
inline.** Read in full (`path.cpp:675-885`, 210 loc): 4 branches by
triad/combat status (air/sea/land-combat/land-noncombat), **5 separate
scoring loops**, a gate-teleport network search (`FAC_PSI_GATE`), and a
sea-route "naval pickup point" search that walks `TileSearch`'s own
path-node parent chain (`ts.get_prev()`/`node.prev`) — deeper coupling
to `TileSearch` internals than `crawler_move`'s simple per-tile scan, so
the start/next iterator pattern doesn't drop in as-is. Comparable in
size to `nuclear_move`/`find_project`, not a quick formula swap.
Deferred to its own stage (placement TBD — likely alongside or after
`nuclear_move`, given similar weight) rather than rushed; `escape_score`/
`base_tile_score` are more contained and come first.

- **Stage 3 — `colony_move`, plus a real port of `base_tile_score`
  and `escape_score`/`search_escape`/`search_base` (both consumed by
  `colony_move` directly, not deferred). ✅ implemented, build-verified,
  live verification pending.**

**Stage 3 implementation (2026-07-22).** `escape_score` (`path.cpp:567-573`)
ported straight to Lua — same "compare candidates, pick the best" AI
judgment as `want_convoy`, just smaller. `search_escape`/`search_base`
(`path.cpp:575-657`) reuse the crawler_move-established incremental
start/next iterator shape (`search_escape_start`/`_next`,
`search_base_start`/`_next`): the host applies the original's own
eligibility filters (`non_ally_in_tile`/is_base+owner/pact/zoc for
escape; already-there/is_base+owner/pact/dist+triad gating/`allow_move`/
is_airbase+zoc for base) as pure facts, never surfacing an ineligible
candidate to Lua at all — safe because `escape_score` has no side
effects, so "computed and discarded" (the original's behavior, since the
zoc/airbase gate in `search_base` only guards the *assignment*, not the
score computation) and "never computed" are equivalent. The `dist > 2 &&
best_score > 500` early-out in `search_escape` is checked per candidate
*returned to Lua* rather than per candidate popped host-side (as the
original does); proven equivalent by construction, not just assumed —
ineligible tiles never affect `best_score` in the original either, so
skipping straight to the next eligible one changes nothing about the
final `tx`/`ty`/`best_score`.

`base_tile_score` (`move.cpp:1339-1399`) — the real "which tile is worth
founding a base on" formula — ported in full. Its own 21-tile
`iterate_tiles(x,y,0,21)` scan is driven by a new `tile_neighbor(x,y,i)`
wrapper: `iterate_tiles` itself is `TableOffsetX`/`TableOffsetY` ring
geometry plus map-edge `wrap()`, the same "pure geometry, not judgment"
tier as `TileSearch` (Phase 4.3) — `tile_neighbor` resolves one ring
index to real wrapped coordinates (or reports off-map), and Lua drives
the `i=0..20` loop, scoring each neighbor itself via the new `tile_*`
fact wrappers (`map_target`/`tile_items`/`tile_is_rocky`/`tile_alt_level`/
`tile_bonus`/`tile_lm_items`/`tile_is_land_region`/`tile_region`/
`tile_is_rainy`/`tile_is_moist`/`tile_is_rolling`/`tile_is_visible`/
`both_non_enemy`/`ocean_coast_tiles`) already added for this stage.
`defender_count` (`path.cpp:474-485`, a pure garrison-strength count,
not a scored comparison) ported directly to Lua using only
already-exposed `veh.get`/`veh.count`/`veh.at_target`/`veh.eval_garrison`
— no new host wrapper needed, confirming the earlier "cheap enough once
actually read" classification.

`colony_move` (`move.cpp:1405-1528`) itself: the ocean-transport branch
(`is_ocean(sq) && triad==LAND`, `move.cpp:1417-1431`) is a "find the
first eligible neighbor tile" mechanic — first-match wins, no scoring
among candidates, same tier as `has_base_sites`/`ocean_colony_land_site`
— kept as one opaque `colony_transport_check` wrapper (mutating: inserts
`NODE_NEED_FERRY` on the no-transport path) to preserve the original's
exact in-order `random(4)` consumption. The base-site search loop reuses
`colony_search_start`/`_next` (already shipped, unused until now) with
Lua scoring each candidate via the new `base_tile_score` and tracking
`best_score`/`k` itself, replicating the `k>=25 && best_score>=0 &&
dist>=...` early-break exactly (including its one quirk: `move.cpp:1490`
uses the real `region_at()` engine call for its region check, not the
raw `sq->region` field every other region check in this function uses —
kept as-is, not "fixed" to match the others). Two more small mechanical
wrappers: `mark_base_site_radius` (marks the chosen site's claimed
radius, `conf.base_spacing`-dependent — config value stays in C++, not
AI policy) and `set_colony_automation_flags` (a plain `VEH::state`
bitset write, `VSTATE_UNK_40000`/`VSTATE_UNK_2000`). `search_route`'s
own defect (`route_score` baked into an opaque wrapper, see above)
remains **deferred** — `colony_move` keeps calling the existing,
already-flagged `path.search_route` for its one fallback call site until
that stage lands.

New engine surface: `VEH.state` (VEH's first mutable-bitset field
exposed for reading — writes still only ever go through
`set_colony_automation_flags`, never a direct Lua write); enums
`BIT_FUNGUS`/`BIT_RIVER`/`BIT_BUNKER`/`BIT_MONOLITH`/`BIT_FARM`/
`BIT_SENSOR`/`LM_JUNGLE`/`LM_SARGASSO`/`LM_DUNES`/`LM_UNITY`/
`ALT_OCEAN`/`ALT_OCEAN_SHELF`/`ALT_SHORE_LINE`/`ORDER_SENTRY_BOARD`/
`VSTATE_UNK_40000`/`VSTATE_UNK_2000` (all compiler-read from
`engine_enums.h`/`engine_veh.h`, already `#include`d) and
`VEH_REMOVE_TURNS` (hand-transcribed `60`, `move.cpp:30`'s own
file-local `static const int` — same tier as `PM_SAFE`, cross-check
there if it ever drifts); `game.map_area_y()`/`game.base_count()` (plain
scalar globals, same pattern as `game.turn()`). Two bugs caught before
this shipped: `BIT_SENSOR` (`0x80000000`) was first emitted with a `%uU`
format string, an invalid LuaJIT numeric literal (`luajit` rejects a
bare `U` suffix — only `LL`/`ULL` are its extension); caught by actually
loading the generated `lua/ffi/types.lua`, not just syntax-checking the
files edited by hand, and fixed by dropping the suffix (LuaJIT's
`bit.*` library coerces any in-range Lua number to its 32-bit pattern via
`tobit`, so the plain decimal literal is sufficient). Second: `base_tile_score`'s
land-tile bonus (`move.cpp:1373`, `(!owned || own) && ++land < 3`) is a
C pre-increment fused into the `&&` chain — the comparison sees the
*post*-increment value, so only the first **two** qualifying tiles ever
grant the bonus, not three; a first draft checked `land < 3` before
incrementing (granting the bonus to three tiles instead of two), caught
on a close re-read against the original before ever running it, fixed by
always incrementing when the first four conditions hold and gating the
score add on the post-increment value, matching the original's real
(mildly surprising, but exact) behavior. `LuaHostApi` bumped
`27→29` (`tile_neighbor` at 28, then `mark_base_site_radius`/
`set_colony_automation_flags`/`colony_transport_check`/`tile_is_visible`
at 29). Both presets build clean, every touched file passes a native-
`luajit` syntax check (including a direct `loadfile` of the generated
`types.lua`, not just `-bl`).

**Files touched:** `tools/gen_ffi.cpp`, `src/luaai.h`/`.cpp`,
`src/veh_turn.cpp` (seam), `lua/ffi/funcs.lua`, `lua/api/game.lua`
(`map_area_y`/`base_count`), `lua/api/faction.lua` (consumed via
`faction.get(id).base_count`, no new wrapper needed there), `lua/ai/move.lua`
(`escape_score`/`search_escape`/`search_base`/`escape_move`/
`base_tile_score`/`defender_count`/`colony_move`), `lua/ai/init.lua`
(registration).

**Live-verified (2026-07-22).** An 80-turn run: **613 real colony-family
decision lines** (347 `colony_move`, 235 `colony_base`, 30 `colony_naval`,
1 `colony_trans`, 0 `colony_drop`), **44 `escape_score` lines**, 0 errors,
0 asserts/crashes, 0 fallback to the C++ body — confirmed two ways:
`lua_ai_command_hook`'s dedup'd "invoked and handled" line fired once for
`colony_move` (as designed, first-call-only), and independently, `grep -c
"^lua: colony_"` on `debug.txt` (613) exactly matches the total decision
line count from `lua.log`, meaning every single one of the 613 was
Lua-handled, none a stray C++-side duplicate. Base count climbed 7→142
over the run (real colonization happening end to end, not just
error-free noise), across 202 distinct starting coordinates (broad, not
one repeating unit). A coherent multi-turn story for one unit: `colony_base
14 26 -> 15 21` (twice — walked to the nearest friendly base, no new site
found), then from `15 21`: `colony_naval 15 21 -> 12 26` and `-> 22 12`
(redirected toward the faction's naval departure point, consistent with
a sea-triad pod stuck without a land region to found on), then later
`colony_move 15 21 -> 18 32` and `-> 79 19` (real sites found once reached,
at increasing range — plausible for an overseas expansion pod). `colony_drop`
never firing this run isn't concerning (airdrop needs specific tech/
conditions that may not have arisen), same "revisit opportunistically,
not a blocker" precedent as `artifact_move`'s never-fired `artifact_link`
branch. `crawler_move` logged 0 decision lines this run — a fact about
this run's game state (no supply crawler ever became eligible to move),
not a regression: the hook registration is untouched by this stage's
diff, and `crawler_move`'s own code path shares nothing with
`colony_move`'s. **Stage 3 closed.**

- **Stage 4 — `former_move`** (~157 loc). The one stage where a real,
  substantial new port is unavoidable: `select_item`
  (`move.cpp:1803-2004`, ~200 loc) plus its 12 `can_*` tile-eligibility
  helpers (`move.cpp:1530-1803`), deliberately left as an opaque wrapper
  during `select_build`'s `FormerUnit` branch (`former_tile_tally`,
  `IMPLEMENTATION_DETAILS.md` 4.10.29) specifically because only here,
  in `former_move`, does *which* terraform action gets chosen matter as
  real AI policy rather than a `>=0` eligibility check.
- **Stage 5 — `trans_move`** (~253 loc, invasion/landing logic:
  `make_landing`/`near_landing`/`invasion_unit`).
- **Stage 6 — `combat_move`** (~726 loc). Last, by far the largest and
  most performance-sensitive — ported only once a C++ baseline is
  measured, per the plan's own rule (5.4).
- **Stage 7 — `move_upkeep` + `invasion_plan`/`land_raise_plan`/
  `update_main_region` + `goal.cpp`.** Faction-level orchestration (once
  per faction per turn, not per unit) rather than per-unit dispatch;
  `move_upkeep` itself splits per 4.4's existing note (table fills stay
  C++, the planning that consumes them is what ports); `goal.cpp` lands
  here since it's consumed by this planning, not by the movers.
- **Stage 8 — `nuclear_move`** (~163 loc), moved to the very end of the
  phase by explicit user direction (2026-07-21), reordering the plan's
  original position right after `crawler_move`. Originally split out of
  stage 2 after reading it in full — LOC undersold it badly: full
  cross-faction diplomatic/threat scoring (`diplo_status`/`at_war`/
  `un_charter`/`corner_market_active`), a complete secret-project
  iteration (same tier as `find_project`/`select_build`), spatial
  containers for base-target search (`Points`, `map_int_t`), and several
  genuinely new primitives (`veh_drop`/`veh_lift`/`defender_count`/
  `ally_near_tile`/`min_range`/a `map_range(VEH*, BASE*)` overload
  distinct from the already-exposed coordinate form). Closer in weight
  to `find_project`/`select_build` than to an "isolated small mover" —
  now deferred past every other movement stage, including `combat_move`
  and the faction-level orchestration stage, so its outsized complexity
  doesn't block the more clearly-scoped work.

---

## Phase 5 — validation

The Consolidation gate (`IMPLEMENTATION_PLAN.md`, opened 2026-07-14) exists
because five ported domains (research, social engineering, war decisions,
two production/plans slices) were "in-game verified clean" only by
temporary dual-run instrumentation over manual play — none had met its
module-level "Done when" (golden traces, real shadow mode, a multi-save
matrix). Sections 5.1.1 onward below are the work that closed it.

### 5.1 Shadow wrapper (in `lua_ai_hook`, C side — Class 1/2 only)

```
if (conf.lua_shadow && hook_exists) {
    uint32_t g = game_rand_state(); uint32_t m = random_state();
    bool ok = call_lua(&lua_result, ...);
    game_rand_restore(g); random_reseed(m);
    int cpp_result = <fallthrough to C++>;
    if (ok && lua_result != cpp_result) log divergence;
    return cpp_result;
}
```

Requires `game_rand_restore` from 3.5. Class 3 hooks are never run twice —
see plan 5.1 (decision traces in separate runs + determinism harness). Log
format: one line per divergence with function, args, both results and RNG
draws consumed — greppable, diffable.

### 5.1.1 Shadow mode implemented (2026-07-16) — Consolidation gate item b, done; exercised live in 5.1.2

Replaced the sketch above (and every hand-rolled per-hook dual-run block
it was standing in for) with the real thing: two functions in
`src/luaai.h`/`.cpp`, `LuaShadowCall lua_ai_shadow_call(name, out_count,
args)` and `void lua_ai_shadow_check(name, shadow, cpp_out, out_count)`,
called in pairs at each hook site — `_call` before the C++ body runs,
`_check` once the C++ result is known. Implements Plan 5.1's Class 1/2
procedure exactly: `_call` returns immediately with `active=false` (no
Lua call, no RNG state touched) when `conf.lua_shadow` is 0 — the "zero
overhead beyond the flag check" requirement; when 1, it snapshots
`game_rand_state()`/`random_state()`, resolves and calls the hook exactly
like `lua_ai_hook()` would, restores both streams (so the caller's own,
about-to-run C++ computation sees the RNG exactly as if the shadow call
never happened), and records the Phase 5.3.5 draw-count deltas
(`g_game_rand_draws`/`g_mod_rng_draws`) for the log line. `_check`
compares `shadow.out[0..out_count-1]` against the caller's own result and
logs one line per divergence (`lua/cpp <hook> mismatch: args=[...]
lua=[...] cpp=[...] rng_draws: game=N mod=N`) via `lua_logf` (not
`debug()` — this file's own convention throughout, and it means mismatch
lines now land in `lua.log` too, not just `debug.txt`-only builds).

**Typed hook-descriptor refactor, same pass.** `lua_ai_hook` gained an
`out_count` parameter: `1` means "a single Lua number", unchanged for
every hook written before this session (`mod_tech_val`, `mod_tech_ai`,
`mod_social_ai`, `mod_wants_to_attack`, `find_proto`, `select_colony`,
`select_combat` all pass `1`, zero Lua-side changes needed); `>1` means
"a 1-indexed Lua table of `out_count` numbers". One function, not a
family of `_i`/`_ii`/`_witem` variants — the plan's explicit rule (4.1)
held. This is what makes `facility_score`/`governor_priorities` hookable,
closing the gap 4.9 left open (`WItem` is 5 ints; the old int-in/
int-result-out contract couldn't express a struct input, let alone a
struct output).

**`facility_score`/`governor_priorities` hooked** (`src/plan.cpp`):
- `facility_score(FacilityId item_id, WItem& Wgov)`: args flattened as
  `{item_id, Wgov.AI_growth, Wgov.AI_tech, Wgov.AI_wealth, Wgov.AI_power,
  Wgov.AI_fight}` (`WItem`'s declared field order, `engine.h`), `out_count=1`.
- `governor_priorities(BASE& base, WItem& Wgov)`: `void`, output-only —
  `out_count=5`, same field order. Needed `base_id` for the Lua side
  (which re-fetches `BASE` via FFI, doesn't take a raw reference) but the
  function's own signature only has `BASE&` — recovered via pointer
  arithmetic, `int base_id = &base - Bases;`, valid because both call
  sites (`build.cpp`) always pass a `Bases[]` element directly.
- **Lua-side adapters, not a signature change to the real functions**
  (`lua/ai/build.lua`): `facility_score_hook`/`governor_priorities_hook`
  are thin marshalling functions between the C side's flat-int
  convention and `facility_score`/`governor_priorities`'s own named-table
  `WItem` interface (`{AI_growth=.., AI_tech=.., ...}`), which stays
  exactly as 4.9 wrote it. Same precedent as `lua/api/faction.lua`'s
  `models_to_cdata`: marshal at the boundary, keep the natural
  representation everywhere else — a future internal Lua caller (once
  `select_build` is ported and calls these two directly) gets the
  convenient named-table interface, not the hook's flat-array one.
  Registered in `lua/ai/init.lua` as `facility_score`/
  `governor_priorities` (the hook names, not the underlying Lua function
  names — `build.facility_score`/`build.governor_priorities` remain the
  real implementations).

**All seven pre-existing hooks migrated.** `mod_tech_val`/`mod_tech_ai`
(`tech.cpp`), `mod_social_ai`/`mod_wants_to_attack` (`faction.cpp`),
`find_proto`/`select_colony`/`select_combat` (`build.cpp`) — every
hand-rolled `report_and_return` lambda or inline mismatch check replaced
by the `_call`/`_check` pair, same call-site shape (the project's
established "1-3 line seam" convention held), backed by shared
infrastructure instead of copy-pasted `debug()` format strings. The
manual RNG snapshot/restore some of these carried (`mod_tech_ai`,
`find_proto`, `select_colony`, `select_combat` — the ones known to
consume RNG) was removed: `lua_ai_shadow_call` now does this
unconditionally for every hook, regardless of whether that specific hook
is known to touch RNG, which is both simpler and more robust (no
per-hook classification to keep correct as hooks evolve). Two
non-AI-decision hooks (`vehicle_counts_check`, `turn_state_hash`) kept
using plain `lua_ai_hook` directly (`out_count=1`) — no shadow
comparison needed, they're diagnostics with no "C++ equivalent result"
to compare against.

**`conf.lua_shadow`** (`src/main.h`/`docs/thinker.ini`) was already wired
as a config option since Phase 2B but documented as "reserved... no-op
for now" — it does something now; comments updated in both places.

**Sanity-checked at build time, then exercised live the same day — see
5.1.2.** Both presets (`ninja-debug`, `ninja-develop`) rebuild clean
throughout (checked after every file, not just at the end); every
touched/new Lua file (`lua/ai/build.lua`, `lua/ai/init.lua`) passes a
native-`luajit` `loadfile` syntax check. `register_hooks: 11 hook(s)
registered` (up from 9: the seven original hooks +
`vehicle_counts_check`/`turn_state_hash`, plus
`facility_score`/`governor_priorities` now) confirmed in 5.1.2's actual
run.

**Files touched:** `src/luaai.h`/`.cpp` (`out_count` param, `LuaShadowCall`,
`lua_ai_shadow_call`/`lua_ai_shadow_check`), `src/tech.cpp`,
`src/faction.cpp`, `src/build.cpp`, `src/game.cpp` (`out_count` added to
the two non-shadow hook calls), `src/plan.cpp` (two new hook seams),
`lua/ai/build.lua` (two new adapters), `lua/ai/init.lua` (two new
registrations), `src/main.h`/`docs/thinker.ini` (`lua_shadow` comment
update).

### 5.1.2 Shadow mode exercised live (2026-07-16) — harness ini-overwrite bug found & fixed, first real run clean

First actual `lua_shadow=1` session, via `tools/autoplay_run.sh
--no-xvfb`. Two real gaps found and fixed before any comparison data could
be trusted (full hunt: `DEVELOPMENT_DIARY.md`, 2026-07-16):

- **The harness silently discarded `lua_shadow=1`** — the "force the
  settings this harness needs" block overwrote `thinker.ini` with the
  shipped template's `lua_shadow=0` default and never re-forced it. Fixed
  with a new `--lua-shadow` flag.
- **No way to confirm which flags were actually in effect after the
  fact** — zero mismatch lines in `lua.log` looks identical whether shadow
  ran and matched, or never ran at all. Fixed with a `config: lua_ai=%d
  lua_shadow=%d lua_strict=%d autoplay=%d` line at the end of
  `lua_ai_init`.

**Result: three full `--no-xvfb --lua-shadow` autoplay runs, three
distinct manually-started games (one deliberately including a `rule_psi`
faction), `outcome: COMPLETED` every time, zero `lua/cpp ... mismatch`
lines across all 9 hooked decision functions in any run.** Gate item (d)'s
acceptance criterion (zero divergences across 3+ distinct saves/maps
including `rule_psi`) is met — see `IMPLEMENTATION_PLAN.md`'s Consolidation
gate for the formal close-out.

**Files touched:** `tools/autoplay_run.sh` (`--lua-shadow` flag, header
doc), `src/luaai.cpp` (startup `config:` echo line).

### 5.2 Golden traces and out-of-game tests

- Instrument the C++ side (debug build) to emit JSON fixtures per function:
  args, observed state, RNG before/after, result (plan 5.2).
- Replay runner on Arch's native `luajit` (`pacman -S luajit`): loads fixtures,
  injects `observed_state` through a fixture-backed `api/` implementation, runs
  the ported function, compares result and RNG consumption. Runs in CI.
- `lua/ai/*` must import engine access only via `lua/api/*`; the ffi require
  lives inside `api/`, never in `ai/` — that is what makes fixture-backed and
  mock `api/` implementations possible. Synthetic mocks come after traces, for
  corner cases traces don't reach.
- Runner: plain `luajit lua/test/run.lua` looping over `test_*.lua`; no
  framework dependency needed initially.

### 5.2.1 Golden traces implemented, first slice (2026-07-16) — Consolidation gate item c, `facility_score`/`governor_priorities`

**Status: ✅ done, verified genuinely end-to-end** — hand-built fixtures
(including a deliberately-wrong case, to prove the checker isn't vacuous)
plus a real capture from a live `--golden-trace` autoplay session:
**1265/1265 passed**, zero failures. Implementation narrative:
`DEVELOPMENT_DIARY.md`, 2026-07-16.

**Why now, despite 4.9's original "no dual-run seam" rationale being
stale.** Both functions are shadow-hooked now (5.1.1/5.1.2, Consolidation
gate item b) and confirmed live with zero divergences (gate item d) — no
longer the least-validated code in the port. But shadow mode only ever
runs *inside* a live game process. Golden traces are a different,
complementary layer: capture (args, engine state, result) once, then
replay through the Lua port under Arch's *native* `luajit` — no Wine, no
Xvfb, no save file, in principle CI-runnable. That's the actual
motivation to still build this, not the original "unvalidated" framing.

**Capture side is pure C++ instrumentation, independent of
`lua_shadow`.** `src/golden_trace.h`/`.cpp` (new): two purpose-built
functions (not a generic JSON-value abstraction — only two call sites
exist), each taking flattened ints only, same precedent as
`lua_ai_shadow_call` flattening `WItem` rather than passing the struct.
Gated on a new `conf.golden_trace` flag (`src/main.h`/`main.cpp`, same
"unlisted debug option" pattern as `minimal_popups` — not in the shipped
`docs/thinker.ini` template), zero-overhead early return when unset, same
convention as `lua_shadow`. Doesn't invoke the Lua side at all — just
records what the C++ implementation already computed — so it works
whether or not `lua_ai`/`lua_shadow` are even on. Appends one JSON-Lines
object per call to `golden_traces.jsonl` in the game dir, opened in
**append mode** (unlike `lua_log`'s per-VM-init truncate), so a fixture
corpus can accumulate across multiple sessions/games instead of only
capturing one run — `tools/autoplay_run.sh`'s stale-log cleanup step
deliberately excludes it for the same reason. One call site each added
in `src/plan.cpp`'s `facility_score`/`governor_priorities`, right next to
the existing shadow-mode calls — all the values needed (`Wgov`, `p`,
`value`, `base`, `f`, `is_human(...)`, `cpp_out`) were already in scope,
so this is a true 1-3 line addition per function.

**Fixture format** (JSON Lines, nested `args`/`observed_state`/`result`
objects, matching Plan 5.2's schema exactly):
```json
{"function":"governor_priorities","args":{"base_id":5},"observed_state":{"base":{"governor_flags":0,"defend_goal":2,"faction_id":1,"is_human":1},"faction":{"AI_growth":0,"AI_tech":0,"AI_wealth":0,"AI_power":0,"AI_fight":0}},"result":{"AI_growth":4,"AI_tech":1,"AI_wealth":1,"AI_power":1,"AI_fight":0},"rng_before":1234,"rng_after":1234}
```
`rng_before`/`rng_after` are captured for schema uniformity with future
hooks even though these two are RNG-free by construction (no `random()`
calls in either) — always equal here, read once via the existing
`game_rand_state()` accessor (Phase 5.3.5).

**Replay runner is the hard part, and the actual reason this needed real
design work.** `tools/golden_trace_replay.lua` (new) runs under Arch's
*native* `luajit` — a different process, architecture, and (typically)
pointer width than the embedded 32-bit-Windows LuaJIT inside
`thinker.dll`. `lua/api/base.lua`/`faction.lua`/`tech.lua` read live
engine memory via `ffi.cast` on pointers obtained from the real
`LuaHostApi`, and `lua/ffi/validate.lua`'s sizeof/alignof/offsetof checks
validate against the real mingw-compiled struct layout — none of that
exists, or would even validate correctly, outside the actual running
game process. So the replay runner can't load the real `lua/api/*.lua`
modules unmodified; it needs fixture-backed substitutes, exactly Plan
5.2's "fixture-backed `api/` implementation" step.

This turned out tractable because `lua/ai/build.lua` loads its
dependencies via plain `dofile(path)` at file scope — this project never
uses `require` (`lua/init.lua`: `package` stays disabled outside debug
builds) — and `dofile_once` (`lua/init.lua:28`) is just a 6-line
memoizing wrapper the replay runner can reimplement itself. The runner
**overrides the global `dofile`** before loading `lua/ai/build.lua`,
intercepting exactly the three module paths `facility_score`/
`governor_priorities` call into (`lua/api/base.lua`, `faction.lua`,
`tech.lua`) with fixture-backed plain-Lua-table stand-ins, and returning
trivial empty stubs for the other modules `build.lua` also `dofile`s at
load time for *unrelated* functions (`game.lua`, `rand.lua`, `veh.lua`,
`lua/ffi/funcs.lua`) — none of those are called by the two functions
under test, they just need to not error at module-load.
`lua/api/cmath.lua` is the one exception loaded **for real** (delegated
to the real `dofile`): it's pure Lua using only LuaJIT's built-in `bit`
library (available under native `luajit` too), no `ffi`/host dependency
at all, so faking it would be pure risk for no benefit.

**One stub can't be trivially empty, found before running anything (not
by trial and error):** `lua/ffi/validate.lua`, because `local E =
types.enums` (`lua/ai/build.lua:47`) evaluates unconditionally at module
load, and `governor_priorities`'s `is_human` branch indexes
`E.GOV_PRIORITY_EXPLORE`/`DISCOVER`/`BUILD`/`CONQUER` unconditionally —
an empty-table stub makes `E` non-nil at load time but crashes on first
use ("attempt to index a nil value") once one of those keys is read from
an empty table used as a bitmask operand... actually crashes earlier:
`types.enums` itself is `nil` on an empty `{}` stub, so `local E = nil`,
and *any* `E.FOO` lookup inside `governor_priorities` errors immediately.
Fixed by hand-copying the four real values from `engine_base.h`
(`GOV_PRIORITY_EXPLORE = 0x1000000`, `DISCOVER = 0x2000000`, `BUILD =
0x4000000`, `CONQUER = 0x8000000`, matching `lua/ffi/types.lua`'s
generated constants) into the replay script's stub — these are stable
engine constants, not expected to change, and the correctness of the
replay depends on using the *real* bit values so branch decisions on a
captured `governor_flags` bitmask reproduce correctly.

No production Lua file changes at all — every bit of fixture
substitution lives in the new replay-runner file. `lua/ai/build.lua`
itself loads through the real, unpatched `dofile`.

**Build note:** the glob-based `file(GLOB ... "src/*.cpp")` in
`CMakeLists.txt` needs a fresh `cmake --preset ...` configure to pick up a
newly-added `.cpp` file — a build-only `cmake --build` after adding
`src/golden_trace.cpp` fails to link with "undefined reference" until
reconfigured.

**Files touched:** `src/golden_trace.h`/`.cpp` (new), `src/main.h` (add
`#include "golden_trace.h"`, `golden_trace` config field), `src/main.cpp`
(`option_handler` branch), `src/plan.cpp` (two call sites),
`tools/golden_trace_replay.lua` (new), `tools/autoplay_run.sh`
(`--golden-trace` flag, artifact collection, cleanup exclusion).

### 5.3 Autoplay harness and graduated equivalence

- `src/test.cpp` / `extra_setup()` is an **empty debug-build scaffold** — no
  autoplay facility exists today. Add a config `autoplay_turns=N`: when set,
  `mod_turn_upkeep` (hooked at `patch.cpp:656`) auto-ends turns for the player
  faction and calls save + exit at turn N. (Still open — see below for the
  narrower dialog-bypass problem, solved separately and first.)

#### 5.3.1 Dialog-bypass spike (2026-07-14) — implemented, in-game verification pending

An all-AI game (every faction set to computer-controlled in the New Game
screen) needs no `autoplay_turns`-style turn forcing — nothing waits for
human input, so `mod_turn_upkeep`'s own turn loop just runs. `is_human()`
(`faction.cpp:109`) reads `FactionStatus[0]`, a bitmask set entirely by the
game's own setup screen; nothing in Thinker's code requires a human faction
to exist. The actual blocker for running such a game unattended: several
`popp()`/`interlude()`/etc. calls in `game.cpp` fire unconditionally, **not**
gated on `is_human` (climate change `SEARISING`/`SEAFALLING`, alien arrival
`ALIENSARRIVE`, Planetary Council `COUNCILOPEN`, the victory-condition popups
at `game.cpp:1339-1525`, and others not yet enumerated) — each blocks the
window message loop waiting for a click.

**Approach taken (a short, deliberately iterative spike, not an attempt to
enumerate every human-assuming path up front — that isn't tractable):** a
grep of every popup/dialog call site across `src/*.cpp` (223 call sites, 14
files) found they all funnel through exactly six raw engine primitives:

| Primitive | Typedef | Engine address |
|---|---|---|
| `POP2` | `FPOP2` | `0x405140` |
| `popp` | `Fpopp` | `0x48C0A0` |
| `popp_2` | `Fpopp_2` | `0x50B970` |
| `interlude` | `Finterlude` | `0x5230E0` |
| `X_pop_9` | `FX_pop_9` | `0x5BF480` |
| `X_pops_18` | `FX_pops_18` | `0x5BF930` |

(`X_pop2`/`X_pop3`/`X_pop7`/`X_pops3`/`X_pops4`/`X_dialog`, `gui_dialog.cpp`,
are Thinker's own thin wrappers over `X_pop_9`/`X_pops_18` — already
covered by wrapping the two primitives underneath, no separate handling
needed. `pop_wait` is not a primitive to bypass: it's passed *as an argument*
to the others — the "how to wait for a click" strategy they invoke
internally — so it's never called directly and needs no shim.)

**Mechanism — redirect at the definition site, not the call site.** Every
one of these six is a plain global function-pointer variable
(`Fpopp popp = (Fpopp)0x48C0A0;` in `engine.cpp`), not something patched in
via `write_call` from an engine call site. That means the single highest-
leverage change is at the *definition*, not any of the 223 callers:

```cpp
// engine.cpp — before
Fpopp popp = (Fpopp)0x48C0A0;

// engine.cpp — after
Fpopp popp_engine = (Fpopp)0x48C0A0;  // the real engine function, still callable
Fpopp popp = autoplay_popp;            // shim; engine.h's `extern Fpopp popp;`
                                        // is untouched, so all 223 call sites
                                        // keep compiling and calling `popp`
                                        // exactly as before
```

Applied identically for all six (`engine.h` gained one matching
`extern <Type> <name>_engine;` next to each existing `extern <Type> <name>;`
declaration). Net diff: 6 lines added to `engine.h`, 6 lines changed in
`engine.cpp`, zero changes to any of the 223 call sites.

**New files `src/autoplay.h`/`src/autoplay.cpp`:** one shim per primitive,
matching its exact typedef. Each shim: if `conf.autoplay`, logs the call
(function name + label/filename argument — the piece that lets iteration
converge fast, see below) to a dedicated `autoplay.log` in the game folder
(own `fopen`/`fflush`-per-write, same always-available rationale as
`lua.log`, 2.6 — `autoplay` isn't a debug-build-only feature) and returns a
safe default (`0`) **without** calling through to the real engine function
(that's what prevents the modal from ever opening); if `conf.autoplay` is
off, calls straight through to the `_engine` pointer, so `autoplay=0`
(the default) is a no-op by construction — verified by a clean build and
link on both presets with no behavioral-diff review needed beyond that.

**New config `conf.autoplay`** (0/1, three-place pattern: `main.h`,
`main.cpp`'s `option_handler`, `docs/thinker.ini`).

**Iteration model (matches how this was scoped — run it, see what's still
missing, extend, repeat):** if an unattended all-AI session still hangs on
some dialog, `autoplay.log`'s last line names exactly which of the six
primitives and which label was reached right before the hang (that label
string is always the second argument logged) — add a label-specific branch
in that one shim, rebuild, redeploy, retry. The funnel being only six
functions wide is what should make this converge in a handful of iterations
rather than an open-ended search.

**Scope limits, both deliberate:**
- The shims gate on `conf.autoplay` alone, not `is_human` — if a human
  faction is present in the same session with `autoplay=1`, dialogs meant
  for that human's own choices (diplomacy proposals via `X_dialog`, the
  `SOCIETY` social-engineering picker, event notices) are auto-dismissed
  the same as AI-facing ones, since the shim has no way to know which
  faction the dialog was "for." This option is for unattended all-AI
  sessions; leave it at `0` for normal human play.
- `autoplay_turns`-style auto-save-and-exit (forcing an exit via
  `*ControlTurnA`/`*ControlTurnB` outside `end_of_game`'s own sequence,
  which also runs `report_score`/`hall_of_fame`/replay bookkeeping first,
  `game.cpp:1516-1535`) was intentionally left out of this pass — that's a
  separate concern from the dialog-hang problem this spike targets, and its
  exact semantics outside a real win/loss condition aren't confirmed yet.
  Stopping an unattended run manually (close the Wine window once
  `autoplay.log`/`debug.txt` show enough turns) is sufficient for now.

**`autoplay_demote_human()`** (`src/autoplay.cpp`, called every
`mod_turn_upkeep`): the New Game screen always requires picking one faction
to control, and `thinker_enabled()` separately excludes whichever faction is
marked human from Thinker's *entire* AI stack, not just its dialogs — so
picking a faction at setup left it with no AI running at all. When
`conf.autoplay` is on, this clears the picked faction's human bit in
`FactionStatus[0]` every turn (idempotent, logs the demotion to
`autoplay.log`), also sets `*GameMorePreferences |=
MPREF_AUTO_ALWAYS_INSPECT_MONOLITH` to suppress one popup class that
originates inside the un-decompiled engine binary (where the six-primitive
shim can't reach — redirecting a global variable isn't the same as
redirecting a function baked into hardcoded-address machine code; a proper
fix needs `write_call`-patching specific call sites, not done). **Also
wired, explicitly experimental with real crash risk:**
`autoplay_try_end_turn()`, calling the previously-never-used
`Console_end_my_turn` (`engine.cpp:2135`) from the idle-timer callback
`mod_blink_timer`, to auto-advance past End Turn.

**Status: ✅ mechanism validated in combination over multiple real sessions**
(Consolidation gate item a). Bug hunts (Quit dialog answered wrong by
default, the End Turn callback silently never installed) and the
nine-primitive catalog correction: `DEVELOPMENT_DIARY.md`, 2026-07-14/15.

- State hash: end-of-turn Lua script iterating factions/bases/vehs writing one
  line per turn to a hash log; two runs with the same seed must produce
  identical files (`cmp`). **Implemented, see 5.3.2.**
- Report divergence at the **first level** it appears (plan 5.3's five levels:
  per-call output → per-call delta → phase hash → turn hash → N-turn
  trajectory) to localize bugs instead of "turn 40 differs".

### 5.3.2 Autoplay harness script + per-turn state hash (2026-07-15)

Builds the tooling Consolidation gate item (a) needed: `tools/
autoplay_run.sh` (deploy, launch, watchdog, classify, collect, restore) and
its dependency, the per-turn state-hash dump from Lua
(`lua/harness/state_hash.lua`). Status and later fixes: `DEVELOPMENT_
DIARY.md`, 2026-07-15/16.

**Per-turn state hash (`lua/harness/state_hash.lua`, new module, new
`lua/harness/` directory).** Not an AI decision — nothing to propose, no
class, no fallback question — so it deliberately lives outside `lua/ai/`
despite being wired through the exact same `lua_ai_hook` dispatch
`lua/ai/build.lua`'s `vehicle_counts_check` (4.10.10) already established
as the way to get a Lua function called from a C++ seam with zero new
host-API plumbing: `lua/ai/init.lua` just adds one more entry
(`turn_state_hash = state_hash.dump`) to the table `register_hooks()`
already reads. C++ side: one `lua_ai_hook("turn_state_hash", &dummy,
{*CurrentTurn})` call inserted into `mod_turn_upkeep`
(`src/game.cpp:1011`), right after `lua_ai_turn_upkeep()`/
`autoplay_demote_human()` and before the turn's own processing touches
anything — so it captures the end state of the turn that just completed,
matching the plan's "end-of-turn" wording literally, and fires exactly
once per turn transition regardless of `conf.autoplay` (useful for manual
determinism checks too, not just autoplay runs).

Folds in, all read in index order (`0..count-1` / `1..MaxPlayerNum-1`,
never `pairs()` — the plan's iteration-order determinism rule applied here
too, since a nondeterministic hash would defeat the harness's purpose even
though this isn't a decision): every base's `faction_id`/`x`/`y`, every
vehicle's `faction_id`/`x`/`y`/`unit_id`, and per faction `tech_ranking`
("twice the number of techs discovered", the closest existing field to a
tech-progress summary) and `energy_credits`. Two new `Faction` fields
needed for this (`tools/gen_ffi.cpp`): `energy_credits`, `tech_ranking` —
everything else (`BASE.faction_id/x/y`, `VEH.faction_id/x/y/unit_id`,
`Faction.base_count`) was already exposed by earlier slices (4.7/4.8/
4.10.1). No `LuaHostApi`/`api_version` change — nothing here needed a host
wrapper, only FFI field reads through the existing `lua/api/base.lua`/
`veh.lua`/`faction.lua` accessors.

**Hash function: FNV-1a-style mix using only `bit.bxor`/`bit.rol`, no
multiply.** A textbook FNV-1a uses a multiplicative step, but Lua numbers
are doubles and the running hash can reach values where a multiply-then-
`bit.tobit` truncation would go through a double-precision product that
isn't exactly representable — not a correctness problem for this specific
use (the hash only needs to be internally reproducible run-to-run, there's
no C++ reference hash to match bit-for-bit, unlike every dual-run mismatch
check elsewhere in `lua/ai/`), but avoidable, so avoided: `bit.rol` is a
LuaJIT `bit` library extension (32-bit rotate) that's exact, same as
`bxor`. Formatted with `bit.tohex(h)`, not `string.format("%x", h)` —
`tohex` always produces the unsigned 8-hex-digit form directly, sidestepping
a sign-representation question `%x` on a `bit.*`-returned (signed 32-bit)
Lua number would otherwise raise.

**`tools/autoplay_run.sh`.** Bash, not Lua — orchestrates the process
outside the game, per the plan's own description of item (a). Flow:
validate the requested preset's build exists → `tools/deploy.sh` → back up
any existing `thinker.ini` (via `mktemp`) and write a harness one (starts
from `docs/thinker.ini`, forces `autoplay=1`/`lua_ai=1`/`lua_strict=0`
with `sed`, preserving CRLF explicitly — `docs/thinker.ini` is CRLF, a
plain `sed -i 's/.../replacement/'` without a trailing `\r` in the
replacement silently drops just that one line to LF, confirmed and fixed
during implementation) → remove stale `lua.log`/`autoplay.log`/
`debug.txt` from any prior session (they're append-mode; a leftover file
would make the very first watchdog poll see an already-advanced turn
number) → `setsid xvfb-run -a env -u WAYLAND_DISPLAY WINEPREFIX=... wine
thinker.exe -windowed` in the background, exactly the command form the
session that requested this specified → discover the Xvfb display number
`xvfb-run -a` allocated by diffing `/tmp/.X*-lock` before/after (needed
for screenshots; `xvfb-run` doesn't expose the number it picked any other
way) → watchdog loop polling `lua.log` for the last `state_hash turn=N`
line, resetting a stall timer on every new `N` → classify `COMPLETED`
(reached the target turn), `STALL` (no new turn within the timeout —
capture a screenshot, see below) or `CRASH` (the process group died on its
own) → `kill -TERM`/`-KILL` the **whole process group** (`setsid` gives
`xvfb-run`/`Xvfb`/`wine`/`wineserver` one group so a single negative-PID
`kill` takes all of it down, regardless of whether `xvfb-run`'s own
cleanup trap runs) → copy `lua.log`/`autoplay.log`/`debug.txt`/`saves/`
plus a `state_hashes.log` (just the hash lines, grepped out, for the
`cmp`-between-runs check plan 5.3 describes) into
`runs/<UTC timestamp>-<preset>/` → restore the original `thinker.ini` via
an `EXIT` trap (fires on normal completion, an early error exit, or
Ctrl+C — a harness run must never leave `autoplay=1` permanently applied
to whatever `thinker.ini` the user had).

**Screenshot capture prefers `xwd`+`convert` (what the requesting session
specified) but falls back to ImageMagick's `import`.** Confirmed during
implementation: this machine has `convert` but not `xwd` (`xorg-xwd` is a
separate, uninstalled package) — `import -window root` produces the same
result without the extra dependency, so the script tries the specified
tool first and only falls back if it's missing, rather than requiring an
install this session didn't otherwise need.

**Process-liveness mechanics, confirmed by reading `setsid`'s actual
behavior, not assumed:** `setsid CMD` (no `-f`) calls the `setsid()`
syscall and then `execvp`s `CMD` in the *same* process — it does not fork
— so the backgrounded PID bash captures (`RUN_PID=$!`) is directly
`xvfb-run`'s own PID, which is also the new session/process-group leader.
That's what makes `kill -0 $RUN_PID` a correct liveness check and
`kill -TERM -$RUN_PID` (negative PID = process-group signal) a correct
"take down everything" call, without needing to separately track Xvfb's
or wine's PIDs.

**KNOWN GAP #1, still open: this script cannot reach an in-progress game on
its own.** `src/main.cpp`'s argv parsing only handles
`-smac`/`-native`/`-screen`/`-windowed` — no flag to auto-load a save or
skip the main/New Game menu, and the six-primitive dialog bypass (5.3.1)
doesn't cover the main menu itself. So a harness run against a fresh
session sits at the main menu until it times out; reaching an in-progress
game still needs one manual interactive step first (New Game screen, or
Load) before the script's automation takes over. `--save FILE` is accepted
and forwarded as a bare `wine` argument on the chance the engine honors it,
but this is unverified — `cmd_parse()` gives no reason to expect it works.
Deferred to a future session, non-blocking for the Consolidation gate (see
`IMPLEMENTATION_PLAN.md`, gate item a).

**KNOWN GAP #2, resolved (see 5.3.5): Xvfb itself couldn't run the game at
all on this dev machine** — every launch under Xvfb died ~1-2s after
`patch_setup` regardless of graphics configuration tried. Ruled out as a
DirectDraw/PRACX problem specifically (a plain `wine notepad` survives fine
under the same Xvfb); no replacement hypothesis found. `--no-xvfb` on the
real desktop satisfies every run this project's validation needs, so this
was demoted to nice-to-have rather than chased further.

**Files touched:** `tools/gen_ffi.cpp` (`Faction.energy_credits`/
`tech_ranking`), `lua/harness/state_hash.lua` (new), `lua/ai/init.lua`
(one new registry entry), `src/game.cpp` (`mod_turn_upkeep` seam),
`tools/autoplay_run.sh` (new), `.gitignore` (`runs/`). Both build presets
(`ninja-develop`, `ninja-debug`) compile clean; `lua/harness/state_hash.lua`
and `lua/ai/init.lua` pass a native-`luajit` `loadfile` syntax check;
`lua/ffi/types.lua` inspected directly for the two new `Faction` offsets.

**Status: ✅ mechanism validated in real use** (Consolidation gate item a).
The wrong-`cwd` bug that broke every launch under this harness, and the
Xvfb investigation behind KNOWN GAP #2's resolution above: `DEVELOPMENT_
DIARY.md`, 2026-07-15.

### 5.3.3 Real validation runs (2026-07-15) — 4/4 runs clean, 3 real bugs found (2 fixed, 1 open), the six-primitive catalog corrected

**Status: ✅ Consolidation gate item (a) satisfied** (the determinism
re-run this session flagged as still needed was later dropped by decision,
5.3.6). Four `--no-xvfb` sessions on the real desktop, all `COMPLETED`
clean:

| Round | Demoted faction | Turns | Outcome | Notes |
|---|---|---|---|---|
| 1 | PEACE | 80 | manual stop | pre-dates the cwd fix (5.3.2) and the `game_alive` fix below |
| 2 | USURPER | 100 | `COMPLETED` | first run of the actual script; revealed the End Turn problem |
| 3 | (unrecorded) | 80 | `COMPLETED` | first run after the blink-timer fix; confirmed End Turn auto-advances |
| 4 | (unrecorded) | 80 | `COMPLETED` | fixed seed **15373264**, logged at game start — used by 5.3.4's determinism testing |

Two real bugs found and fixed: `game_alive()` (the watchdog was checking
the launcher's PID, not the actual game's — `thinker.exe` exits by design
after handing off to `terranx.exe`, misclassified as `CRASH` every run),
and `autoplay_try_end_turn` was never once invoked (the timer callback that
calls it is normally only installed under an unrelated `smooth_scrolling`
option, off by default). Full bug-hunt narrative: `DEVELOPMENT_DIARY.md`,
2026-07-15.

**Six-primitive dialog-bypass catalog (5.3.1) was incomplete — corrected to
nine.** `engine.h` declares ~33 raw popup primitives total; the original
spike's grep found only two because it searched for Thinker's own
convenience-wrapper names and missed bare numbered primitives. Of the
remaining ~27, only three (`X_pop`, `X_pop_2`, `X_pops`) actually have call
sites in Thinker's own recompiled source — fixed with three new shims,
same `_engine`-suffix pointer-swap pattern as the original six.

**Still open: tech-discovery announcement.** `tech_achieved` lives entirely
inside the original, un-decompiled engine binary — not fixable by pointer
redirect, same category as the monolith-popup gap (5.3.1). A real fix needs
disassembly work not done. Lower frequency than End Turn was; not a
blocker.

**Partial mitigation: secret-project completion, 2 clicks → 1** via the
pre-existing `minimal_popups` debug option, added to the harness's forced
settings — removes the datalinks-entry screen; the completion notice itself
still requires one click, not root-caused (plausibly the same
un-decompiled-binary problem as tech-discovery).

**Files touched:** `tools/autoplay_run.sh` (`game_alive()`, `--no-xvfb`
real-display support, `--screenshot-interval`, `minimal_popups=1`),
`src/patch.cpp` (blink-timer `else if (cf->autoplay)` branch),
`src/autoplay.cpp`/`.h` (three new shims), `src/engine.cpp`/`.h` (three new
`_engine`-suffix pointer pairs).

### 5.3.4 Determinism testing across process launches — `fixed_rng_seed` (2026-07-15)

**Architectural fact found: the mod's own RNG stream is not tied to the
save file at all.** `DLL_PROCESS_ATTACH` seeds both `random_reseed()` (the
LCG `random()`/`rand.map()` draw from) and `map_rand` from `GetTickCount()`
— system uptime in milliseconds — every time the DLL loads, independent of
any save loaded afterward. No in-game "preserve random seed" option exists.

**Fixed:** new `fixed_rng_seed` config option, default `0` (unchanged
behavior). When nonzero, used as the seed instead of `GetTickCount()`.
Wired into the harness as `--rng-seed N`.

**Exercised live: `fixed_rng_seed` confirmed working (turn-1 state
byte-identical across launches with the seed pinned), but full determinism
not achieved — turn 2 still diverges.** Traced one real mechanism: single-
player pod-opening (`veh.cpp`'s `goody_pod_pop`-style code) only reseeds a
position-independent local stream when `*MultiplayerActive`; in
single-player it draws from the **main sequential** `random()`/`game_rand()`
stream instead, so its outcome depends on everything the other six
AI-controlled factions already drew that turn, outside the human's control.
Not root-caused further this session.

**Correction (external review, same day): this is not the project's
"bit-exact only where achievable" tolerance case** — that framing covers
Lua-vs-C++ tolerance between two different implementations, not a single
binary diverging from itself across two launches of the identical save with
the identical pinned seed. That's ambient nondeterminism, and it directly
blocked the Consolidation gate's item (d) as originally scoped (a systemic
state-hash comparison method) — see 5.3.5/5.3.6 for the diagnostics and the
eventual decision to drop that comparison method rather than keep chasing
it. Full session narrative: `DEVELOPMENT_DIARY.md`, 2026-07-15.

### 5.3.5 RNG divergence diagnostics + Xvfb re-attempt (2026-07-15, external review follow-up)

External review re-ranked the open gaps from 5.3.3/5.3.4: the turn-2+ RNG
divergence is **blocking** (invalidates gate item (d)'s whole comparison
method), Xvfb is **not** blocking (item (a)'s validation matrix is already
satisfied by `--no-xvfb`). This section builds instrumentation; the actual
root-cause run is 5.3.6.

**RNG diagnostics added, all gated cheap-or-conf.autoplay-only:**

1. **Save-load RNG snapshot** (`src/game.cpp`, `mod_load_daemon`): logs
   `game_rand_state()`, `random_state()` (the mod's own LCG), and
   `map_rand.get_state()` immediately after `load_daemon()` returns,
   gated on `conf.autoplay` (`debug.txt`: `load_daemon rng: game_rand=...
   mod_rng=... map_rng=...`). Answers the question 5.3.4 left open: is
   the *engine's own* `game_rand` state (not just the mod's, which
   `fixed_rng_seed` already pins) identical across two loads of the same
   save? Not yet run to find out — the instrumentation is built, the
   comparison isn't done.
2. **Per-faction RNG draw counters** (`src/random.cpp` + `src/veh_turn.cpp`):
   three new running counters, never reset, incremented on every call to
   `random()`/`random_get()` (`g_mod_rng_draws`), `game_randv()`
   (`g_game_rand_draws`), and `GameRandom::get()`/`get(low,high)`
   (`g_map_rand_draws` — `map_rand`, used by `pick_tile` and friends).
   Logged at the top of `mod_enemy_turn` (`veh_turn.cpp`, once per faction
   per turn, right where the existing `enemy_turn %d %d` line already is),
   gated on `conf.autoplay` since this one *is* noisy (up to 7x/turn).
   Turns "audit all turn-1 AI code for a source of nondeterminism" into
   "diff two `debug.txt`s and find the first faction whose counter already
   differs before any value does" — counts diverging always precedes (and
   is far cheaper to spot than) a value divergence.
3. **Per-turn RNG state in `state_hashes.log`** (`lua/harness/state_hash.lua`):
   the existing per-turn line gained `rng=<game_rand_state>:<mod_rand_state>:
   <map_rand_state>` (hex, matching the hash's own format) — deliberately
   **not** folded into the hash itself (a different signal, kept visible
   rather than opaque). Lets a future comparison spot "the first turn
   where RNG state differs while the state hash still happens to match"
   directly from `state_hashes.log` alone, no `debug.txt` correlation
   needed for that specific question.

**Plumbing:** `LuaHostApi` gained six new read-only accessors
(`game_rand_state`/`mod_rand_state`/`map_rand_state`/`game_rand_draws`/
`mod_rng_draws`/`map_rng_draws` — `src/luaai.h`/`.cpp`, `api_version`
8→9), `lua/ffi/funcs.lua` (`HOST_API_VERSION` bumped to match),
`lua/api/rand.lua` (six new exports: `game_state`/`mod_state`/
`map_state`/`game_draws`/`mod_draws`/`map_draws`). None of these consume
their stream (unlike `rand.game`/`rand.map`, which do) — pure peeks, safe
to call from anywhere without perturbing determinism themselves. Both
presets rebuild clean. **Not yet exercised live** — validating this needs
an actual save-load-twice session, which is the follow-up work this
instrumentation was built for, not something this pass did.

**Xvfb re-attempt:** three suspects tried individually then combined —
higher screen depth/resolution, the GDI renderer, `WINEDLLOVERRIDES=
"ddraw=b"` to rule out PRACX. **No change in any case** — every variant
dies at the exact same point regardless of graphics configuration. Sanity
check: `wine notepad` under the identical Xvfb instance survives fine,
ruling out Xvfb-vs-wine breakage in general. **Conclusion: the
DirectDraw/PRACX hypothesis (5.3.2) is ruled out, not just unconfirmed.**
No replacement hypothesis tested. Demoted to nice-to-have — see 5.3.2's
KNOWN GAP #2.

**Files touched:** `src/random.h`/`.cpp` (three draw counters),
`src/game.cpp` (`mod_load_daemon` RNG snapshot log), `src/veh_turn.cpp`
(`mod_enemy_turn` draw-count log), `src/luaai.h`/`.cpp` (six new
`LuaHostApi` entries, `api_version` 9), `lua/ffi/funcs.lua`
(`HOST_API_VERSION` 9), `lua/api/rand.lua` (six new exports),
`lua/harness/state_hash.lua` (`rng=` field on the per-turn line). Wine
prefix registry change made and reverted (GDI renderer test). Both
presets rebuild clean throughout.

**Root-cause run done — see 5.3.6, one real fix landed, divergence
narrowed but not eliminated.** The two item-(a) sub-items explicitly
deferred by the external review (harness menu bootstrap, tech-discovery
preference-flag experiment) remain not started — see
`IMPLEMENTATION_PLAN.md`'s item (a) status for both.

### 5.3.6 `game_rand` pinning + root-cause run (2026-07-15) — divergence point moved from turn 2 to turn 3, not eliminated

The 5.3.5 diagnostics, run for real: `mod_rng`/`map_rng` matched across
launches as already known, but **`game_rand` (the engine's own RNG) did
not** — `fixed_rng_seed` only ever pinned the mod's own streams, the
engine's `game_rand` drifted freely from process start.

**Fixed:** `mod_load_daemon` now calls the existing
`game_rand_restore(conf.fixed_rng_seed)` immediately after `load_daemon()`
returns (deliberately post-load, not at `DLL_PROCESS_ATTACH` — an
uncontrolled number of draws happen between process start and reaching the
load screen).

**Result: turns 1 and 2 now match completely** (state hash and all three
RNG-state fields byte-identical, up from turn 1 only). Full trajectory
still diverges, first at turn 3 — localized to a specific event
(`enemy_turn 3 1`, an extra Unity Rover sequence in one run) with identical
RNG-draw counts on both sides up to that point, so the cause isn't (yet
visibly) a prior draw-count difference. Not root-caused further this
session — real, measurable progress (divergence pushed one full turn
later) but the full byte-identical-trajectory acceptance criterion was not
met. Investigation narrative: `DEVELOPMENT_DIARY.md`, 2026-07-16.

**Files touched:** `src/game.cpp` (`mod_load_daemon`, one
`game_rand_restore` call).

**Closed by decision (2026-07-16) — full-trajectory determinism dropped
as gate item (d)'s prerequisite, not resolved.** Rationale: per-call
shadow-mode comparison (5.1.1, item b) is strictly stronger evidence of
port fidelity than trajectory comparison, and needs no cross-launch
determinism at all — both sides run inside the same process invocation,
same call, same turn. The only future consumer of trajectory-style
comparison this project has is movement (M6), which per its own
performance/complexity profile will use a **windowed** method instead:
reload the same autosave twice, compare exactly one turn — not a full
N-turn trajectory. That windowed method's prerequisite is **single-turn**
reproducibility, which this session's work already delivers: turn 1 and
turn 2 came back byte-identical across launches once both
`fixed_rng_seed` and `game_rand_restore()` were in place (the pre-fix
baseline only had turn 1). Chasing engine-internal nondeterminism further
is also, on reflection, engine debugging rather than AI porting — outside
this project's charter (see `CLAUDE.md`'s scope). Net: the RNG-pinning
work is not wasted, it's re-purposed from "prove two processes reach the
same state" (dropped) to "prove one save reloads deterministically for
one turn" (M6's actual need, already met).

**Resume point, only if M6's windowed method fails for a reason that
traces back to this:** two discriminating tests were proposed (external
review) and deliberately **not run** this session —
1. Binary-diff the turn-2 autosaves between runs E and F (`runs/
   determinism-save/`, if still present, or a fresh same-seed pair) —
   confirms whether the state itself is identical at the point the
   divergence starts, independent of the state-hash mechanism.
2. Repeat the same-seed pair again (a third and fourth run) and see
   whether the divergence point (turn 3 this session) wanders to a
   different turn, or stays put — wandering would point at genuine
   nondeterminism (timing, uninitialized memory, ASLR-dependent container
   iteration); a stable turn 3 every time would point at something more
   mundane and reproducible, worth a real look.
Do not restart general-purpose determinism-chasing from here without a
concrete M6 trigger — this section's job now is to be found quickly if
that trigger happens, not to be worked proactively.

### 5.4 Performance instrumentation

Wrap the AI phases in `mod_turn_upkeep`/`move_upkeep`/production loops with
`GetTickCount()` deltas logged per faction per turn (debug builds). Baseline the
C++ numbers **before** the movement port starts, on a late-game save (huge map,
7 factions). LuaJIT profiler: `require("jit.p").start("vf")` toggled by an
Alt-key or config flag in debug builds. Watch specifically for **trace aborts
caused by host-API calls in hot loops** (`jit.v`/`jit.dump`); mitigate by
batching queries, moving loop-body data to FFI reads, or hoisting the C call.

---

## Phase 6 — docs, packaging, CI

- Packaging: add `cp -r lua/ .` steps to `tools/makedevzip.sh` and
  `tools/makerelzip.sh` (they currently copy `docs/*` + binaries into
  `build/tmp` and 7z it); add `lua/` sync to `tools/deploy.sh` (with delete of
  stale files — `rsync --delete` or `rm -rf` + copy).
- CI sketch (`.github/workflows/build.yml`): ubuntu-latest;
  `apt install g++-mingw-w64-i686-posix gcc-multilib ninja-build cmake`;
  `git submodule update --init`; build luajit (same make line, `HOST_CC="gcc
  -m32"` works with gcc-multilib); `cmake --preset ninja-develop && cmake
  --build --preset ninja-develop`; `luacheck lua/` + integer-expression lint;
  `luajit lua/test/run.lua` (golden-trace replay). Upload `thinker.dll`
  artifact.
- Docs to write: `docs/LUA_API.md` (incl. `cmath`, hook classes),
  `docs/LUA_PORTING.md` with the module checklist table (function → Lua file →
  **hook class** → status: pending/shadow/default → provenance commit).
- "Hello AI" example: override exactly one Class-1 hook (suggest a research
  scoring hook with a printed rationale) — small enough to read in one sitting,
  real enough to show the whole loop.

---

## Known traps (collected)

1. **Never init Lua in `DllMain`** — loader lock. Lazy init from
   `mod_turn_upkeep` (`game.cpp:1010`, patched at `patch.cpp:656-657`) (2.3).
2. `Vehs`/`Bases` are re-pointable — never bake their addresses into Lua (3.2).
3. `PMTable`/`NodeSet` are STL — host accessors only (3.4).
4. Engine structs have C++ methods — cdefs need field-only generation, done by
   the compiler-based generator, never by parsing (3.1).
5. No struct-size asserts exist in the headers — the generator's validation
   table (sizeof/alignof/offsetof per field) is the truth; assert at init (3.1).
6. `debug()` is a no-op outside debug builds — Lua logging gets its own
   `lua.log`, mirroring to `debug.txt` when present (2.6).
7. Integer `/` and `%` differ between C and Lua on negatives — `idiv`/`imod`
   mandatory in `ai/`; `bit.tobit` where C++ relies on 32-bit wrap (3.7).
8. Never call engine functions through Lua-declared FFI signatures — host-API
   wrappers only (read/write asymmetry, 3.3).
9. Class 3 hooks: no fallback to C++ after the first mutation — finish the
   unit safely and log instead (4.1).
10. Shadow mode must snapshot/restore *both* RNG streams (3.5, 5.1); Class 3
    hooks are never run twice (5.1).
11. `mod_enemy_move` orchestration stays in C++; hook the per-class movers (4.2).
12. Upstream rewrites big files — after every upstream merge, run the drift
    report and re-run `gen_ffi`; layout asserts catch silent struct changes
    (4.3, plan 4.4).
13. `conf.autoplay=1` bypasses dialogs for *everyone* in the session, not
    just AI factions — it doesn't check `is_human`. Fine for an all-AI game,
    but leave it at `0` if a human is also playing, or their own diplomacy/
    social-engineering/event dialogs get auto-dismissed too (5.3.1).

## Launch with:
WINEPREFIX=~/.wine-smac wine ~/.wine-smac/drive_c/Games/SMAC/thinker.exe
