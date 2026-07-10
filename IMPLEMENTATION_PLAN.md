# Implementation Plan — Thinker AI in Lua

Goal: extract Thinker Mod's deterministic AI (currently written in C++ inside
`thinker.dll`) into Lua scripts executed by an interpreter embedded in the DLL,
keeping the current behavior as the baseline and opening the way for improved AI
development without recompiling the mod.

**Scope:**

- Build the project on Arch Linux (mingw32 cross-compile) and run it via Wine.
- Embed a Lua interpreter (recommendation: LuaJIT, see Phase 2).
- Port the AI decision modules from C++ to Lua, incrementally and verifiably,
  with fallback to the original C++ code.

**Out of scope (do not touch):**

- Engine bug fixes, Scient's patches, rendering, mapgen, UI, launcher, netcode.
  All of that stays in C++.
- AI balance/behavior changes. The port must be 1:1 at first; AI improvements
  come later, on top of the Lua base.

---

## Architectural context (how the AI works today)

Thinker is a DLL (`thinker.dll`) injected into `terranx.exe` (a 32-bit Windows
binary). In `DllMain`/`ThinkerModule` (`src/main.cpp:442`), the mod reads
`thinker.ini` and applies in-memory patches (`src/patch.cpp`), redirecting engine
`call`s to mod functions via `write_call(address, function)`. Thinker's AI is
enabled per faction according to `factions_enabled` (`src/faction.cpp:143`).

AI entry points (the "seams" where Lua will plug in):

