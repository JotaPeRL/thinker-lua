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
  faction and calls save + exit at turn N.
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
