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

### 4.8 Production/plans port, second slice: `select_colony`/`select_combat` — in-game verified clean

> **Status (2026-07-14): implemented and building clean on both presets;
> in-game dual-run verification done, zero mismatches.** Both ported to
> `lua/ai/build.lua`, registered as hooks. `LuaHostApi` bumped to
> `api_version=7` with 17 new entries (one more than scoped: `select_
> colony`'s `iterate_tiles` scan for a placeable ocean-colony land tile
> — `veh_owner()`/`is_owned()`/`owner` MAP-tile reads — wasn't caught by
> the scoping pass below; replicated as `ocean_colony_land_site(base_id,
> land)`, including its own conditional RNG consumption, rather than
> opening `MAP`/`iterate_tiles` to Lua for one loop). `check_probe`
> (`build.cpp`) had to lose its `static` to be reachable from
> `luaai.cpp`, same pattern as `revised_tech_cost` earlier. New `base.lua`
> accessor: `count()` (`*BaseCount`, needed by `select_combat`'s enemy-base
> scan, not exposed anywhere before now). A `b2n(bool)` local helper was
> added to `build.lua` — this pair has far more C boolean-to-int arithmetic
> (`bool + bool`, `bool * N`) than `unit_score`/`find_proto` did, and
> spelling each one out as `x and 1 or 0` inline was getting error-prone.
> Every new/changed Lua file passed a native-`luajit` `loadfile` syntax
> check.
>
> **Round 1 (first in-game run) found a real bug, fast:** `BASE.x`/`BASE.y`
> were never added to the FFI field list back in 4.7 — nothing had needed
> a base's coordinates until `select_combat`'s enemy-base scan
> (`funcs.map_range(base.x, base.y, b.x, b.y)`) and `select_colony`'s
> `has_base_sites(base.x, base.y, ...)` calls. First real exercise of
> `lua_strict=1`'s failure mode outside the Phase 2B smoke test: one
> hook's error disabled Lua AI for the *entire* session, not just that
> hook, which is why the first session's log was so short — switched the
> deployed `thinker.ini` to `lua_strict=0` (disables only the failing
> hook, falls back to C++ for it) for iterative testing going forward,
> per the same tradeoff already documented in 2.5/IMPLEMENTATION_PLAN.md
> 2B. Fixed by adding `x`/`y` to `BASE`'s `emit_struct` block
> (`tools/gen_ffi.cpp`) — no C++ recompile needed, `types.lua` is a
> build-time-generated file the compiled `thinker.dll` doesn't embed.
>
> **Round 2 (after the fix), in-game run (turns 101-105, continuing the
> same session):** `lua.log` showed `register_hooks: 7 hook(s)
> registered` and all three `build.lua` hooks (`select_colony`,
> `select_combat`, `find_proto`) in the first-call diagnostic. Zero Lua
> errors, zero `lua/cpp select_colony mismatch` / `lua/cpp select_combat
> mismatch` / `lua/cpp find_proto mismatch` lines. Neither `select_colony`
> nor `select_combat` calls `debug()` in the original C++, so unlike
> `find_proto`'s 769-call count, there's no per-call log to derive an
> exact volume from — only confirmed as invoked and clean, not
> heavily-exercised the way the first slice was. Both consume RNG
> conditionally in several places (short-circuit `||`/`&&` chains gating
> `random()` calls); the careful call-order preservation documented
> inline held up in this run, but the caution about it being easy to get
> subtly wrong stands for future sessions with more volume.

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

### 4.9 Production/plans port, third slice: `governor_priorities`/`facility_score` — implemented (not dual-run verifiable, by design)

> **Status (2026-07-14): implemented, building clean on both presets,
> syntax-checked.** Both fields/enums landed in `tools/gen_ffi.cpp`
> (`BASE.defend_goal`, 4 `GOV_PRIORITY_*`) exactly as scoped, no surprises
> this time. No `LuaHostApi` change (`api_version` stays at 7) — nothing
> here needed a host wrapper. No in-game run possible or meaningful: as
> explained below, neither function fits the hook contract, so there is no
> seam to exercise and no `lua.log`/`debug.txt` signal to check.

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

### 4.10 `select_build` itself (porting-order item 3, final piece) — step 1 implemented, in-game verification pending

> **Status (2026-07-14): step 1 of the 4-stage order in 4.10.9 (`VEH`
> exposure + the vehicle-count loop, as a standalone correctness check)
> implemented and building clean on both presets; in-game verification not
> yet run.** See 4.10.10 for the full session record, exactly what was
> touched, and what to check when resuming — read that first if you're
> picking this back up. Steps 2-4 (push_item + running-best tracker, the
> `build_order` scoring loop, wiring the real hook) are still
> unimplemented; the rest of this section (4.10.1-4.10.9) is the original
> scoping pass and remains accurate reference material for the parts not
> yet done.

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

### 4.10.10 Step 1 session record (2026-07-14) — implemented, in-game verification pending

Implements exactly step 1 of 4.10.9's plan: `VEH`'s first-ever FFI exposure
plus a standalone correctness check for `select_build`'s own vehicle-count
loop (`build.cpp:913-955`). **Not a hook** — `select_build` itself is still
pure C++, unhooked; this only adds a temporary, throwaway call that logs
counters for a human to diff against a debug line already in the original.
Steps 2-4 (push_item + running-best tracker, the `build_order` scoring
loop, wiring the real hook) are untouched.

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

**Validated so far (this session, no game launch):**

- Both presets (`ninja-develop`, `ninja-debug`) build clean — no new
  warnings, no errors.