| Domain | C++ entry | Files | Size |
|---|---|---|---|
| Turn/unit dispatch | `mod_enemy_turn`, `mod_enemy_veh`, `mod_enemy_move` | `veh_turn.cpp` | ~900 loc |
| Movement per unit type | `colony_move`, `former_move`, `crawler_move`, `artifact_move`, `trans_move`, `nuclear_move`, `combat_move`, `move_upkeep` | `move.cpp` | ~3700 loc |
| Strategic plans | `plans_upkeep`, `design_units`, `former_plans`, `invasion_plan`, `land_raise_plan` | `plan.cpp`, `move.cpp` | ~600 loc |
| Base production | `select_build`, `find_proto`, `unit_score`, `facility_score`, `find_project`, `mod_base_hurry` | `build.cpp`, `plan.cpp` | ~1300 loc |
| Social engineering / diplomacy | `mod_social_ai`, `mod_wants_to_attack` | `faction.cpp` | ~2500 loc (partial) |
| Research | `mod_tech_ai`, `mod_tech_val` | `tech.cpp` | ~760 loc |
| Goals | `add_goal`, `wipe_goals` etc. (state in the engine's `Faction` struct) | `goal.cpp` | ~180 loc |
| Pathfinding and tile search | `Path`, `TileSearch`, `PMTable mapdata`, `NodeSet mapnodes` | `path.cpp`, `map.cpp`, `move.h` | ~1000 loc |

Relevant infrastructure:

- Engine structures (VEH, BASE, Faction, MAP, UNIT, `alphax.txt` rules) are
  already 100% mapped in `engine_types.h`, `engine_veh.h`, `engine_base.h`,
  `engine.h` — fixed addresses for globals such as `Vehs`, `Bases`, `Factions`,
  `MapTiles`.
- RNG: the AI uses the engine's own RNG (`game_rand`, `src/random.cpp`) and its
  own LCG (`random(n)`). Determinism matters for replays/multiplayer sync.
- Logging: `debug.txt` via `debug()`/`debug_ver()`; custom crash handler.

**Total to port: ~9–10k lines of C++ decision logic.** Pathfinding and hot data
structures (PMTable) stay in C++ as primitives exposed to Lua (see Phase 4).

---

## Phase 0 — Fork preparation

> **Status: ✅ completed (2026-07-10)** — remote `upstream` = `induktio/thinker`,
> remote `origin` = `JotaPeRL/thinker-lua`, working branch `lua-ai` created and
> pushed.

1. Configure remotes: `origin` = your fork; `upstream` = `induktio/thinker`.
2. Create the `lua-ai` working branch from `master`.
3. Strategy for coexisting with upstream: Thinker is actively developed (large
   rewrites, e.g. commit `15418b2 "Rewrite faction and movement code"`).
   To minimize rebase conflicts:
   - Concentrate new code in new files (`src/luaai.cpp`, `src/luaapi.cpp`, the
     `lua/` directory), touching existing files as little as possible.
   - In existing files, the touch is 1–3 lines per hooked function (the "seam"
     of Phase 4).
4. Document the fork's goal and status in the fork's `Readme.md`.

**Done when:** fork builds identically to upstream, branch created.

---

## Phase 1 — Build on Arch Linux + running via Wine

> **Status: ✅ completed (2026-07-10)** — `develop` and `debug` builds compile
> cleanly (mingw GCC 16.1.0, CMake 4.3.4, Ninja 1.13.2); GOG game installed at
> `~/.wine-smac/drive_c/Games/SMAC` (terranx.exe v2.0, SHA-1 confirmed);
> `tools/deploy.sh` created; game launches normally via Wine with the mod loaded.

The project already supports mingw-w64 i686 cross-compile via CMake
(`CMakeLists.txt` hardcodes `i686-w64-mingw32-g++`; presets in
`CMakePresets.json`).

### Day-to-day commands (validated)

```sh
# Develop build (optimized, statically linked)
cmake --preset ninja-develop            # configure (first time)
cmake --build --preset ninja-develop    # artifacts in build/develop/

# Debug build (BUILD_DEBUG: dev shortcuts Alt+D/M/V, verbose debug.txt)
cmake --preset ninja-debug              # configure (first time)
cmake --build --preset ninja-debug      # artifacts in build/debug/

# Deploy to the game folder (copies dll/exe, modmenu.txt, basenames/;
# the debug build also copies the mingw runtime DLLs)
tools/deploy.sh develop                 # or: tools/deploy.sh debug

# Launch the game
WINEPREFIX=~/.wine-smac wine ~/.wine-smac/drive_c/Games/SMAC/thinker.exe -windowed
```

### 1.1 Toolchain

```sh
sudo pacman -S --needed mingw-w64-gcc cmake ninja wine
```

Arch-specific notes:

- Arch's `mingw-w64-gcc` package provides both triplets, including
  `i686-w64-mingw32-g++` — confirm with `i686-w64-mingw32-g++ --version`.
- `cmake_minimum_required(VERSION 3.31)` — fine, Arch ships a recent CMake.
- Arch's Wine runs 32-bit binaries (WoW64/multilib). Enable `[multilib]` in
  `pacman.conf` if not already enabled (also needed for LuaJIT, Phase 2).

### 1.2 Build

```sh
cmake --preset ninja-develop
cmake --build --preset ninja-develop
# artifacts: build/develop/thinker.dll and thinker.exe
```

Builds to validate: `debug` (with `BUILD_DEBUG`, developer shortcuts Alt+D/M/V
etc., essential for the following phases) and `develop`.

Results observed in the actual build:

- Arch's mingw GCC 16.1.0 compiles both presets **with zero warnings**.
- Arch's mingw links against **UCRT** (`api-ms-win-crt-*` imports), unlike the
  msvcrt toolkit mentioned in upstream `Technical.md`. Transparent under Wine
  (built-in ucrtbase) and on Windows 10+; it would only break on XP.
- The `debug` build is **not static** (`-static` only applies to
  develop/release): it depends on `libgcc_s_dw2-1.dll`, `libstdc++-6.dll` and
  `libwinpthread-1.dll`, copied from `/usr/i686-w64-mingw32/bin/` by
  `deploy.sh`.

### 1.3 Installation and testing under Wine

How it was done (prefix at `~/.wine-smac`, game at `drive_c/Games/SMAC`):

1. Arch's Wine ≥ 11 is **WoW64-only**: `WINEARCH=win32` is no longer supported.
   Use a default prefix — 32-bit binaries run via WoW64 normally:
   `WINEPREFIX=~/.wine-smac wineboot -u`.
2. GOG installer (Inno Setup) in silent mode:
   `WINEPREFIX=~/.wine-smac wine setup_...exe /VERYSILENT /SUPPRESSMSGBOXES
   /NORESTART /SP- /LANG=english '/DIR=C:\Games\SMAC'`.
   Verify `terranx.exe` v2.0
   (SHA-1 `4b19c1fe3266b5ebc4305cd182ed6e864e3a1c4a` — confirmed).
3. Deploy with `tools/deploy.sh [develop|debug]`. **Note:** besides
   `thinker.dll`/`thinker.exe`, the mod requires `docs/modmenu.txt` in the game
   folder (it defines all Thinker dialogs, including Alt+T) and uses
   `docs/basenames/`. `deploy.sh` copies both; `docs/alphax.txt` (optional rule
   changes) and `docs/smac_mod/` are left out on purpose.
4. Launch and validate (done): game opens in windowed mode, mod loaded, Alt+T
   works. Wine notes: `WINEDEBUG=-all` for performance; the GOG
   `1.1_pracx_ddraw` release ships `ddraw.dll` and PRACX in the folder — they
   did not interfere in testing, but removing/renaming `ddraw.dll` is the first
   thing to try if graphics problems appear.

### 1.4 CI (optional but recommended)

GitHub Actions on `ubuntu-latest` with `g++-mingw-w64-i686-posix` + CMake,
building `develop` on every push. Ensures the fork's build never breaks while
the port advances.

**Done when:** game runs via Wine with the locally compiled `thinker.dll`,
Alt+T menu visible, a game playable for 50+ turns without crashing.

---

## Phase 2 — Embedding the Lua interpreter

### 2.1 Interpreter choice: **LuaJIT 2.1** (recommended)

| Criterion | LuaJIT 2.1 | Lua 5.4 (PUC) |
|---|---|---|
| 32-bit x86 Windows target | LuaJIT's original platform, excellent support | OK |
| Performance | Near C with the JIT (matters for `move_upkeep`/per-tile scoring) | 2–10x slower |
| **FFI** | **Accesses engine structs directly in memory, no manual binding layer** | None; would require hundreds of manual C bindings |
| Calling engine functions at fixed addresses | `ffi.cast` with `__cdecl`/`__stdcall`/`__thiscall` support on x86 | Requires a C wrapper per function |
| Build | Cross-compile with an extra step (multilib host) | Trivial (vendor the .c files into the CMake glob) |
| Language | Lua 5.1 + extensions | Lua 5.4 (goto, native integers) |

FFI is the deciding factor: the game is a 32-bit process with all structures
already mapped in headers; with LuaJIT, Lua reads/writes `Vehs[i]`, `Bases[i]`,
`MAP*` directly and calls engine functions by address. This shrinks the binding
layer from "thousands of lines of C glue" to "cdef declarations generated from
the headers". JIT performance also removes the risk in hot loops (map sweeps of
128x128+ per faction per turn).

