# Implementation Details — tactical notes per phase

Companion to `IMPLEMENTATION_PLAN.md`. The plan says *what* and *why*; this file
pins down *where* and *how*, with facts verified against the codebase (line
numbers as of commit `15418b2`; re-verify after upstream merges). It also
records two corrections to assumptions in the plan (see 3.1 and 3.4).

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
git -C third_party/luajit checkout v2.1   # rolling branch, pin the commit

# host tools (minilua/buildvm) must match target pointer size => 32-bit host cc
sudo pacman -S --needed multilib-devel lib32-glibc
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

### 2.3 Init point and new files

- Init in `src/main.cpp` `DllMain`, `DLL_PROCESS_ATTACH` branch, **after**
  `patch_setup(&conf)` succeeds and config is final (after line ~470, next to
  `random_reseed`). Shutdown in the `DLL_PROCESS_DETACH` branch.
- New files: `src/luaai.h` / `src/luaai.cpp` owning the single `lua_State*`:
  - `bool lua_ai_init()` — create state, `luaL_openlibs`, run `lua/init.lua`
    from the game's working directory (the game always runs with cwd = game
    folder; use a relative path).
  - `void lua_ai_shutdown()`, `bool lua_ai_reload()` (close + init; drop all
    cached hook refs).
  - Hook callers (Phase 4): `lua_ai_hook_i(name, &out, args...)` variants.
- The CMake source glob (`src/*.cpp`) picks new files up automatically.

### 2.4 Config options

Three places per option (follow any existing option as template, e.g.
`social_ai`):

1. Field in `struct Config`, `src/main.h` (~line 200+, defaults inline).
2. Parse branch in `option_handler`, `src/main.cpp` (`MATCH("lua_ai")` etc.).
3. Documented default in `docs/thinker.ini` (deploy only copies it when absent).

Options: `lua_ai=1`, `lua_shadow=0`, `lua_strict=0` (see plan 2.3).

### 2.5 Hot reload key

Keyboard handling lives in `src/gui.cpp` inside the window procedure, as a chain
of `else if (msg == WM_CHAR && wParam == '<key>' && alt_key_down())` starting
around line 695 (Alt+T) with debug-only entries guarded by `debug_cmd` from
line ~721. Add Alt+U (unused) calling `lua_ai_reload()`; make it available in
all builds — script authors are the target audience, not just mod developers.

### 2.6 Logging reality check

`debug()` / `debug_ver()` (`src/main.h:35-48`) compile to **nothing** outside
`BUILD_DEBUG`, and `debug_log` is only opened under `DEBUG` (`src/main.cpp:450`).
Decide explicitly: Lua's `log.*` should write to its own `lua.log` (always
available, since script users won't run debug builds), and *additionally* mirror
to `debug.txt` when `debug_log` exists. Keep an `fflush` policy like
`flushlog()`.

---

## Phase 3 — binding layer

### 3.1 Correction: engine structs are C++, not C

`engine_veh.h`, `engine_base.h` etc. define structs with **inline C++ methods**
(e.g. `VEH::triad()` at `engine_veh.h:401` and dozens of `is_*()` helpers
through ~line 480; fields themselves start at `struct VEH` line 482 region).
LuaJIT `ffi.cdef` accepts only C. Consequences for `tools/gen_ffi.py`:

- Emit **fields only**, dropping method definitions. Prefer parsing with
  `libclang` Python bindings over regex — these headers also contain bitfield
  comments, nested enums and `#pragma pack` regions that regex handles poorly.
- Re-expose dropped helpers in the Lua `api/` layer (Phase 3.2), porting their
  one-line bodies manually as needed.
- **Size validation without static_asserts:** the headers have *no*
  `static_assert(sizeof...)` to copy from. Instead, have the host side export
  the truth: `luaai.cpp` passes `sizeof(VEH)`, `sizeof(BASE)`, `sizeof(MAP)`,
  `sizeof(UNIT)`, `sizeof(Faction)`... through the host API at init, and
  `ffi/types.lua` asserts `ffi.sizeof('VEH') == host.sizes.VEH` for every
  emitted struct. This catches generator drift on every launch.

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

### 3.3 Functions by address and host API

- Engine calls follow the pattern `fp_none game_rand = (fp_none)0x64601D;`
  (`engine.cpp:311`), with `__cdecl` typedefs at `engine.h:205-213` and
  `__thiscall` ones for window classes (`engine.h:561`). LuaJIT FFI on x86
  supports `__cdecl`, `__stdcall`, `__thiscall` in cdecls.
- Thinker's own C++ helpers are exposed through one `extern "C"` struct of
  function pointers (`struct LuaHostApi` in `luaai.h`), passed to `init.lua` as
  a lightuserdata + cdef. Include a `version` int; bump it on any layout change
  and assert it in Lua. This avoids DLL symbol-export fragility.

### 3.4 Correction: PMTable/NodeSet are STL — not FFI-accessible

