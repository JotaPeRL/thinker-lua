# Implementation Details — tactical notes per phase

Companion to `IMPLEMENTATION_PLAN.md` (rev 2). The plan says *what* and *why*;
this file pins down *where* and *how*, with facts verified against the codebase
(line numbers as of commit `15418b2`; re-verify after upstream merges). It also
records corrections to earlier assumptions (see 3.1 and 3.4).

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

> **Status update (2026-07-14): in-game dual-run verification done, zero
> mismatches.** Two manual Wine play sessions, made much longer/deeper than
> would normally be practical thanks to the autoplay spike (5.3.1) letting
> turns run with no human clicking through popups:
> - Session 1: turns 9-13, all 7 AI factions, 75 `mod_social_ai` calls, all
>   with `pop_boom=0` and no available social-model alternative yet
>   (`sf=-1` throughout, tech-gated by `society_avail`) — zero mismatches.
> - Session 2: turns 80-89, all 7 AI factions, 70 calls, all with
>   `pop_boom=1` this time (population caught up), including two real
>   proposed-and-applied changes (`social_change` lines in `debug.txt`):
>   turn 81 BELIEVE Frontier→Fundamentalist (score 29), turn 82 GAIANS
>   Simple→Green (score 18). Lua's proposed `sf`/`sm2` matched C++'s
>   independently-computed value in both cases (that's *why* there's no
>   mismatch line) — zero mismatches across all 70 calls.
>
> Combined: ~145 dual-run calls across both hook-relevant branches
> (`pop_boom` 0 and 1, `sf` both `-1` and a real proposal that got applied),
> zero divergences. This clears the "budget time to root-cause a mismatch"
> concern below — none showed up. Temporary dual-run instrumentation
> (`src/faction.cpp`'s `mod_social_ai` seam) still in place; removing it in
> favor of real Phase 5.1 shadow mode remains open, same as M4/tech.
> `mod_wants_to_attack` (item 2b) still untouched.

> **Status (2026-07-13): implemented and building clean on both presets;
> in-game dual-run verification not yet run (needs a manual Wine play
> session — see IMPLEMENTATION_PLAN.md's status block for the checklist).**
> `social_score()` + the `sf`/`sm2` selection loop ported to
> `lua/ai/social.lua`, registered as `mod_social_ai` (`lua/ai/init.lua`),
> with the same temporary dual-run mismatch instrumentation as
> `mod_tech_val`/`mod_tech_ai` (`src/faction.cpp`'s `mod_social_ai` seam).
> `LuaHostApi` bumped to `api_version=4` with the 11 entries below.
> `tools/gen_ffi.cpp` gained a `FieldShape<T[N][M]>` partial specialization
> to flatten `Faction::social_psych` (`int32_t[8][9]`) into a single
> `int32_t[72]` cdef field (Lua indexes it `arr[i*9+j]`, row-major) — the
> first 2D array field this generator has needed to handle.
>
> **Corrections found while implementing** (re-derived directly from
> `social_score`/`mod_social_ai`'s bodies, not from the scope below, which
> both under- and over-specified the FFI surface):
> - **Missing, now added:** `Faction::social_support[8]`,
>   `Faction::social_psych[8][9]`, `Faction::social_effic[9]` (the AI's
>   score lookup tables) and a `keep_fungus(faction_id)` host wrapper
>   (`plans[faction_id].keep_fungus`) — `social_score` reads all four and
>   none were in the original field/wrapper list below. Also missing two
>   enums it branches on: `FAC_MANIFOLD_HARMONICS` (103) and
>   `RULES_SCN_NO_TECH_ADVANCES` (0x4000000) — both already existed in
>   `engine_enums.h`, just weren't listed.
> - **Listed but not actually needed, dropped:** `energy_credits`,
>   `SE_Politics_pending`, `SE_upheaval_cost_paid`. All three are read only
>   by `mod_social_ai`'s affordability-check-and-commit code *after* the
>   selection loop — code this port deliberately does not replicate (Lua
>   only proposes `sf`/`sm2`; C++ still decides afford/apply, unchanged).
>   Trimming these keeps the exposed FFI surface matched to what Lua
>   actually reads.
>
> Both build presets compile clean; `lua/ffi/types.lua` regenerated and its
> new `offsetof`/`sizeof` rows spot-checked against the flattened-array
> math by hand. Every new/changed Lua file passed a native-`luajit`
> `loadfile` syntax check (`pacman`'s `luajit`, not the mingw-embedded one —
> catches syntax errors only, not semantic ones, since it can't load the
> sandbox/ffi globals). **Not yet done:** the actual in-game run — deploy
> `debug`, play turns with AI factions active, confirm `lua.log` shows
> `register_hooks: 3 hook(s) registered` and zero `lua/cpp mod_social_ai
> mismatch` lines. Given how much branching `social_score` has (far more
> than `mod_tech_val`), treat a clean run here as less likely on the first
> try than M4's was — budget time to root-cause any mismatch before calling
> this done. `mod_wants_to_attack` (item 2b) remains untouched.

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

> **Status (2026-07-14): implemented and building clean on both presets;
> in-game dual-run verification done, zero mismatches.** `evaluate_attack` ported to
> `lua/ai/war.lua`, registered as `mod_wants_to_attack` (`lua/ai/init.lua`),
> same temporary dual-run mismatch pattern as `mod_tech_val`/
> `mod_social_ai` (`src/faction.cpp`'s `mod_wants_to_attack` seam, added
> around the existing call to `evaluate_attack` rather than threaded through
> every return point inside it, since -- unlike `mod_tech_val` -- the seam
> lives in the small wrapper function, not the sprawling one). `LuaHostApi`
> bumped to `api_version=5` with 4 new entries (`great_beelzebub`,
> `great_satan`, `has_agenda`, `hq_region`). `tools/gen_ffi.cpp` gained 9
> new `Faction` fields (`major_atrocities`, `player_flags`,
> `mil_strength_1`, `best_armor_value`, `region_force_rating`,
> `region_total_combat_units`, `tech_commerce_bonus`,
> `integrity_blemishes`, `SE_morale_pending`), 2 new `MFaction` fields
> (`rule_flags`, `rule_morale`), the `FactionRankings` global flagged back
> in 4.5 as "add for item 2b", and 9 new enums -- all re-derived directly
> from `evaluate_attack`'s body while implementing, matching the plan below
> exactly except for one addition the scoping pass had missed: `Faction::
> mil_strength_1` (used comparing `Factions[i].mil_strength_1` against
> `plr_tgt->mil_strength_1` in the first loop) wasn't listed below and had
> to be added during implementation -- same kind of under-specification
> already seen in 4.5's scoping pass, caught the same way (re-reading the
> C++ body directly instead of trusting the earlier field list). `game.lua`
> gained a `faction_ranking(i)` accessor for `FactionRankings` (an
> `int[MaxPlayerNum]` array, not a scalar, so it doesn't fit the existing
> bare-scalar-global accessors already there). Every new/changed Lua file
> passed a native-`luajit` `loadfile` syntax check.
>
> **In-game run (same session as the autoplay/social-AI testing, continued
> from turn 90):** `lua.log` showed `register_hooks: 4 hook(s) registered`
> and `mod_wants_to_attack` in the first-call diagnostic line. `debug.txt`:
> 123 `wants_to_attack` calls across turns 90-92, **zero**
> `lua/cpp mod_wants_to_attack mismatch` lines. Both outcomes exercised (46
> `value=0`, 77 `value=1` — not a degenerate run where only one branch of
> the boolean ever fires). **One path still unexercised:** `faction_id_unk`
> was `0` in all 123 calls, so the `faction_id_unk > 0` branches (the
> third-party-ally adjustments to `compare`/`factor_force_rating` via
> `Factions[faction_id_unk].region_force_rating[region]`) never ran —
> not a sign of a problem, just untested; would need a call site that
> passes a real third faction (diplomacy-triggered `evaluate_attack` calls)
> to cover.

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

> **Status (2026-07-14): implemented and building clean on both presets;
> in-game dual-run verification done, zero mismatches.** `unit_score` + `find_proto`
> ported to `lua/ai/build.lua`, `find_proto` registered as the hook
> (`lua/ai/init.lua`); same temporary dual-run pattern as the other three
> items, with RNG snapshot/restore around the Lua call since `find_proto`
> consumes it (`random(128)`, confirmed to be `random_get(0,128)` under a
> different name — same LCG state as `rand.map`, no new RNG binding
> needed). `LuaHostApi` bumped to `api_version=6` with 12 new entries.
> `tools/gen_ffi.cpp` gained `BASE`'s first-ever `emit_struct` block (11
> fields) plus fields on `UNIT`/`CChassis`/`CWeapon`/`CRules`/`Faction` and
> a page of enums — the scoping pass below undercounted by about a dozen
> items once the functions were actually transcribed line-by-line (several
> more found live, same "the plan is a hypothesis, the source is the
> truth" pattern as every prior item): `Faction::mil_strength_1`-style
> misses this time were `UNIT::unit_flags` (backs `is_prototyped()`,
> needed by `proto_extra_cost`), `Faction::SE_police_pending` +
> `SE_Pending` (backs `BASE::SE_police(pending)`), `CRules::
> artillery_max_rng`, `PLAN_NAVAL_SUPERIORITY`/`PLAN_RECON`/
> `FAC_STOCKPILE_ENERGY`/`TRIAD_*`/`PLAN_SUPPLY`/`PLAN_PROBE`/
> `PLAN_TERRAFORM`/`DIFF_SPECIALIST` enums, `MultiplayerActive` (new
> `game.lua` accessor), and the `MaxBaseNum`/`MaxProtoFactionNum` counts
> (declared for gen_ffi's own compilation but never actually emitted to
> Lua before now). Also caught and fixed two accidental duplicate enum
> emissions (`FAC_CENTAURI_PRESERVE`/`FAC_TEMPLE_OF_PLANET`, already
> emitted by the tech pilot) before they landed.
>
> **`UNIT::offense_value()`/`defense_value()` vs `proto_offense()`/
> `proto_defense()` — real distinct functions, not a naming accident.**
> Confirmed while implementing: the tech pilot's `proto_offense_value`/
> `proto_defense_value` (`lua/api/tech.lua`) are `UNIT::offense_value()`/
> `defense_value()` — the raw `Weapon`/`Armor` field, no reactor
> multiplier. `unit_score`'s own `proto_offense`/`proto_defense`
> (`veh.cpp:3166-3182`, now also in `tech.lua`) apply the reactor
> multiplier and a planet-buster special case. Both needed, kept
> separate, documented at both definition sites so it doesn't get
> collapsed into one "helper" by a future edit.
>
> **`defend`'s int-vs-boolean trap, caught before it shipped:**
> `lua_ai_hook` passes bool-shaped args as a raw `0`/`1` int (Lua's `0` is
> truthy, unlike C's), so `find_proto`/`unit_score` both normalize
> `defend` to a real Lua boolean on entry — same class of bug
> `lua/ai/social.lua`'s `pop_boom` already had to route around with
> explicit `~= 0` checks, just centralized here into one conversion
> instead of `~= 0` at every use site (this function uses `defend` in
> enough `and`/`or` ternary expressions that scattering the checks would
> have been easy to miss one of).
>
> `UNIT`'s new inline-method re-exposures (`proto_is_missile`,
> `proto_is_planet_buster`, `proto_is_psi_unit`, `proto_is_colony`,
> `proto_is_prototyped`, `proto_triad`, `proto_range`) and
> `proto_offense`/`proto_defense` landed in the existing `lua/api/tech.lua`
> rather than a new `unit.lua` — it already owns every `CChassis`/
> `CWeapon`/`UNIT` accessor they need, so a second module would just
> duplicate the same `ffi.cast` calls. New `lua/api/base.lua`: `BASE` is a
> mutable, re-pointable pointer (like `Vehs`, 3.2), so `get()` re-fetches
> it via a new `LuaHostApi.bases_ptr()` host call on every access instead
> of caching one `ffi.cast` the way `Factions`/`MFactions` (fixed
> addresses) are cached elsewhere.
>
> Every new/changed Lua file passed a native-`luajit` `loadfile` syntax
> check.
>
> **In-game run (continued autoplay session, turns 93-100):** `lua.log`
> showed `register_hooks: 5 hook(s) registered` and `find_proto` in the
> first-call diagnostic. `debug.txt`: **769** `find_proto` calls across all
> 7 AI factions, **zero** `lua/cpp find_proto mismatch` lines, zero Lua
> errors. Coverage was broad, not a lucky narrow path: `defend` both
> true/false (253/516), 6 distinct triad-flag combinations (land/sea/air
> and their bitwise unions), 5 distinct weapon modes. This is the deepest
> dependency chain ported so far (two new structs' worth of fields, a
> dozen-plus enums, 12 host wrappers) and it came back clean on the first
> real session — contrary to the "expect a mismatch" caution below, which
> stands as general guidance for the *next* item, not a prediction that
> held here.

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

## Phase 5 — validation

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

**Not yet done:** an actual unattended all-AI play session confirming turns
advance with no hang, start to finish.

**Correction (2026-07-14, found by testing):** the New Game screen has no
"0 human players" option — it always requires picking one faction to
control. That alone doesn't defeat autoplay's popup bypass, but
`thinker_enabled()` (`faction.cpp:142`) separately excludes whichever
faction is marked human (`!is_human(faction_id)`) from Thinker's entire AI
stack — `social_ai`, `tech_ai`, `design_units`, all of it, not just its
dialogs. So the chosen faction stayed under manual control with no AI
running for it at all; the dialog-bypass shims never touched this because
they don't look at `is_human`. Fix: `autoplay_demote_human()`
(`src/autoplay.cpp`), called every `mod_turn_upkeep` (`game.cpp:1012`, one
line). When `conf.autoplay` is on, it clears `*CurrentPlayerFaction`'s bit
in `FactionStatus[0]` (the same bitmask `is_human()` reads) — the faction
picked in the mandatory setup screen becomes Thinker-AI-controlled like any
other, starting turn 1. Idempotent (no-op once the bit is already clear);
logs which faction got demoted to `autoplay.log`. Both presets rebuilt and
relinked clean after this change.

**Round 2 (2026-07-14, first real play session, three findings):**

1. **Quit did nothing.** `autoplay.log` showed `X_pop_9 ... label=REALLYQUIT`
   every time Quit was clicked — the shim's blanket default of `0` answers
   "no" to this confirmation dialog. Fixed with a label-specific override in
   `autoplay_x_pop_9` (`src/autoplay.cpp`): `REALLYQUIT` now returns `1`.
   This is the "add a case" iteration the spike was designed around —
   expect more of these as new labels turn up.
2. **Monolith/tech popups still appeared.** Root cause is architectural, not
   a missing label: the six shimmed primitives only intercept calls made
   *through Thinker's own recompiled source* (game.cpp, veh_turn.cpp, ...)
   reading the `popp`/`X_pop_9`/etc. global variables. Code that still lives
   entirely inside the original, un-decompiled engine binary (most of
   `tech_achieved` at `0x5BB000`, for instance — Thinker only patches a
   couple of call sites *inside* it) calls the same popup functions via
   hardcoded addresses baked into its own machine code, never touching
   those global variables, so the shim never sees the call. Redirecting the
   variable is not the same as redirecting the function. Applied one
   targeted, low-risk mitigation using the game's own existing preference
   toggle: `autoplay_demote_human()` now also sets
   `*GameMorePreferences |= MPREF_AUTO_ALWAYS_INSPECT_MONOLITH`
   (`engine_enums.h`, an existing Preferences-screen checkbox that
   `mod_monolith`, `veh.cpp:1031/1041`, already checks before showing its
   popup). **Not fully solved** — a proper fix for popups originating
   entirely inside untouched engine code would need `write_call`-patching
   the specific call sites inside functions like `tech_achieved`, the same
   technique already used elsewhere in `patch.cpp`, which requires
   disassembly/RE work not done yet.
3. **End Turn still required every turn.** Unrelated to `is_human`/
   `thinker_enabled()` entirely: those only gate whether Thinker's *AI
   decision code* runs for a faction, not whether the game's own UI loop
   sits waiting for that faction's manual End Turn input — a separate,
   lower-level mechanism that demoting the human bit doesn't touch. Found a
   candidate: `Console_end_my_turn` (`engine.cpp:2135`, address `0x5169F0`,
   `__thiscall` on the `Console*` singleton `MapWin`) — named like the End
   Turn button/key handler, but **nothing in this codebase has ever called
   it before**, so its preconditions are unconfirmed. Wired as
   `autoplay_try_end_turn()` (`src/autoplay.cpp`), called from
   `mod_blink_timer` (`gui.cpp:519`, an existing periodic idle callback —
   `write_offset(0x50F3DC, mod_blink_timer)` in `patch.cpp` — that fires
   while the game sits idle waiting for input; `mod_turn_upkeep` doesn't
   work for this since it only runs once a turn has *already* ended).
   **Explicitly experimental and unverified — real crash risk**, flagged as
   such rather than treated as equally solid as (1) and (2); logs every
   attempt (no throttling yet) so a crash is diagnosable from
   `autoplay.log`'s last line. Needs an actual play session to know if it
   works, hangs, or crashes.

- State hash: end-of-turn Lua script iterating factions/bases/vehs writing one
  line per turn to a hash log; two runs with the same seed must produce
  identical files (`cmp`).
- Report divergence at the **first level** it appears (plan 5.3's five levels:
  per-call output → per-call delta → phase hash → turn hash → N-turn
  trajectory) to localize bugs instead of "turn 40 differs".

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