Documented fallback: if LuaJIT proves problematic under Wine (unlikely — it is
widely used in 32-bit Windows games), switching to vendored Lua 5.4 only means
redoing the binding layer (Phase 3), not the AI scripts — which is why Phase 3
defines a high-level API that isolates the rest of the scripts from the FFI
mechanism.

### 2.2 Building LuaJIT

1. Vendor LuaJIT as a git submodule at `third_party/luajit` (v2.1 branch).
2. Cross-compile for Windows i686, static link:

```sh
# requires multilib on Arch: sudo pacman -S --needed multilib-devel lib32-glibc
make -C third_party/luajit/src HOST_CC="gcc -m32" \
     CROSS=i686-w64-mingw32- TARGET_SYS=Windows BUILDMODE=static libluajit.a
```

   (The host build of `minilua`/`buildvm` needs the same pointer size as the
   target — hence `gcc -m32` and multilib.)
3. Integrate into CMake: an `ExternalProject`/`add_custom_command` target that
   runs the make above and produces `libluajit.a`;
   `target_link_libraries(thinkerlib PRIVATE luajit)` + include dir. Document in
   the fork's `Technical.md`.
4. Smoke test: `luaL_dostring(L, "return 1+1")` called at startup, result logged
   to `debug.txt`.

### 2.3 Lifecycle and layout

- **Init:** in `ThinkerModule`/`DllMain` (`src/main.cpp:442`), after
  `patch_setup` and `thinker.ini` parsing: create the `lua_State`, open the
  standard libs + ffi, and load `lua/init.lua` from the game directory. A new
  file pair `src/luaai.cpp/.h` encapsulates everything (state, pcall wrappers,
  reload).
- **Script layout** (installed alongside the game, shipped in the release zip):