`PMTable` is `std::unordered_map<Point, PInfo>` and `NodeSet` is
`std::set<MapNode>` (`engine.h:196-197`). The plan's statement that Lua reads
`mapdata`/`mapnodes` "via FFI" is wrong as written. Access goes through host-API
accessor functions instead, e.g.:

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

---

## Phase 4 — porting

### 4.1 Hook plumbing

- C side keeps a cache: `name -> LUA_REF` filled lazily from the Lua-side
  registry table (`ai.hooks`), invalidated on reload. Per-call overhead is then
  one `lua_rawgeti` + `lua_pcall`.
- Signature variants needed (from the seam survey): `int f(int)` covers most
  (`select_build(base_id)`, `*_move(veh_id)`, `mod_tech_ai(faction_id)`);
  social AI needs pointer args (`CSocialCategory*` — pass as lightuserdata,
  cast with FFI on the Lua side).
- Return protocol: hook returns `nil` → "not handled" → C++ fallback runs. Any
  non-nil is the decided value. This lets a Lua module partially opt in.

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
   now, expose via host API, or already available.
2. Port 1:1, keeping the C++ control flow recognizable; comment the origin
   (`-- port of tech.cpp:mod_tech_val`).
3. Enable in shadow mode (`lua_shadow=1`), play/autoplay until divergences are
   zero across the plan's 5.x test matrix.
4. Flip default, move on. Never port two modules in shadow simultaneously —
   divergence attribution gets muddy.

### 4.4 Movement-specific notes

- `move_upkeep(faction_id, mode)` (`move.cpp`) is both *computation* (fills
  `mapdata`, `mapnodes`, region info — stays in C++ per plan 4.3) and *decision
  prep* (invasion/naval planning). Split it when porting: keep the table fills
  as host primitives; port the planning that consumes them.
- `combat_move` interleaves decisions with engine actions (`set_move_to`,
  attack orders). Side effects make shadow comparison impossible at function
  level — validate via determinism runs (plan 5.3), and shadow only its pure
  scoring helpers (`battle_priority`-style functions).

---

## Phase 5 — validation

### 5.1 Shadow wrapper (in `lua_ai_hook_*`, C side)

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

Requires `game_rand_restore` from 3.5. Log format: one line per divergence with
function, args, both results — greppable, diffable.

### 5.2 Out-of-game tests

`lua/ai/*` must import engine access only via `lua/api/*`. A mock `api` (plain
Lua tables, no ffi) makes modules runnable under Arch's native `luajit`
(`pacman -S luajit`). Keep the ffi require inside `api/`, never in `ai/` — that
is what makes mocking possible. Runner: plain `luajit lua/test/run.lua` looping
over `test_*.lua` files; no framework dependency needed initially.

### 5.3 Autoplay harness

`src/test.cpp` / `extra_setup()` is an **empty debug-build scaffold** — no
autoplay facility exists today. Add a config `autoplay_turns=N`: when set,
`mod_turn_upkeep` (hooked at `patch.cpp:656`) auto-ends turns for the player
faction and calls save + exit at turn N. State hash: end-of-turn Lua script
iterating factions/bases/vehs writing one line per turn to a hash log; two runs
with the same seed must produce identical files (`cmp`).

### 5.4 Performance instrumentation

Wrap the AI phases in `mod_turn_upkeep`/`move_upkeep`/production loops with
`GetTickCount()` deltas logged per faction per turn (debug builds). Baseline the
C++ numbers **before** the movement port starts, on a late-game save (huge map,
7 factions). LuaJIT profiler: `require("jit.p").start("vf")` toggled by an
Alt-key or config flag in debug builds.

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
  --build --preset ninja-develop`; `luacheck lua/` (install via luarocks);
  `luajit lua/test/run.lua`. Upload `thinker.dll` artifact.
- Docs to write: `docs/LUA_API.md` (generated skeleton from `api/` module
  docstrings if practical), `docs/LUA_PORTING.md` with the module checklist
  table (function → Lua file → status: pending/shadow/default).
- "Hello AI" example: override exactly one hook (suggest `select_build` for one
  base with a printed rationale) — small enough to read in one sitting, real
  enough to show the whole loop.

---

## Known traps (collected)

1. `Vehs`/`Bases` are re-pointable — never bake their addresses into Lua (3.2).
2. `PMTable`/`NodeSet` are STL — host accessors only (3.4).
3. Engine structs have C++ methods — cdefs need field-only generation (3.1).
4. No struct-size asserts exist in the headers — export sizes via host API (3.1).
5. `debug()` is a no-op outside debug builds — Lua logging needs its own file (2.6).
6. Shadow mode must snapshot/restore *both* RNG streams (3.5, 5.1).
7. `mod_enemy_move` orchestration stays in C++; hook the per-class movers (4.2).
8. Upstream rewrites big files — after every upstream merge, re-run `gen_ffi.py`
   and diff the emitted cdefs; size asserts catch silent struct changes.