- Every touched/new Lua file (`lua/api/veh.lua`, `lua/api/tech.lua`,
  `lua/ai/build.lua`, `lua/ai/init.lua`, `lua/ffi/funcs.lua`) passes
  `luajit -e "assert(loadfile('<file>'))"` (syntax only, same caveat as
  every prior slice — this catches syntax errors, not semantic ones,
  since it can't load the sandbox/ffi globals outside the game process).
- The generated `lua/ffi/types.lua` was inspected directly: `VEH`'s
  offsets are `x=0, y=2, unit_id=10, faction_id=14, order=17,
  home_base_id=46`, `sizeof=52, alignof=1` — hand cross-checked against
  `engine_veh.h:482-513`'s field declarations one by one and matches
  exactly (no gaps in reasoning here the way the `CChassis::preq_tech`
  int16_t/int32_t mixup from 3.1 could hide one). `VehCount`,
  `PLAN_ARTIFACT`, `BSC_FUNGAL_TOWER`, `ORDER_CONVOY`,
  `GOV_MAY_PROD_TERRAFORMERS` all present in the generated `globals`/
  `enums` tables with the expected values.
- Deployed to `~/.wine-smac/drive_c/Games/SMAC` (`tools/deploy.sh
  develop`).

**Not yet done — pick up here next session:**

1. **Launch the game and actually play some turns** (existing saves from
   prior sessions exist under `saves/`, faction "Lal of the Peacekeepers",
   or start fresh — `conf.autoplay=1` and `lua_strict=0` are already set
   in the deployed `thinker.ini`). No automation exists for this: driving
   the Wine GUI (New Game screen, or loading a save) needs manual clicks,
   same as every previous "in-game verified" entry in this file.
2. **Check `lua.log` for errors first** — no `error in 'vehicle_counts_check'`
   lines, and confirm `register_hooks: N hook(s) registered` includes the
   new one (N should be 8, one more than the prior session's 7).
3. **Diff the counters.** For a handful of `(turn, base_id)` pairs, find
   the matching `vehicle_counts base:N ...` line in `lua.log` and the
   `select_build ... base_id ...` line in `debug.txt`, and compare `def`,
   `frm`, `prb`, `crw`, `pods`, `scouts` field by field. A mismatch
   localizes the bug to the vehicle-count loop or the `VEH`
   predicates/fields before the harder `build_order` scoring loop (step 3)
   is even touched — exactly the point of doing this as its own step.
4. **If clean:** proceed to step 2 of 4.10.9's order (`push_item` + the
   running-best tracker + `has_retool`/`skip_facility`). If not: the
   mismatch is somewhere in `lua/api/veh.lua`, the new `tech.lua`
   predicates, or `vehicle_counts_check` itself — the loop is short enough
   that bisecting by commenting out branches should localize it quickly.
5. Once `select_build` is eventually fully ported and hooked, this
   temporary seam (the `lua_ai_hook("vehicle_counts_check", ...)` call in
   `build.cpp`, the registration in `lua/ai/init.lua`, and arguably
   `vehicle_counts_check` itself) should be removed — it was only ever a
   scaffolding check for this one step, not permanent AI logic, same fate
   as the other temporary dual-run instrumentation elsewhere in this file.

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
--no-xvfb`. Two real gaps found and fixed before any comparison data
could be trusted:

- **The harness silently discarded `lua_shadow=1`.** The "thinker.ini:
  force the settings this harness needs" block (`tools/autoplay_run.sh`)
  does `cp docs/thinker.ini "$INI_PATH"` — replacing whatever
  `thinker.ini` was deployed, including any manually-set `lua_shadow=1`,
  with the shipped template's default (`lua_shadow=0`) — then only
  force-sets `autoplay`/`lua_ai`/`lua_strict`/`minimal_popups`, never
  `lua_shadow`. `trap restore_ini EXIT` returns the original file only
  after the game process has already exited, too late to matter. A run
  launched this way never invokes the Lua side for comparison at all,
  regardless of what the deployed file said before the script ran — found
  live when asked to confirm a completed run's results. Fixed with a new
  `--lua-shadow` flag (same pattern as `--rng-seed`): forces
  `lua_shadow=1` via `sed` right after the existing forced-settings block.
- **No way to confirm which flags were actually in effect after the
  fact.** Zero `mismatch` lines in `lua.log` is the expected output both
  when shadow ran and matched perfectly, and when shadow was never active
  (nothing compared, nothing logged) — indistinguishable from the log
  alone. Shadow mode's own RNG-restore-after-every-call design (5.1.1)
  means `state_hashes.log`'s `rng=` field can't disambiguate the two
  cases either, by construction — shadow must not perturb determinism, so
  it leaves no trace there. Fixed with one `lua_logf` line at the end of
  `lua_ai_init` (`src/luaai.cpp`): `config: lua_ai=%d lua_shadow=%d
  lua_strict=%d autoplay=%d` — every future run's own `lua.log` now
  proves what was active without depending on memory of the launch
  command.

With both fixes in place, one full `--no-xvfb --lua-shadow` run (manually
started new game, all-AI after `autoplay_demote_human`, no fixed seed):
`register_hooks: 11 hook(s) registered`, `config: lua_ai=1 lua_shadow=1
lua_strict=0 autoplay=1`, `outcome: COMPLETED` at turn 71 (target 70),
**zero `lua/cpp ... mismatch` lines** in `lua.log` or `debug.txt` across
all 9 hooked decision functions (`mod_tech_val`, `mod_tech_ai`,
`mod_social_ai`, `mod_wants_to_attack`, `find_proto`, `select_colony`,
`select_combat`, `facility_score`, `governor_priorities`). First real
data point for gate item (d) — one save/map of the 3+ its acceptance
criterion requires (still need at least one more, plus one with
`rule_psi` factions present, before the item can close).

**Files touched:** `tools/autoplay_run.sh` (`--lua-shadow` flag, header
doc), `src/luaai.cpp` (startup `config:` echo line).

**Second run (2026-07-16), new game including a `rule_psi` faction.**
Same `--no-xvfb --lua-shadow` harness, different manually-started game
this time deliberately including a `rule_psi` faction (`src/config.cpp`'s
`BN_PSI` bonus, `MFactions[].rule_psi` — feeds `plan.cpp`'s psi-combat
scoring and `veh_combat.cpp`'s psi attack/defense bonus). Confirmed via
`config:`/`register_hooks:` lines as before; nonzero `psi:` fields in
`plans_upkeep`/`unit_score` debug lines throughout `debug.txt` are
consistent with an active `rule_psi` faction exercising that branch.
`outcome: COMPLETED` at turn 70, **zero `lua/cpp ... mismatch` lines**
again. **2 of the required 3+ saves/maps for gate item (d)**, and the
`rule_psi` requirement is now satisfied.

**Third run (2026-07-16), third distinct new game.** Same
`--no-xvfb --lua-shadow` harness, another manually-started game.
`register_hooks: 11 hook(s) registered`, `config: lua_ai=1 lua_shadow=1
lua_strict=0 autoplay=1`, `outcome: COMPLETED` at turn 70, **zero
`lua/cpp ... mismatch` lines** in `lua.log` or `debug.txt`. **3rd of the
required 3+ saves/maps — gate item (d)'s acceptance criterion is met:
zero `lua_shadow=1` divergences across 3 distinct saves/maps, including
one with a `rule_psi` faction.** See `IMPLEMENTATION_PLAN.md`'s
Consolidation gate for the formal close-out.

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
  identical files (`cmp`). **Implemented, see 5.3.2.**
- Report divergence at the **first level** it appears (plan 5.3's five levels:
  per-call output → per-call delta → phase hash → turn hash → N-turn
  trajectory) to localize bugs instead of "turn 40 differs".

### 5.3.2 Autoplay harness script + per-turn state hash (2026-07-15) —
implemented, mechanics smoke-tested end to end, turn-advancing run not yet
done

> **Consolidation gate (IMPLEMENTATION_PLAN.md) item (a), first half.**
> Builds the tooling item (a) needs: `tools/autoplay_run.sh` (deploy,
> launch under Xvfb, watchdog, classify, collect, restore) and its
> dependency, the per-turn state-hash dump from Lua
> (`lua/harness/state_hash.lua`). **Not done in this pass:** the actual
> `autoplay_demote_human` retest / "one real unattended all-AI run" item
> (a) also asks for — that needs a game actually in progress, which this
> script cannot reach on its own (see the KNOWN GAP below), so it's left
> for the manual follow-up the session that requested this work already
> flagged as separate.

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

**Smoke-tested this session — STALL path only, exit code 2 as designed
(`COMPLETED`→0, `STALL`→2, `CRASH`→3):** `tools/autoplay_run.sh --preset
debug --timeout 25 --poll 3 --turns 999999`. No New Game was started (see
KNOWN GAP below), so no `state_hash` line was ever going to appear — this
run exercises exactly the deploy → launch → display-discovery → watchdog →
STALL-classify → screenshot → kill → collect → restore pipeline, not the
Lua state-hash code itself (that needs an actual in-progress game, i.e.
the still-open manual step). Confirmed clean: deploy copied the new
`lua/harness/` directory alongside the existing `lua/ai`/`lua/api`/
`lua/ffi`; Xvfb allocated `:99`, discovered correctly; the watchdog
correctly saw no `state_hash` lines and declared `STALL` at the 25s mark;
`stall.png` came out a valid 640x480 PNG via the `import` fallback;
`ps aux | grep wine` showed **zero** leftover processes after the kill
(no orphaned `wineserver`/`Xvfb`); `thinker.ini` was restored to its
exact pre-run content (diffed byte-for-byte against a pre-run copy,
confirmed **not** silently left as the harness's forced-`autoplay=1`
version — the fact that the restored file also happened to have
`autoplay=1`/`lua_strict=0` is coincidental, carried over from the *prior
manual session's* hand-edited `thinker.ini`, not evidence the restore was
a no-op). `runs/<UTC timestamp>-debug/` contained `outcome.txt`,
`stall.png`, `saves/` (copied even though empty/irrelevant here — no game
was started) and `xvfb-run.out`; deleted after inspection (test artifact,
not meant to be kept in the repo — `runs/` is gitignored, see below).

**KNOWN GAP, stated plainly rather than glossed over: this script cannot
reach an in-progress game on its own.** Checked `src/main.cpp`'s argv
parsing (`CommandLineToArgvW`) before assuming otherwise: only
`-smac`/`-native`/`-screen`/`-windowed` are handled — there is no
command-line flag to auto-load a save or skip the main/New Game menu, and
Xvfb is headless (no human can click into it without attaching a VNC
viewer or similar to the allocated display). The six-primitive dialog-
bypass shims (5.3.1) only intercept *in-game* modal popups, not the main
menu itself, which isn't one of the six. So today, a harness run against
a fresh Xvfb session will sit at the main menu until the timeout fires a
`STALL` — exactly what the smoke test above demonstrated. Getting to an
actual "one real unattended all-AI run" therefore still needs one
interactive session first (attach a VNC viewer to the Xvfb display this
script prints, or run the same launch command on a real display once) to
get through the New Game screen and reach a state where turns are already
advancing — this script only automates *after* that point. `--save FILE`
is accepted and forwarded as an extra `wine` argument on the chance the
engine honors a bare save path on its command line, but this is
**unverified** — not tested this session, don't assume it works without
checking. Auto-loading a save on every harness run remains unimplemented;
flagged here rather than left for the next session to discover the hard
way.

**Files touched:** `tools/gen_ffi.cpp` (`Faction.energy_credits`/
`tech_ranking`), `lua/harness/state_hash.lua` (new), `lua/ai/init.lua`
(one new registry entry), `src/game.cpp` (`mod_turn_upkeep` seam),
`tools/autoplay_run.sh` (new), `.gitignore` (`runs/`). Both build presets
(`ninja-develop`, `ninja-debug`) compile clean; `lua/harness/state_hash.lua`
and `lua/ai/init.lua` pass a native-`luajit` `loadfile` syntax check;
`lua/ffi/types.lua` inspected directly for the two new `Faction` offsets.

**Not yet done — pick up here:** the actual unattended all-AI run itself
(needs the manual New-Game-screen step above first, then re-run
`tools/autoplay_run.sh` against the resulting in-progress save/session);
confirm the `COMPLETED` and `CRASH` classification paths for real (only
`STALL` was exercised); confirm `state_hash` lines actually appear in
`lua.log` and that `cmp`-ing `state_hashes.log` across two same-seed runs
produces identical files, which is the entire point of this mechanism and
hasn't been checked against a real game yet.

**Addendum (2026-07-15): two real bugs found while answering "how do I use
this", one fixed, one still open.**

1. **Fixed — wrong `cwd` broke every Xvfb launch, silently.** `thinker.exe`
   (`src/launch.cpp`) checks for `"terranx.exe"` as a path **relative to
   its own process's cwd**, not relative to the `.exe`'s own location —
   real Windows only gets this right because Explorer sets a launched
   process's cwd to its folder, a courtesy `wine /abs/path/thinker.exe`
   from an unrelated shell cwd does not provide. The first version of this
   script launched wine without ever `cd`-ing into `$GAME_DIR`, so it hit
   `FileExists(GameExeFile) == false` and got a plain Win32 `MessageBox`
   ("Cannot find terranx.exe. Game is unable to start.") — confirmed by
   screenshot. That dialog is **not** one of the six autoplay-bypassed
   primitives (`src/autoplay.cpp`), so it blocks forever even with
   `autoplay=1`. This means the smoke test recorded above (STALL at 25s,
   "last turn seen: none") was almost certainly hitting this dialog the
   whole time, not sitting at the New Game menu as assumed when it was
   written. Fixed: the launch now runs as `(cd "$GAME_DIR" && exec setsid
   ...)` in both the Xvfb and `--no-xvfb` branches — `exec` inside the
   subshell means `$!` after backgrounding still names the real process
   directly, so the kill/process-group logic needed no other changes.
2. **Still open — Xvfb itself appears unable to run the game at all on
   this dev machine**, a second, more fundamental problem than gap #1.
   Even with the `cwd` fix, under Xvfb the process reliably exits ~1-2s
   after the `patch_setup screen: ... window: ...` / `random_reseed ...`
   lines land in `debug.txt` — **before `mod_turn_upkeep` / Lua init ever
   runs** (no `lua.log` is created at all). `WINEDEBUG=+ddraw,+d3d,+seh`
   showed no explicit fatal error, just a burst of `RtlUnwindEx` activity
   around `wined3d_dll_init Application name terranx.exe\Direct3D` right
   before the process disappears — consistent with the DirectDraw/PRACX
   (`ddraw.dll`) surface-creation path failing outright in this headless
   setup, not yet root-caused past that. `LIBGL_ALWAYS_SOFTWARE=1` (the
   usual fix for "no GPU under Xvfb") made no difference — same failure
   point, same timing. Xvfb's own startup warnings (`radv is not a
   conformant Vulkan implementation`, `DRI3 error: Could not get DRI3
   device`) are visible in every run but weren't confirmed as *the* cause,
   only as circumstantial. **Practical consequence: `--no-xvfb` is
   currently the only launch mode confirmed to reach the game's window at
   all on this machine** — the default (Xvfb) mode fails before KNOWN GAP
   #1 (the New-Game-menu problem) even becomes relevant. Documented as
   KNOWN GAP #2 directly in `tools/autoplay_run.sh`'s header. Whoever
   picks this up next: try alternate Xvfb screen depths/extensions, or a
   PRACX-disabling launch path if one exists, before assuming it's
   unfixable — this was time-boxed, not exhaustively diagnosed.
   >
   > **Update (2026-07-15, later the same day): the three follow-ups
   > above were tried, none fixed it — see 5.3.5.** Higher screen
   > depth/resolution, the GDI renderer, and `WINEDLLOVERRIDES=ddraw=b`
   > (each alone and combined) all still die at the identical point. A
   > plain `wine notepad` survives fine under the same Xvfb, ruling out
   > Xvfb-vs-wine breakage in general. The DirectDraw/PRACX hypothesis
   > this section proposed is now considered **ruled out**, not just
   > unconfirmed — whoever picks this up next should look elsewhere
   > entirely, not retry graphics-related variations. Demoted to
   > nice-to-have in the consolidation gate (`IMPLEMENTATION_PLAN.md`,
   > item (a)'s status) — `--no-xvfb` already satisfies every run this
   > harness needs; headless only matters once parallelizing runs becomes
   > the actual goal.

### 5.3.3 Real validation runs (2026-07-15) — 4/4 runs clean, 3 real bugs found (2 fixed, 1 open), the six-primitive catalog corrected

> **Consolidation gate item (a), completed except the determinism re-run.**
> Four `--no-xvfb` sessions run end-to-end on the real desktop (manual
> gameplay by the user, this tool watching logs and, twice, killing/
> collecting/fixing between rounds): 3 distinct new games + a 4th with a
> recorded fixed seed. All four finished clean — `state_hash` lines
> sequential with no gaps, zero `error in` lines in `lua.log`, no leftover
> `wine`/`terranx.exe` processes after cleanup.

| Round | Demoted faction | Turns | Outcome | Notes |
|---|---|---|---|---|
| 1 | PEACE | 80 | manual stop | pre-dates the cwd fix (5.3.2) and the game_alive fix below; killed and collected by hand |
| 2 | USURPER | 100 | `COMPLETED` | first run of the actual script; revealed the End Turn problem below |
| 3 | (unrecorded) | 80 | `COMPLETED` | first run after the blink-timer fix; confirmed End Turn now auto-advances; revealed the tech/secret-project/probe gaps below |
| 4 | (unrecorded) | 80 | `COMPLETED` | fixed seed **15373264** (`random_reseed 15373264`, logged at game start) — needs to be **run a second time with this same seed** and `cmp`'d against this round's `state_hashes.log` to actually complete the determinism check (plan 5.3); not yet done |

**Bug found and fixed: `game_alive()` — the watchdog was checking the wrong
PID.** `thinker.exe` (`src/launch.cpp`) is a launcher stub: it
`CreateProcess`-suspends `terranx.exe`, injects the DLL, resumes it, and
**exits itself by design** once that hand-off succeeds — this is not a
crash. `tools/autoplay_run.sh`'s watchdog originally only checked
`kill -0 $RUN_PID` (the launcher's pid), so it declared `CRASH` within one
poll interval of *every* successful launch, and its cleanup step then
skipped killing anything (since it believed the process was already
gone), leaving `terranx.exe` running fully detached from the script.
Caught live: round 2's window kept accepting input for several minutes
after the script had already printed `CRASH` and exited. Fixed with a
`game_alive()` helper that also checks `pgrep -x terranx.exe`, used
everywhere the watchdog previously checked `$RUN_PID` directly, including
the final cleanup (which now also `pkill`s `terranx.exe` by name and
`wineserver -k`s the prefix, not just process-group-kills `$RUN_PID`).
Round 2's `COMPLETED` result (100/100 turns, the table above) is from
*after* this fix — confirmed working, not just theorized.

**Bug found and fixed: `autoplay_try_end_turn` was never once invoked.**
The user reported having to press End Turn manually every single turn
even with `autoplay=1` and 80-100 turns completing "cleanly" (rounds 1-2).
Root cause, confirmed by reading `src/patch.cpp:1154`: the
`write_offset(0x50F3DC, (void*)mod_blink_timer)` call that installs the
periodic UI-timer callback `autoplay_try_end_turn()` is called from
(`src/gui.cpp:521`) lives inside `if (cf->smooth_scrolling) { ... }` — an
unrelated visual feature, off by default
(`docs/thinker.ini`: `smooth_scrolling=0`). Since the callback was never
installed, `autoplay_try_end_turn()` was never called at all — not
"failing silently", literally never invoked (confirmed: zero `attempting
Console_end_my_turn` lines in round 2's `autoplay.log`, out of the whole
100-turn session). This had been sitting in the code since 5.3.1 marked
"EXPERIMENTAL... needs an actual play session to know if it works, hangs,
or crashes" — the real answer was "never gets the chance to do any of
those." Fixed (`src/patch.cpp`): an `else if (cf->autoplay)` branch
installs the same `mod_blink_timer` when `smooth_scrolling` is off but
`autoplay` is on — safe, since `mod_blink_timer`'s own body only touches
generic UI state (tutorial arrow, plan window blink) unrelated to the
`mod_gen_map`/`mod_calc_dim` patches that stay smooth_scrolling-gated.
**Confirmed fixed live in round 3**: turns advanced without manual End
Turn presses for the whole 80-turn session.

**Six-primitive catalog (5.3.1) was incomplete — corrected, catalog is
now nine.** Round 3 (after the End Turn fix) surfaced two more
interaction points the user had to click through: new-tech-discovered
announcements, and secret-project completion (two clicks: the completion
notice, then closing the project's datalinks entry). Investigating the
second one found that `engine.h` declares a much larger family than the
six originally catalogued: `X_pop` through `X_pop_9` (9 distinct raw
functions, not variants of one), `X_pops` through `X_pops_18` (18 more),
and `X_pop_ask`/`X_pop_ask_number` families (10 more) — roughly 33 raw
engine popup primitives total, of which the original spike only found and
shimmed two (`X_pop_9`, `X_pops_18`), because its grep searched for
Thinker's own convenience-wrapper names (`X_pop2`/`X_pop3`/`X_pop7`/
`X_pops3`/`X_pops4`/`X_dialog`, which do funnel into those two) and missed
every call site that uses a *bare* numbered primitive directly. Checked
which of the ~33 actually have call sites in Thinker's own recompiled
source (the only ones a pointer redirect can reach — the tech-discovery
gap below is the counter-example, code baked into the *original*
un-decompiled binary, which a pointer redirect cannot touch regardless):
only **`X_pop`** (8 sites — end-of-game/scenario dialogs, `game.cpp`),
**`X_pop_2`** (6 sites, same area), and **`X_pops`** (5 sites — probe-team
post-action "excuse" dialogs, `probe.cpp`, confirmed as the round-4 probe
click culprit) are actually used; the rest have zero call sites and were
left alone. Fixed: three new shims (`autoplay_x_pop`/`_x_pop_2`/`_x_pops`,
`src/autoplay.cpp`/`.h`), wired via the same `_engine`-suffix pointer-swap
pattern as the original six (`src/engine.cpp`/`.h`). Rebuilt clean on both
presets; **not yet re-verified live** (built and deployed after round 4
finished — the next round will be the first to exercise this).

**Still open: tech-discovery announcement.** `tech_achieved`
(`src/engine.cpp:1115`, address `0x5BB000`) lives entirely inside the
original, un-decompiled engine binary — same category of problem as
5.3.1's "monolith popup" gap, and confirmed **not** fixable by any pointer
redirect (its announcement popup is called by hardcoded address from
inside that binary, never touching a redirectable global). Thinker
already patches *one* call site inside it
(`write_call(0x5BBEB0, (int)tech_achieved_pop3)` — the SOCIETY
social-engineering picker, which does correctly route through
`X_pop3`→`X_pop_9` and get bypassed) but not the tech-announcement popup
itself. A real fix needs disassembly work to find that specific call
site's address, the same unfinished business 5.3.1 already flagged for
the monolith case. Left for the user to keep clicking through for now —
lower frequency than End Turn was, so not a blocker for continued
validation.

**Partial mitigation: secret-project completion, 2 clicks → 1.**
`minimal_popups` is a pre-existing, undocumented debug-only option
(`src/main.h`: "unlisted option"; `DEBUG`-gated in `src/main.cpp`) that
`remove_call`s the `BEGINPROJECT`/`CHANGEPROJECT`/`DONEPROJECT` call sites
inside the un-decompiled engine binary entirely (`src/patch.cpp:1195`) —
a second, redundant call site for the same announcements, distinct from
the one already routed through the shimmed primitives (confirmed
`BEGINPROJECT` still appears 19 times in round 4's `autoplay.log` even
with `minimal_popups=1` — that's the *other*, already-covered call site
still firing normally). Added to `tools/autoplay_run.sh`'s forced
settings (appended, since it isn't in `docs/thinker.ini`'s template, so
`sed` can't replace an existing line). User-confirmed in round 4: secret
project completion dropped from two clicks to one — **`minimal_popups`
removed the datalinks-entry screen specifically; the completion notice
itself is the click that remains**, not yet root-caused (plausibly the
same un-decompiled-binary class of problem as tech-discovery, not
confirmed).

**Files touched this session's validation rounds:** `tools/
autoplay_run.sh` (`game_alive()`, `--no-xvfb` real-display support,
`--screenshot-interval`, `minimal_popups=1`), `src/patch.cpp`
(blink-timer `else if (cf->autoplay)` branch), `src/autoplay.cpp`/`.h`
(three new shims), `src/engine.cpp`/`.h` (three new `_engine`-suffix
pointer pairs). Both presets rebuild clean throughout (confirmed after
every change, not just at the end).

**Not yet done:** repeat round 4 with seed 15373264 to actually complete
the determinism check (`cmp` two `state_hashes.log` files — the whole
point of the fixed-seed run, not done yet, only run once so far); confirm
the three new `X_pop`/`X_pop_2`/`X_pops` shims live (built and deployed,
not yet exercised in an actual session); the tech-discovery gap and the
secret-project completion-notice click remain open.

### 5.3.4 Determinism testing across process launches — `fixed_rng_seed` (2026-07-15)

Attempting the actual determinism check (`round 4`'s seed, re-run against
the same save loaded twice) surfaced a real architectural fact: **the
mod's own RNG stream is not tied to the save file at all.**
`src/main.cpp`'s `DLL_PROCESS_ATTACH` seeds both `random_reseed()`
(`random.cpp`'s LCG, the stream `random()`/`rand.map()` draw from
throughout the Lua AI) and `map_rand` from `GetTickCount()` — the system
uptime in milliseconds — **every time the DLL loads**, independent of
whether a save is loaded afterward and independent of that save's own
state. Confirmed by two loads of the identical save: the very first
`state_hash` line (turn 1, logged before any of that turn's processing)
was byte-identical both times, proving the save itself loads to identical
state — but turn 2 already diverged (`vehs=29` vs `vehs=30`, different
hash). Root cause is broader than "the human's manually-replayed turn 1
wasn't pixel-perfect" (the working theory at the time): **every other
AI-controlled faction is already making `random()`-dependent decisions
during that same turn 1**, before the demoted faction is even in the
picture, so their draws already diverge between runs regardless of what
the human did. Checked for a built-in "preserve random seed" toggle in
the game's own menus first (the user's own hypothesis) — confirmed by
the user directly in the New Game/Preferences screens: no such option
exists, consistent with there being no code path anywhere in `src/*.cpp`
that overrides the `GetTickCount()` seed.

**Fixed:** new `fixed_rng_seed` config option (`src/main.h`/`.cpp`, same
3-place pattern as every other option), default `0` (unchanged behavior
— `GetTickCount()` as always). When nonzero, used as the seed instead,
so `random_reseed`/`map_rand` produce the identical stream on every
process launch that sets it. Wired into the harness as `--rng-seed N`
(`tools/autoplay_run.sh`, appended to the forced `thinker.ini` like
`minimal_popups`, only when passed — normal runs are unaffected and keep
varying naturally). Both presets rebuild clean.

**Abandoned approach, kept here so it isn't retried blind: pausing the
process with `SIGSTOP` to give the user time to save mid-session doesn't
work.** The idea was to freeze `terranx.exe` the instant `turn=2`'s
`state_hash` line appeared (captured via a tight log-polling loop, no
code changes needed) so the user could open the Save menu without the
auto-End-Turn racing ahead. `SIGSTOP` is a hard OS-level freeze of the
*entire* process, including its message loop — the user couldn't
interact with anything at all (not even dismiss the event popup that
happened to be open at the moment of the freeze), confirmed live. Had to
`SIGKILL` and restart. `fixed_rng_seed` sidesteps the whole problem: with
the RNG pinned, replaying the same save + the same manual turn-1 actions
should reproduce exactly, no mid-session pause needed — this held for
the save itself (see below), not (yet) for the full turn.

**Exercised live, `fixed_rng_seed` confirmed working, but full determinism
still not achieved — a second, deeper source of divergence found.**
Test setup: one save (`saves/"Deirdre of the Gaians, 2101.SAV"`, kept at
`runs/determinism-save/` in the repo — turn 1, saved manually by the user
with autosave disabled, since the earlier autosave-based plan turned out
to be unreliable past the first couple of turns, not investigated
further), loaded twice with `--rng-seed 15373264` both times (runs
labelled A/B below predate this fix and used no seed pinning; C/D are the
post-fix pair). Two independent findings, both confirmed from
`debug.txt`/`state_hashes.log`, not inferred:

1. **The save itself loads deterministically, and `fixed_rng_seed` works
   exactly as designed.** All four runs (A, B, C, D) show `state_hash
   turn=1` byte-identical (`bases=7 vehs=29 hash=af557615`) — the loaded
   state is always the same, as expected. `debug.txt`'s `random_reseed`
   line read **15373264 in both C and D**, confirming the seed pin took
   effect identically across two separate process launches (A/B, with no
   pinning, would have shown different values here — not checked, moot
   once the mechanism was fixed).
2. **Turn 2 still diverges even with the seed pinned and the user
   deliberately reproducing identical turn-1 actions** (confirmed
   carefully by the user: same three actions in the same order, using a
   nutrient-bonus tile specifically *because* its uniqueness makes
   reproduction verifiable). In both C and D, Thinker's autoplay moved
   the scout patrol to investigate the same Unity Pod — but the pod's
   *contents* differed between the two runs. Traced one real mechanism
   that explains this class of bug: `veh.cpp`'s pod-opening code
   (`goody_pod_pop`-style, ~line 1157) only reseeds a
   position-independent local stream
   (`game_srand(*MapRandomSeed + f->goody_opened * 37)`) **when
   `*MultiplayerActive`** — in single-player (every session this project
   has ever run), pod contents instead draw from the **main sequential**
   `random()`/`game_rand()` stream, meaning their outcome depends on
   *everything* drawn before them that turn — including the other six
   AI-controlled factions' own turn-1 decisions, made automatically,
   outside the user's control. If any of those factions' processing
   consumes a different *number* of random draws between C and D — for
   any reason, timing-independent or not — the pod's position in the
   stream shifts and it rolls differently, independent of the human's
   actions or the seed being pinned. **Not root-caused further**: the
   next step would be auditing the vanilla/Thinker AI code the other six
   factions run during turn 1 for anything that could make its own
   random-draw *count* non-deterministic given identical inputs — a
   classic candidate is iteration over an unordered container keyed by
   something address-dependent (pointer identity, `unordered_map`/
   `unordered_set` bucket order under ASLR), but this is a hypothesis,
   not a confirmed finding, and needs real investigation before acting on
   it.

**Where this leaves Phase 5.3's determinism goal:** the state-hash
mechanism and the seed-pinning fix both work correctly and are validated
— the *tooling* is sound. Full bit-exact reproducibility across separate
process launches is not yet achieved. **Correction (external review,
2026-07-15, same day): this is not the "bit-exact only where achievable"
case the paragraph above originally invoked** — that framing covers
Lua-vs-C++ tolerance (comparing two different implementations), not a
single binary diverging from itself across two launches of the identical
save with the identical pinned seed. That's ambient nondeterminism, and
it directly blocks the consolidation gate's item (d) (`IMPLEMENTATION_
PLAN.md`), whose whole method is a systemic state-hash comparison — see
5.3.5 for the diagnostics landed to root-cause it (not yet run). Artifacts
for a fresh look: `runs/determinism-save/` (the save file,
`run-A`/`run-B`/`run-C-seed`/`run-D-seed` state-hash logs).

### 5.3.5 RNG divergence diagnostics + Xvfb re-attempt (2026-07-15, external review follow-up)

> Second-opinion review (via a separate model, prompted with this
> session's findings) re-ranked the three open gaps from 5.3.3/5.3.4: the
> turn-2+ RNG divergence is **blocking** (it invalidates gate item (d)'s
> whole comparison method, not just "nice to have bit-exactness"), Xvfb
> is **not** blocking (item (a)'s validation matrix is already satisfied
> by `--no-xvfb` on the real desktop). This section covers instrumentation
> only — the actual root-cause run (loading the same save twice with the
> new diagnostics active, diffing the logs) is manual follow-up, not done
> this session.

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

**Xvfb re-attempt (Task 3 of the external review, run autonomously — no
gameplay needed, success criterion was just "process survives past
`patch_setup` and creates `lua.log`"):** all three suspects from 5.3.2's
"whoever picks this up next" note, tried individually then combined:

- Higher screen depth/resolution (`xvfb-run --server-args="-screen 0
  1024x768x24"`, up from whatever `-a`'s default was — confirmed via
  `patch_setup screen: 1024x768 window: 1024x768` in `debug.txt`, so the
  args did take effect): no change, same failure point.
- GDI renderer (`wine reg add "HKCU\Software\Wine\Direct3D" /v renderer
  /d gdi /f`, reverted after testing): no change.
- `WINEDLLOVERRIDES="ddraw=b"` to rule out PRACX's `ddraw.dll`
  (confirmed active via `err:winediag:wined3d_dll_init Disabling 3D
  support` in the wine log): no change.
- All three combined: no change. Every variant dies at the exact same
  point (`patch_setup`/`random_reseed` logged, then gone within ~1-2s),
  regardless of graphics configuration.
- Sanity check: `wine notepad` under the identical Xvfb instance survives
  and stays interactive-ready — rules out Xvfb-vs-wine breakage in
  general, confirms the failure is specific to this game/DLL.

**Conclusion: the DirectDraw/PRACX hypothesis (5.3.2) is ruled out, not
just unconfirmed.** Whatever kills the process under Xvfb, it isn't
graphics configuration — three independent graphics-related fixes and
their combination made zero difference to either the failure point or the
timing. No replacement hypothesis tested yet. Given `--no-xvfb` already
covers every run the harness's validation matrix needs, and headless
operation only matters for future parallelization (not a current
blocker), this is demoted to nice-to-have rather than chased further —
`IMPLEMENTATION_PLAN.md`'s consolidation gate item (a) status and
`tools/autoplay_run.sh`'s KNOWN GAP #2 both updated to say so.

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

The diagnostics from 5.3.5, run for real (`load_daemon rng:` line, same
save, same `--rng-seed 15373264`, twice): `mod_rng`/`map_rng` matched
across launches as already known, but **`game_rand` (the engine's own
RNG) did not** — `20942280` vs `21141192` at the exact same point (right
after `load_daemon()` returns), conclusively answering 5.3.4/5.3.5's open
question. `fixed_rng_seed` (5.3.4) only ever pinned the mod's own
streams; the engine's `game_rand` was never touched by it and drifts
freely from process start.

**Fixed:** `mod_load_daemon` (`src/game.cpp`) now calls the existing
`game_rand_restore(conf.fixed_rng_seed)` (`random.cpp`, built for Phase 5
shadow mode, unused until now) immediately after `load_daemon()` returns,
gated on `fixed_rng_seed != 0` — same trigger as the mod-RNG pinning,
default behavior unchanged. Deliberately placed *after* load, not just at
`DLL_PROCESS_ATTACH` (where the mod-RNG pinning already lives): an
uncontrolled number of `game_rand` draws happen between process start and
reaching the load screen (menu navigation, etc.), so pinning only at
startup would still leave the at-load state path-dependent on how the
human got there. Restoring post-load discards all of that by
construction.

**Acceptance run:** same save, same `--rng-seed 15373264`, run twice.
`load_daemon rng:` now reads `game_rand=15373264 mod_rng=15373264
map_rng=15363119` identically in both — the restore works exactly as
designed. Result: **turns 1 and 2 now match completely** (state hash *and*
all three RNG-state fields byte-identical — an improvement over 5.3.4/
5.3.5, where turn 2 already diverged before this fix). `cmp` on the full
`state_hashes.log` pair: **still differs, first at turn 3** (`runs/
determinism-save/run-E-postfix-state_hashes.log` /
`run-F-postfix-state_hashes.log`). Per the plan for this session: **not
chased further** — localized and recorded below, per requirement 3, then
stopped.

**Localization (not root-caused — this is as far as this session goes):**
diffing the two `debug.txt`s directly finds the first difference during
**turn 3, faction 1's processing** (`enemy_turn 3 1`) — one run shows an
extra sequence (`veh_init`, `enemy_move ... Unity Rover`, `set_move_to`)
that the other doesn't; from that point on, unit counts and everything
downstream diverge completely, matching the `vehs=` mismatch already
visible in `state_hashes.log` at turn 3. The per-faction draw counters
logged immediately before this point (`game_rand_draws=416
mod_rng_draws=185` at the `enemy_turn 3 1` line) are **still identical**
in both runs — so whatever causes the extra Unity Rover event isn't (yet
visibly) a prior draw-count difference; either the same draw produces a
different outcome at this exact call (unexpected, would need direct
inspection to explain), or something non-RNG-related decides differently
whether this event fires at all before any relevant `random()`/
`game_randv()` call is even reached. Same general shape as 5.3.4's
original finding (single-player pod-related content/outcomes are order-
and history-dependent) but now narrowed to a specific turn, faction, and
event type instead of "somewhere in turn 2's processing."

**Net effect at the time:** real, measurable progress (divergence pushed
one full turn later, one genuine bug fixed using existing infrastructure)
but item (d) as then stated stayed blocked — the acceptance criterion
(byte-identical `state_hashes.log` for the full run) was not met. Not a
regression from 5.3.4/5.3.5's status, a narrowing of it.

**Files touched:** `src/game.cpp` (`mod_load_daemon`, one
`game_rand_restore` call). Both presets rebuild clean.

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