```
<game folder>/
  thinker.dll
  lua/
    init.lua          -- bootstrap, loads modules
    ffi/types.lua     -- cdefs generated from the headers (Phase 3)
    ffi/funcs.lua     -- engine/thinker functions by address
    api/…             -- high-level API (game, map, rules, rand, log)
    ai/…              -- the ported AI (tech.lua, social.lua, build.lua, move.lua…)
    test/…            -- unit tests runnable outside the game
```

- **New `thinker.ini` options:**
  - `lua_ai=1` — toggles the Lua AI globally (0 = pure C++ behavior).
  - `lua_shadow=0` — Phase 5 shadow mode (compares Lua vs C++ without affecting
    the game).
  - `lua_strict=0` — 0: a Lua error falls back to C++ and logs; 1: an error
    opens a popup and exits (for development).
- **Error handling:** every hook call goes through `lua_pcall` with a traceback
  handler. Error → full log to `debug.txt` (once per function/turn to avoid
  flooding) → "not handled" return → the original C++ runs. **The game must
  never break because of a script.**
- **Hot reload:** developer shortcut (e.g. Alt+U, following the `debug.cpp`
  pattern) that discards the `lua_State` and reloads `lua/`. Development
  iteration without restarting the game — one of the project's biggest wins.
- **Logging:** expose `log.debug(...)`/`log.ver(...)` writing to the same
  `debug.txt`, prefixed `lua:`, honoring the Alt+M verbose toggle.

**Done when:** `thinker.dll` with static LuaJIT links and runs under Wine;
`init.lua` loads, logs to `debug.txt`, hot reload works, a deliberate script
error does not bring the game down.

---

## Phase 3 — Binding layer (FFI + high-level API)

Two layers, so the Lua AI never touches raw FFI:

### 3.1 Low layer: cdefs and addresses

1. **cdef generator:** Python script at `tools/gen_ffi.py` that parses
   `engine_types.h`, `engine_veh.h`, `engine_base.h`, `engine_enums.h` and emits
   `lua/ffi/types.lua` (structs, enums and `sizeof` asserts). Generated, not
   handwritten → when upstream changes a struct, regenerate. Validate at
   startup: `assert(ffi.sizeof('VEH') == 52)` etc. against the existing
   `static_assert`s in the C++ headers.
2. **Engine globals:** address table (e.g. `Vehs = ffi.cast('VEH*', 0x...)`)
   extracted from `engine.h`. Also generated by the script.
3. **Functions by address:** engine (`can_arty`, `veh_skip`, `set_move_to`,
   `base_find_3`, `action_...` etc.) and Thinker helpers that stay in C++
   (pathfinding, PMTable). For the C++ helpers, export an `extern "C"` table of
   function pointers (`struct LuaHostApi`) passed to Lua at init — more robust
   than relying on DLL symbol exports.
4. **RNG:** expose `rand.game(n)` → `game_randv(n)` and `rand.map(n)` → the LCG
   in `random.cpp`. **Project rule: `math.random` is forbidden in `lua/ai/`**
   (init may even override it with an error). This preserves the engine's RNG
   stream → determinism and network sync identical to C++.

### 3.2 High layer: idiomatic API

Thin Lua modules over the FFI, with the semantics of the helpers already in
`veh.h`/`base.h`/`map.h`:

- `game`: iterators `game.vehs()`, `game.bases()`, `game.factions()`,
  `game.turn()`, access to `conf`.
- `map`: `map.tile(x, y)` (with X-axis wrap like `mapsq`), `map.range`,
  `map.iter_near(x, y, r)`, tile flags (`is_fungus`, `items`, `region`...).
- `veh`/`base`: methods mirroring the C++ ones (`veh:triad()`, `veh:speed()`,
  `base:can_build(item)`, ...). Implement on demand, as the port requires.
- `path`: wrappers over the retained C++ primitives (`path.find`,
  `path.move_to`, `tilesearch.iterate(...)`, `mapdata`/`mapnodes` reads).
- `rules`: access to the already-parsed `alphax.txt` tables (Units, Facility,
  Tech, Social).

Determinism guideline: decisions must never depend on hash-table iteration
order (`pairs`). The API provides index-ordered iterators; review this in the
code review of every ported module.

**Done when:** from inside the game, a script can list a faction's bases and
units, read tiles, call `path.find` and get the same values the C++ `debug.txt`
reports. Struct layout asserts pass.

---

## Phase 4 — Incremental AI port

### 4.1 Hook mechanism (seam)

Every C++ entry point gets a 2–3 line detour at the top:

```cpp
int select_build(int base_id) {
    int value;
    if (lua_ai_hook_i("select_build", &value, base_id)) {
        return value; // decided by Lua
    }
    // ... original C++ code untouched (fallback)
}
```

`lua_ai_hook_*` (in `luaai.cpp`) returns `false` if `lua_ai=0`, if the function
is not registered on the Lua side, or if the pcall failed. This way each
function migrates individually, and the original C++ remains as reference and
fallback for the whole project (removal only in an optional cleanup phase).

Shared state during the transition: `plans[]` (AIPlans), `mapdata` (PMTable) and
`mapnodes` remain the canonical data in C++, accessed by Lua via FFI — both
sides see the same state, so half of a domain can be ported without desync.

### 4.2 Porting order (lowest risk to highest)

Each item follows the same cycle: port 1:1 → shadow mode (Phase 5.1) until
divergences reach zero → enable Lua by default on the branch → move to the next.

1. **Pilot — research AI** (`tech.cpp`: `mod_tech_val` scoring, `mod_tech_ai`;
   ~400 relevant loc). Small, pure (score per tech), easy to compare. Validates
   the whole pipeline (hook, FFI, RNG, shadow).
2. **Social engineering** (`faction.cpp`: `mod_social_ai` and the social model
   scoring; `mod_wants_to_attack`). Self-contained, runs once per faction per
   turn.
3. **Production and plans** (`build.cpp` + `plan.cpp`): `governor_priorities`,
   `facility_score`, `unit_score`/`find_proto`, `select_colony`/`select_combat`,
   `select_build`, `find_project`, `mod_base_hurry`, then `plans_upkeep`,
   `design_units`, `former_plans`. This is the heart of the single-player
   challenge and where future AI improvements pay off the most.
4. **Movement** (`move.cpp` + dispatch in `veh_turn.cpp` + `goal.cpp`): start
   with the isolated movers (`artifact_move` → `nuclear_move` → `crawler_move` →
   `colony_move` → `former_move` → `trans_move`) and finish with `combat_move` +
   `move_upkeep` + invasion plans. The largest and the most
   performance-sensitive.
5. **AI probe decisions** (`probe.cpp`, partial — only the AI's target/action
   choices; resolution mechanics stay in C++).

### 4.3 What stays in C++ (primitives exposed to Lua)

- All of `path.cpp` (A*, `Path::find`, low-level tactical movement).
- `TileSearch` and the `PMTable`/`mapdata` fill in `move_upkeep` (O(map) sweeps
  per turn). Lua orchestrates (decides *what* to do), C++ provides fast queries
  (*how* to compute). If LuaJIT later proves fast enough, port these too — a
  decision deferred to measurement, not guesswork.
- Combat itself (`veh_combat.cpp`), engine mechanics, everything UI/render.

### 4.4 Lua code conventions

- One module per domain (`ai/tech.lua`, `ai/social.lua`, `ai/build.lua`,
  `ai/move.lua`, `ai/plan.lua`), registering hooks in a central `ai.hooks`
  table read by `luaai.cpp`.
- 1:1 port commented with a reference to the original C++ function (name +
  file), for auditing while upstream evolves.
- `luacheck` in CI to catch accidental globals and silly mistakes.

**Done when (per module):** shadow mode with zero divergences over N autoplay
turns (see 5.1) on at least 3 distinct saves + 1 new game with a fixed seed; no
noticeable turn-time regression.

---

## Phase 5 — Validation, testing and performance

### 5.1 Shadow mode (the port's central tool)

With `lua_shadow=1`, the hook runs **both** implementations and compares:

1. Save the RNG states (`game_rand_state()`, `random_state()`).
2. Run the Lua version, capture the result, **restore the RNGs** (the Lua
   decision must not consume the stream twice).
3. Run the C++ (which is what counts for the game).
4. Divergence → log to `debug.txt`: function, arguments, each side's result.

Constraint: functions with side effects (e.g. `combat_move` issues orders)
cannot run twice; for those, shadow comparison is limited to the internal pure
scoring functions, and whole-system validation is done by the determinism tests
(5.3) toggling `lua_ai` between runs.

### 5.2 Unit tests outside the game

The `lua/ai/*` modules depend only on the `api/*` layer; create `lua/test/mock/`
with fake API implementations (synthetic map, test factions) and run with Arch's
native `luajit` (`pacman -S luajit`) + a simple runner (or `busted`). Fast tests
for scoring functions (facility_score, unit_score, tech_val) with cases
extracted from real game logs. Runs in CI.

### 5.3 Determinism and regression

- Manual/scripted harness: same seed + same initial save, autoplay for N turns
  (all factions AI, player as observer/autopilot; investigate the debug build's
  facilities — `test.cpp`/`extra_setup` — and, if needed, add an
  `autoplay_turns=N` flag that exits and saves on its own).
- Compare: a state hash (unit positions, bases, tech, energy per faction,
  extractable via a Lua script at end of turn) between two runs with `lua_ai=1`
  (Lua determinism) and between `lua_ai=0` vs `lua_ai=1` (port fidelity, valid
  as long as the port is 1:1).
- Verbose `debug.txt` diffable between runs.

### 5.4 Performance

- Instrument time per turn phase (upkeep, production, movement) per faction,
  logged to debug. Measure the C++ baseline before porting movement.
- Budget: Lua AI turn ≤ 1.5x the C++ time on huge maps with 7 factions in the
  late game (the real target is "imperceptible to the eye").
- Tools: `jit.p` (LuaJIT profiler) embeddable via script; check that hot loops
  do not fall back to the interpreter (`jit.v`/`jit.dump` in development
  builds).

### 5.5 Compatibility

- Saves: the port does not change the save format (AI state already lives in
  the engine structs/`plans[]`). Validate loading vanilla and Thinker C++
  saves.
- Multiplayer: out of scope to validate deeply, but keep the RNG rule (3.1) and
  document that `lua_ai` must be identical across peers.
- Native Windows: ask the community/a friend with real Windows for a smoke test
  before any release (Wine is the dev environment, not the only target).

---

## Phase 6 — Documentation, packaging and DX

1. `docs/LUA_API.md`: API reference (`game`, `map`, `veh`, `base`, `path`,
   `rules`, `rand`, `log`) + hook lifecycle + rules (RNG, determinism,
   prohibitions).
2. `docs/LUA_PORTING.md`: C++ function → Lua module map, status per module
   (port checklist), how to use shadow mode and hot reload.
3. Update the fork's `Technical.md`: Arch build, LuaJIT, deploy via Wine.
4. Packaging: include `lua/` in the zips (`tools/makedevzip.sh`,
   `tools/makerelzip.sh`) and in `deploy.sh`.
5. "Hello AI" example: a minimal commented script that overrides a simple hook,
   as the entry point for other modders — this is the fork's end product.

---

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| FFI has no memory safety: a wrong cdef corrupts game memory | Hard-to-debug crash | Generated cdefs + `sizeof`/offset asserts at startup; crash handler already logs to `debug.txt`; debug builds with extra checks |
| Thinker upstream does large rewrites | Painful rebases | Minimal, centralized seams; new code in new files; regenerate cdefs by script |
| Movement performance in Lua | Slow turns in the late game | Pathfinding/PMTable stay in C++; LuaJIT; measure before/after; port movement last |
| Silent behavioral divergence | "Different" AI without noticing | Per-function shadow mode; fixed-seed determinism tests; auditable 1:1 port |
| LuaJIT + Wine/32-bit edge cases | Blocker in Phase 2 | Early smoke test (Phase 2 ends with Lua running in-game); documented Lua 5.4 fallback, isolated by the API layer |
| RNG consumed differently | Desync/broken replays | `rand.*` mandatory, `math.random` banned, snapshot/restore in shadow mode |

---

## Milestones

- **M1 — Local build:** ✅ completed (2026-07-10) — game runs via Wine with a DLL compiled on Arch.
- **M2 — Lua embedded:** Phase 2 complete (init.lua, safe errors, hot reload).
- **M3 — Bindings:** Phase 3 complete (a script reads game state and calls primitives).
- **M4 — Pilot:** research AI in Lua enabled by default, clean shadow runs.
- **M5 — Production/social in Lua:** porting-order modules 2 and 3 active.
- **M6 — Movement in Lua:** port complete; C++ becomes legacy fallback.
- **M7 — Fork release:** docs, zips with `lua/`, customization example.

From M4 onward the fork is already useful (custom research AI can be
experimented with); each following milestone widens the moddable surface without
waiting for the whole project.
