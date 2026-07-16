# Implementation Plan — Thinker AI in Lua (rev 2)

> Tactical, code-grounded notes for executing each phase live in
> `IMPLEMENTATION_DETAILS.md` — read both before starting work on a phase.

Goal: extract Thinker Mod's deterministic AI (currently written in C++ inside
`thinker.dll`) into Lua scripts executed by an interpreter embedded in the DLL,
keeping the current behavior as the baseline and opening the way for improved AI
development without recompiling the mod.

Conceptually, the project is **not** "porting C++ to Lua inside the same address
space". It is **separating AI policy from engine mechanism**: Lua is a client of
a versioned Thinker API. FFI may *implement* parts of that API, but it is not
itself the API.

**Rev 2 changes (2026-07-11):** incorporates external review. Main deltas:
hook taxonomy (pure/transactional/command) with a propose-then-commit contract;
read/write asymmetry in the FFI layer (reads direct, writes and calls wrapped);
cdef generation from the compiler itself instead of header parsing; a
feasibility spike (Phase 2A) before consolidating the runtime; golden traces as
the primary test anchor; upstream drift detection by function-body hashing;
graduated equivalence levels; integer-semantics rules; milestone reordering.

**Interpreter decision (final): LuaJIT 2.1, pinned commit, no fallback.**
PUC Lua 5.4 is formally abandoned as a contingency. If the Phase 2A spike shows
LuaJIT to be unviable in this process (mingw i686 static link, inside
terranx.exe, under Wine and native Windows), **the project ends**. This is a
deliberate kill criterion, not an open question — it removes the tax of keeping
the AI code "5.4-portable" and lets the API layer use metatypes freely.

**Scope:**

- Build the project on Arch Linux (mingw32 cross-compile) and run it via Wine.
- Embed LuaJIT 2.1 statically in `thinker.dll`.
- Port the AI decision modules from C++ to Lua, incrementally and verifiably,
  with fallback to the original C++ code where the hook contract permits it.

**Out of scope (do not touch):**

- Engine bug fixes, Scient's patches, rendering, mapgen, UI, launcher, netcode.
  All of that stays in C++.
- AI balance/behavior changes. The port must be 1:1 at first; AI improvements
  come later, on top of the Lua base.
- **Multiplayer is not supported during the porting phase.** The implementation
  must avoid gratuitous nondeterminism (RNG rules, iteration order), but
  multiplayer validation and script synchronization (manifest with script
  hashes, identical LuaJIT builds across peers, no unilateral reload) are
  deferred to a possible future phase.

---

## Architectural context (how the AI works today)

Thinker is a DLL (`thinker.dll`) injected into `terranx.exe` (a 32-bit Windows
binary). In `DllMain`/`ThinkerModule` (`src/main.cpp:442`), the mod reads
`thinker.ini` and applies in-memory patches (`src/patch.cpp`), redirecting engine
`call`s to mod functions via `write_call(address, function)`. Thinker's AI is
enabled per faction according to `factions_enabled` (`src/faction.cpp:143`).

AI entry points (the "seams" where Lua will plug in), with their **hook class**
(see Phase 4.1):

| Domain | C++ entry | Files | Size | Class (initial assessment) |
|---|---|---|---|---|
| Turn/unit dispatch | `mod_enemy_turn`, `mod_enemy_veh`, `mod_enemy_move` | `veh_turn.cpp` | ~900 loc | command |
| Movement per unit type | `colony_move`, `former_move`, `crawler_move`, `artifact_move`, `trans_move`, `nuclear_move`, `combat_move`, `move_upkeep` | `move.cpp` | ~3700 loc | command (inner scoring: pure) |
| Strategic plans | `plans_upkeep`, `design_units`, `former_plans`, `invasion_plan`, `land_raise_plan` | `plan.cpp`, `move.cpp` | ~600 loc | transactional |
| Base production | `select_build`, `find_proto`, `unit_score`, `facility_score`, `find_project`, `mod_base_hurry` | `build.cpp`, `plan.cpp` | ~1300 loc | mostly pure query / transactional |
| Social engineering / diplomacy | `mod_social_ai`, `mod_wants_to_attack` | `faction.cpp` | ~2500 loc (partial) | transactional / pure |
| Research | `mod_tech_ai`, `mod_tech_val` | `tech.cpp` | ~760 loc | pure query |
| Goals | `add_goal`, `wipe_goals` etc. (state in the engine's `Faction` struct) | `goal.cpp` | ~180 loc | command |
| Pathfinding and tile search | `Path`, `TileSearch`, `PMTable mapdata`, `NodeSet mapnodes` | `path.cpp`, `map.cpp`, `move.h` | ~1000 loc | stays in C++ |

The class column is a working hypothesis to be confirmed per function during
porting; each ported function's classification must be recorded in
`docs/LUA_PORTING.md` (Phase 6).

Relevant infrastructure:

- Engine structures (VEH, BASE, Faction, MAP, UNIT, `alphax.txt` rules) are
  already 100% mapped in `engine_types.h`, `engine_veh.h`, `engine_base.h`,
  `engine.h` — fixed addresses for globals such as `Vehs`, `Bases`, `Factions`,
  `MapTiles`.
- RNG: the AI uses the engine's own RNG (`game_rand`, `src/random.cpp`) and its
  own LCG (`random(n)`). Determinism matters for replays and for the port's own
  validation.
- Logging: `debug.txt` via `debug()`/`debug_ver()`; custom crash handler.

**Effort model.** "~9–10k LOC of decision logic to port" measures source size,
not effort. The work splits into four masses with different risk profiles:

| Workstream | LOC | Risk / effort profile |
|---|---|---|
| Embedding & lifecycle (Phase 2) | small | high risk, front-loaded |
| ABI/API & bindings (Phase 3) | medium | highest risk; must be right |
| Logic translation (Phase 4) | large | moderate risk, mechanical |
| Validation & diagnostics (Phase 5) | medium | high sustained effort |

Translating 400 lines of `tech.cpp` may well take less time than making the two
versions comparable, observable and safe. Long-term, the dominant cost is
**maintaining equivalence while upstream evolves** — hence the drift tooling in
Phase 4.4.

Pathfinding and hot data structures (PMTable) stay in C++ as primitives exposed
to Lua (see Phase 4.3).

---

## Phase 0 — Fork preparation

> **Status: ✅ completed (2026-07-10)** — remote `upstream` = `induktio/thinker`,
> remote `origin` = `JotaPeRL/thinker-lua`, working branch `lua-ai` created and
> pushed.

1. Create the `lua-ai` working branch from `master`.
2. Strategy for coexisting with upstream: Thinker is actively developed (large
   rewrites, e.g. commit `15418b2 "Rewrite faction and movement code"`).
   To minimize rebase conflicts:
   - Concentrate new code in new files (`src/luaai.cpp`, `src/luaapi.cpp`, the
     `lua/` directory), touching existing files as little as possible.
   - In existing files, the touch is 1–3 lines per hooked function (the "seam"
     of Phase 4).
   - Note: minimal seams reduce *textual* conflicts only. Semantic drift
     (upstream changes a formula, RNG order, or a signature without touching
     the seam) is handled by the drift report in Phase 4.4.
3. Document the fork's goal and status in the fork's `Readme.md`.

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
  `pacman.conf` if not already enabled (also needed to build LuaJIT's host
  tools, Phase 2).

### 1.2 Build

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
2. GOG installer (Inno Setup) in silent mode; verify `terranx.exe` v2.0
   (SHA-1 `4b19c1fe3266b5ebc4305cd182ed6e864e3a1c4a` — confirmed).
3. Deploy with `tools/deploy.sh [develop|debug]`. The mod requires
   `docs/modmenu.txt` in the game folder and uses `docs/basenames/`;
   `deploy.sh` copies both.
4. Launch and validate (done): game opens in windowed mode, mod loaded, Alt+T
   works. `WINEDEBUG=-all` for performance; the GOG `1.1_pracx_ddraw` release
   ships `ddraw.dll` and PRACX in the folder — they did not interfere.

**Done when:** game runs via Wine with the locally compiled `thinker.dll`,
Alt+T menu visible, a game playable for 50+ turns without crashing. ✅

---

## Phase 2 — Embedding LuaJIT

### 2.1 Interpreter: LuaJIT 2.1, pinned, no fallback

LuaJIT is chosen for: native x86-32 Windows support (its original platform),
JIT performance for per-tile scoring loops, and FFI for direct *read* access to
the already-mapped engine structs. What FFI is and is not used for is defined
precisely in Phase 3 — it is an implementation detail of the `api/` layer, not
the architecture.

Rules:

- **Pin an exact commit** of the v2.1 branch as the submodule revision
  (`LuaJIT commit: <hash>` recorded in `Technical.md`). Updates are deliberate,
  never implicit. This makes builds reproducible.
- **Do not depend on the JIT for initial viability.** The Phase 2A spike and
  M2 acceptance run first with `jit.off()`, then with the JIT enabled, and
  compare. This separates embedding problems, FFI problems, JIT compiler
  problems, and Wine codegen problems from each other.
- **No performance promise.** LuaJIT *can* approach C, but workloads dominated
  by small FFI calls into C (which abort traces) may not. Performance is
  measured (Phase 5.4), not assumed; the architecture minimizes Lua↔C boundary
  crossings in hot paths precisely for this reason.
- **Kill criterion:** if the spike fails in a way that cannot be resolved
  (crashes attributable to LuaJIT itself under mingw-static/Wine/terranx that
  survive `jit.off()`), the project is abandoned. No PUC Lua contingency.

### 2.2 Building LuaJIT

1. Vendor LuaJIT as a git submodule at `third_party/luajit`, pinned commit.
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

### Phase 2A — Feasibility spike (gate for everything else)

> **Status: ✅ completed (2026-07-13)** — LuaJIT pinned at
> `3c4f9fe2052b8d08a917ac0d5f38563f0297b5a3` (v2.1), builds clean on both
> presets, deployed. Checklist items 1–7 verified in `lua.log` (init, host
> reads, C→Lua call, contained error with traceback, per-turn calls). Item 9
> (JIT off, then on) verified across two manual play sessions. **Item 8
> relaxed:** no autoplay facility exists yet (`test.cpp`/`extra_setup()` is an
> empty scaffold), so the 100+-turn run was not automated; validation instead
> covered ~15 manually-played turns (turns 19–33) split across the JIT
> off/on sessions with zero crashes or unexpected errors, judged sufficient
> for this gate. LuaJIT is confirmed stable in-process under mingw
> static-link + Wine; the spike's purpose (de-risking the interpreter choice)
> is satisfied. Automated long-run autoplay remains open — see Phase 5.3's
> `autoplay_turns=N` — and should be picked up before the Phase 5.3
> determinism harness needs it, not blocking Phase 2B.

A disposable branch (or clearly marked experimental commits) containing **only**:

1. Static LuaJIT linked into `thinker.dll`.
2. Lua VM initialized **outside the loader lock** (see 2.3 — lazy init on
   first use or in an already-patched engine callback, never in the real
   `DllMain` callback path).
3. `init.lua` loaded from the game directory, result logged to `debug.txt`.
4. One `extern "C"` host function returning the current turn, called from Lua.
5. One host function returning a simple value from a base, called from Lua.
6. One C→Lua call into a pure Lua function, result logged.
7. A deliberate Lua error, contained by `lua_pcall` + traceback, game continues.
8. 100+ autoplayed turns without a crash.
9. All of the above with `jit.off()`, then repeated with the JIT on.

Explicitly **not** in the spike: hot reload, cdef generator, high-level API,
shadow framework, packaging, CI. The spike answers one question early — *does
LuaJIT work stably inside this process, with this compiler, this link, and this
Wine?* — before any infrastructure is built on top of it. Per the kill
criterion, a negative answer ends the project cheaply.

### Phase 2B — Production runtime

> **Status: ✅ completed (2026-07-13)** — `src/luaai.cpp/.h` rewritten from
> the Phase 2A spike into the production lifecycle: `lua_ai`/`lua_shadow`/
> `lua_strict` config options (`src/main.h`, `src/main.cpp`,
> `docs/thinker.ini`, same 3-place pattern as `social_ai`); sandboxed VM
> (`base`/`table`/`string`/`math`/`bit`, `io`/`os`/`debug`/`package` gated
> behind `BUILD_DEBUG`); `math.random`/`randomseed` replaced with
> error-raising stubs; deduplicated error logging keyed on
> `(hook, turn, traceback)`; `lua_strict` policy (0/1/2); safe-point hot
> reload on Alt+U (`src/gui.cpp`, sets a flag, applied at the top of the
> next `mod_turn_upkeep`), with a generation counter. `lua/init.lua`
> stripped of the Phase 2A spike fixtures (`spike_add`, `spike_error`,
> `on_turn`, `host_current_turn`, `host_base_pop`) down to the sandbox
> smoke test. In-game validation (manual play via Wine, `lua.log`
> inspected): sandboxed init logs cleanly with no spike fixtures; a
> deliberate `error()` in `init.lua` is contained, traceback-logged, and
> deduplicated per turn (confirmed distinct at turn 44 and turn 50 across
> two sessions); `lua_strict=1` logs the error once and then disables the
> Lua runtime for the rest of the session without crashing. **Not
> separately exercised:** `lua_ai=0` full bypass, the `io`/`os` sandbox
> boundary in a `develop` (non-debug) build vs. a `debug` build, the
> `math.random` stub, and same-turn (as opposed to cross-session) dedup —
> these follow directly from code already reviewed and are low-risk;
> accepted without a dedicated manual pass. `lua_shadow` remains wired but
> inert until Phase 5.1.
- **Init:** a `lua_init()` in the new `src/luaai.cpp/.h`, invoked from a safe
  point after process startup is complete (e.g. lazily on the first hook call,
  or from an existing patched engine callback that runs post-init). `DllMain`
  itself registers nothing Lua-related. Rationale: `DllMain` runs under the
  Windows loader lock; file I/O, runtime initialization and JIT activation
  there are classic deadlock/UB territory, even if it might happen to work.
- **Script layout** (installed alongside the game, shipped in the release zip):

```
<game folder>/
  thinker.dll
  lua/
    init.lua          -- bootstrap, loads modules
    ffi/types.lua     -- cdefs GENERATED by the build (Phase 3)
    ffi/funcs.lua     -- LuaHostApi binding (Phase 3)
    api/…             -- high-level API (game, map, rules, rand, log, cmath)
    ai/…              -- the ported AI (tech.lua, social.lua, build.lua, move.lua…)
    test/…            -- golden-trace runner and unit tests (Phase 5.2)
```

- **Sandboxing:** open only the libraries the AI needs: `base`, `table`,
  `string`, `math` (partially — see RNG and integer rules in Phase 3), `bit`.
  `io`, `os`, `debug` and arbitrary `require` paths are available only in
  development builds. `ffi` is loaded by the `ffi/` and `api/` layers, never
  exposed to `ai/`.
- **New `thinker.ini` options:**
  - `lua_ai=1` — toggles the Lua AI globally (0 = pure C++ behavior).
  - `lua_shadow=0` — Phase 5 shadow mode.
  - `lua_strict=0` — error policy:
    - `0`: log, disable the failing hook for the session, fall back to C++
      where the hook class permits (Phase 4.1);
    - `1`: log, popup/debug trap, disable **all** Lua AI for the session;
    - `2`: deliberate abort (development only).
- **Error handling:** every hook call goes through `lua_pcall` with a traceback
  handler. Log deduplication key: `hook + traceback hash + turn` (not merely
  "once per function/turn", which would hide distinct errors in the same hook).
- **Containment statement (precise version):** *errors raised through the Lua
  runtime are contained and must not terminate the game. Memory corruption from
  unsafe native access cannot be recovered at runtime and is prevented by API
  design (Phase 3's read/write asymmetry) and startup validation — not by
  `pcall`.*
- **Hot reload:** developer shortcut (e.g. Alt+U) that discards the `lua_State`
  and reloads `lua/`, subject to hard rules:
  - Reload only at a **safe point**: never inside a Lua callback, never
    mid-faction-movement; the keypress sets a flag, the reload executes between
    turns / before the next AI phase.
  - **Architectural rule for the 1:1 phase:** no state required to continue the
    game may live exclusively in the `lua_State`. Canonical state stays in the
    engine structs and `plans[]` (this is already the plan — here it becomes a
    stated invariant that makes reload trivially safe).
  - A generation counter is incremented on reload; any handle/cache carrying an
    old generation is rejected.
  - No FFI callbacks are ever registered with C++ (the hook flow is always
    C++→Lua via the registry, see Phase 4.1), so no dangling callback problem.
- **Logging:** expose `log.debug(...)`/`log.ver(...)` writing to the same
  `debug.txt`, prefixed `lua:`, honoring the Alt+M verbose toggle.
  (Implementation decision recorded in `IMPLEMENTATION_DETAILS.md` 2.6:
  `debug.txt` only exists in debug builds, so Lua logging gets its own
  always-available `lua.log` and *mirrors* to `debug.txt` when present.)

**Done when:** Phase 2A spike passes (gate); production runtime has safe init,
sandbox, error policy, dedup logging and safe-point hot reload; a deliberate
script error does not bring the game down and is logged exactly once per
distinct traceback per turn.

---

## Phase 3 — Binding layer (host API + FFI reads)

Guiding principle: **Lua is a client of a versioned Thinker API.** Three layers,
with a strict asymmetry between reads and everything else:

- **Reads of engine state:** direct FFI against the mapped structs, inside
  `api/` only. Reads with startup-validated layouts cannot corrupt memory; the
  worst case is a wrong decision, which is exactly what shadow mode detects.
  This is where FFI's value is — no per-field C wrapper for thousands of
  field accesses, and no boundary crossing per field in hot loops.
- **All writes to engine state and all calls to engine functions:** through
  `extern "C"` wrappers in a `LuaHostApi` struct of function pointers, passed
  to Lua at init. The AI calls a few dozen engine functions, not thousands —
  wrapping them is cheap, and it eliminates the two genuinely dangerous FFI
  uses: hand-declared calling conventions on x86-32 (`cdecl`/`stdcall`/
  `fastcall`/`thiscall`, stack cleanup, struct returns, ECX/EDX) and unchecked
  writes. A wrong signature "works" until it corrupts the stack on a rare path;
  a wrapper compiled by the same toolchain that already calls these functions
  in C++ cannot get the ABI wrong.
- **Raw pointers never leave `ffi/`; persistent references are numeric IDs.**

### 3.1 Low layer: generated cdefs and the host API

> **Status: ✅ completed (2026-07-13)** — `tools/gen_ffi.cpp` compiles as a
> native host binary (`g++ -m32`, not the project's `i686-w64-mingw32-g++`;
> `sizeof`/`alignof`/`offsetof` are compiler-frontend values that don't need
> the real target OS, and the startup validation below is the actual safety
> net) and runs as a CMake build step producing `lua/ffi/types.lua`.
> Includes only the portable, `#pragma pack(1)` struct headers
> (`engine_types.h`/`engine_base.h`/`engine_veh.h`), not `engine.h` (avoids
> its `<windows.h>` dependency); a small block of stub `extern` declarations
> satisfies the inline C++ methods those headers mix in with their fields
> (never called, only compiled). Field cdef types are derived from each
> field's real declared type via a template (`CTypeName`/`FieldShape`), not
> typed in by hand — this caught a real bug during implementation
> (`CChassis::preq_tech` is `int16_t`, a hand-typed `"int32_t"` would have
> produced a self-inconsistent cdef with no way to detect it before runtime).
> Scoped to the tech-AI pilot's read surface (`Faction`, `MFaction`, `CTech`,
> `CFacility`, `CReactor`, `CWeapon`, `UNIT`, `CChassis`, `Continent`,
> `CRules`, `TechOwners`) per M3A — every generated `sizeof` cross-checked
> against the existing hand-maintained `static_assert` table in
> `engine.h:227-261` and matches exactly. Startup validation
> (`lua/ffi/validate.lua`, run once from `init.lua`) asserts every
> `sizeof`/`alignof`/`offsetof` via `ffi.*` and routes a mismatch through the
> Phase 2B `lua_strict` error path. `LuaHostApi` (`src/luaai.h`) is a
> minimal versioned struct — `api_version` plus `rand_game`/`rand_map` only;
> wrapping the C++ helper functions the tech port will call
> (`has_tech`/`is_human`/etc.) and re-exposing `UNIT`'s inline methods are
> deferred to Phase 4, decided on demand as that code is written, per
> `IMPLEMENTATION_DETAILS.md` 4.3. `game_rand_restore()` added to
> `random.cpp`/`.h` next to `game_rand_state()` (Phase 5 shadow mode,
> unused for now). `lua/api/cmath.lua` (`idiv`/`imod`) added. The sandbox
> now opens `ffi` — caught a real LuaJIT quirk along the way:
> `luaopen_ffi` (unlike `base`/`table`/`string`/`math`/`bit`) does not
> self-register a global (`lib_ffi.c` comments "no global 'ffi' created!"
> and returns the module table instead), so it needs its own 1-result open
> call plus an explicit `lua_setglobal`, not the shared 0-result
> `open_lib()` helper used for the other libraries. `package`/`require`
> stays disabled outside debug builds as originally designed; the new
> `lua/ffi/`, `lua/api/` modules load each other via `dofile` (base
> library, always open) instead. All of the above validated in-game via
> Wine (`lua.log`): clean layout validation, then
> `rand.game(10)=7 rand.map(0,10)=7 cmath.idiv(-7,2)=-3 cmath.imod(-7,2)=-1`
> — the `idiv`/`imod` values hand-verified against C truncating-division
> semantics before the in-game run.

1. **cdef generator — generate from the compiler, not from parsing.** A small
   generator program (`tools/gen_ffi.cpp`) that `#include`s the same engine
   headers with the same defines/packing as the real build, and *prints*:
   - `lua/ffi/types.lua`: C-syntax struct/enum declarations for LuaJIT's
     `ffi.cdef`, plus the fixed addresses of engine globals (`Vehs`, `Bases`,
     `Factions`, `MapTiles`, …) from `engine.h`;
   - a validation table: `sizeof` and `alignof` for every exposed struct, and
     `offsetof` for **every exposed field**, plus enum widths, `sizeof(bool)`,
     pointer size (must be 4), and the widths of types used in bitmasks.
   Built and run as a build step (it targets the host; it only reads layout via
   the cross-compiler's front end — if needed, compile it with
   `i686-w64-mingw32-g++` and run under Wine to guarantee identical ABI).
   This avoids writing a C++ header parser entirely: the compiler that produces
   `thinker.dll` is the single source of truth for layout.
2. **Startup validation:** `init.lua` asserts every generated
   `sizeof`/`alignof`/`offsetof` against `ffi.sizeof`/`ffi.alignof`/
   `ffi.offsetof`. Size alone is insufficient — two structs can share a size
   with fields in different positions. Any mismatch: Lua AI refuses to enable,
   loud log, C++ runs.
3. **`LuaHostApi`:** versioned struct of `extern "C"` function pointers
   covering (a) every engine function the AI calls (`can_arty`, `veh_skip`,
   `set_move_to`, `base_find_3`, `action_*`, …), (b) every mutation of engine
   state, (c) the C++ primitives that stay native (pathfinding, `TileSearch`,
   `PMTable` queries — Phase 4.3). Includes `api_version`; `init.lua` checks it.
   Every wrapper validates incoming IDs (`base_id`, `veh_id`, coordinates)
   before dereferencing — handles can go stale after unit death or base capture.
4. **RNG:** expose `rand.game(n)` → `game_randv(n)` and `rand.map(n)` → the LCG
   in `random.cpp`, via the host API. **`math.random` is forbidden in `lua/ai/`**
   — `init.lua` replaces it with a function that raises. This preserves the
   engine's RNG stream → determinism identical to C++.
5. **Integer semantics (project rule).** C and Lua disagree on division and
   modulo of negative integers: C truncates toward zero, Lua floors. In a
   scoring codebase full of integer arithmetic this produces *silent*
   divergences. Therefore:
   - `api/cmath.lua` provides `idiv(a, b)` and `imod(a, b)` with C semantics;
   - bare `/` and `%` are **banned in integer expressions in `lua/ai/`**
     (enforced in code review; a luacheck-adjacent lint pass greps for them);
   - all bitwise work uses the `bit` library (C-like 32-bit semantics);
   - watch signedness and overflow: C++ `int` wraps at 32 bits, Lua numbers
     don't — where the original code relies on wrap/truncation, replicate it
     explicitly (`bit.tobit`).
6. **Float-narrowing rule.** Lua numbers are always doubles; C++ `float`
   locals/fields are 32-bit and *narrow on every assignment/operation*,
   which changes rounding versus computing the same expression in double
   precision throughout. Where the original C++ computes in `float` (first
   seen in `select_build`'s `Wbase`/`Wthreat` block,
   `IMPLEMENTATION_DETAILS.md` 4.10.7), the Lua port must replicate the
   narrowing at the **exact same points** the C++ narrows — after each
   `float`-typed intermediate, not just on the final result — via
   `ffi.new('float', x)` round-trips (`x = tonumber(ffi.new('float', x))`).
   Getting this wrong is a silent precision divergence, the float-arithmetic
   sibling of the integer-division trap above. **Audit this when
   `select_build` resumes** (Phase 4.2 porting-order item 3, currently
   frozen — see the Consolidation gate below) — it is the only ported
   function known to need it so far, and it hasn't been implemented yet.

### 3.2 High layer: idiomatic API

> **Status: 🔨 narrowed slice done (2026-07-13)** — this section as written
> below describes the full engine-wide `game`/`map`/`veh`/`base`/`path`/
> `rules` API; per M3A's "do not build the full API up front" and a
> deliberate scoping decision this session, only the slice
> `mod_tech_val`/`mod_tech_ai` need was built: `lua/api/faction.lua`
> (`is_human`, `has_treaty`, `climactic_battle`, `mod_wants_to_attack` +
> ID-validated `Faction`/`MFaction` accessors), `lua/api/tech.lua`
> (`has_tech`, `tech_level`, `tech_is_preq`, `mod_tech_avail` + accessors
> for `CTech`/`CFacility`/`CReactor`/`CWeapon`/`CChassis`/`CArmor`/unit
> prototypes, plus `proto_offense_value`/`proto_defense_value`/`proto_speed`
> re-porting `UNIT`'s three inline methods dropped by field-only cdef
> generation), `lua/api/map.lua` (`bad_reg` + a `Continent` accessor,
> deliberately minimal — one function). `LuaHostApi` bumped to
> `api_version=2` with the 9 new entries, all direct function-pointer
> assignments (no trampolines — confirmed `extern "C"` is irrelevant for
> same-TU pointer assignment, only `is_human`'s `bool` return needed its
> own field type rather than a generic `int`, since C++ function-pointer
> types don't implicitly convert). Also added `dofile_once` (`lua/init.lua`)
> — a path-memoized loader closing a fragility flagged in the Phase 3.1
> commit message, now load-bearing since `lua/ffi/types.lua` and
> `lua/ffi/funcs.lua` gained real second/third callers this session.
> Validated in-game: `faction.is_human(1)=false`,
> `tech.get(0).AI_growth=2`, `map.bad_reg(0)=true`. `game`/`veh`/`base`/
> `path`/live-tile access below remain undone — no consumer until
> Phase 4's later porting-order items (social engineering, production,
> movement) need them.

Thin Lua modules over the FFI reads + host API calls, with the semantics of the
helpers already in `veh.h`/`base.h`/`map.h`:

- `game`: iterators `game.vehs()`, `game.bases()`, `game.factions()`,
  `game.turn()`, access to `conf`.
- `map`: `map.tile(x, y)` (with X-axis wrap like `mapsq`), `map.range`,
  `map.iter_near(x, y, r)`, tile flags (`is_fungus`, `items`, `region`...).
- `veh`/`base`: methods mirroring the C++ ones (`veh:triad()`, `veh:speed()`,
  `base:can_build(item)`, ...). Implemented on demand, as the port requires
  (see milestone M3A: build the vertical slice for the pilot first, not the
  whole API up front).
- `path`: wrappers over the retained C++ primitives (`path.find`,
  `path.move_to`, `tilesearch.iterate(...)`, `mapdata`/`mapnodes` reads).
- `rules`: access to the already-parsed `alphax.txt` tables.

Boundary rules:

- **`lua/ai/` may not `require('ffi')`** — enforced by the sandbox (Phase 2B)
  and luacheck. All native access goes through `api/`. Since LuaJIT is now a
  hard dependency, `api/` objects **may** be FFI metatypes crossing into `ai/`
  when measurement favors it — the prohibition is on `ai/` touching the FFI
  mechanism, not on the representation `api/` chooses. This keeps `ai/`
  readable and auditable without paying an abstraction tax that no longer buys
  anything.
- **Determinism:** decisions must never depend on hash-table iteration order
  (`pairs`). The API provides index-ordered iterators; reviewed in every ported
  module.

**Done when:** from inside the game, a script can list a faction's bases and
units, read tiles, call `path.find` via the host API and get the same values
the C++ `debug.txt` reports. All layout asserts pass; `api_version` handshake
works; a stale ID passed to a wrapper is rejected, not dereferenced.

---

## Phase 4 — Incremental AI port

### 4.1 Hook mechanism, taxonomy and contract

Every hooked C++ entry point is classified into one of three classes. The class
determines the hook contract, the fallback rule and the shadow-mode strategy
(Phase 5.1). Classification is recorded per function in `docs/LUA_PORTING.md`.

**Class 1 — Pure query.** No state modification beyond RNG consumption
(e.g. `mod_tech_val`, `facility_score`, `unit_score`). Contract: Lua returns a
value; C++ uses it. Fallback on error: always safe.

**Class 2 — Transactional decision.** Produces a decision plus a bounded,
identifiable state delta (e.g. `select_build` outcomes, plan updates).
Contract: **propose-then-commit** — Lua returns a proposal table and performs
**no** mutation itself:

```lua
return { handled = true, build_item = item_id }
```

C++ validates the proposal (range checks, legality) and applies it. Fallback on
error: safe, because nothing was mutated before the error.

**Class 3 — Command/effect.** Issues orders, moves units, creates goals —
broad or irreversible effects mid-execution (e.g. `combat_move`,
`mod_enemy_veh`). Contract: Lua calls host-API mutators as it executes.
**Fallback rule: once the first mutation has been issued, there is no fallback
to C++ for that invocation** — falling back over a partially modified state is
worse than completing or skipping. The hook wrapper tracks "mutations issued";
on error after the first mutation it finishes the unit safely (e.g. `veh_skip`
via host API) and logs, rather than re-running the C++ body. Errors *before*
the first mutation fall back normally.

Seam shape in C++ (unchanged in spirit, 2–3 lines per function):

```cpp
int select_build(int base_id) {
    int value;
    if (lua_ai_hook("select_build", &value, base_id)) {
        return value; // proposed by Lua, validated and applied by this side
    }
    // ... original C++ code untouched (fallback / reference)
}
```

Implementation notes:

- `lua_ai_hook` returns `false` if `lua_ai=0`, if the hook is unregistered, or
  if the pcall failed under the class's fallback rules.
- **Hook resolution via the Lua registry:** hooks are resolved once at (re)load
  into registry references — no per-call string lookup. In movement dispatch
  this runs per unit per turn; the difference matters.
- Avoid a zoo of `lua_ai_hook_i/_ii/_b/_v` variants: a small set of typed
  argument/result descriptors (or per-domain structs) keeps call sites uniform.
- Shared state during the transition: `plans[]` (AIPlans), `mapdata` (PMTable)
  and `mapnodes` remain canonical in C++, read by Lua via FFI — both sides see
  the same state, so half of a domain can be ported without desync.

### 4.2 Porting order (lowest risk to highest)

> **Item 1 (research pilot) status: 🔨 in-game verified (2026-07-13), formal
> validation still open.** `mod_tech_val`/`mod_tech_ai` ported 1:1 to
> `lua/ai/tech.lua`, registered as Class 1 hooks via `lua/ai/init.lua` and
> `luaai.cpp`'s registry (`register_hooks()`, `lua_ai_hook()`,
> `LuaHostApi` bumped to `api_version=3` with `revised_tech_cost`/
> `tech_balance_enabled` added). Both hooks in `src/tech.cpp` now carry
> **temporary** dual-run instrumentation: every call runs both Lua and C++,
> C++'s value still governs, and a mismatch is logged
> (`lua/cpp mod_tech_val mismatch: ...` / `lua/cpp mod_tech_ai mismatch: ...`)
> — this is a manual stand-in for Phase 5.1's shadow mode, not shadow mode
> itself. `mod_tech_ai` additionally consumes the map RNG (`random_get`,
> once per available tech via Lua's `rand.map()`); its dual-run follows the
> plan's 5.1 Class-1 shadow procedure precisely — snapshot `random_state()`
> before the Lua run, `random_reseed()` back to it before the real C++ run —
> so comparing both sides doesn't burn the RNG stream twice or desync it.
> Verified via `lua.log`/`debug.txt` across two Wine play sessions (the
> second one after adding `mod_tech_ai`'s comparison): both sessions show
> `register_hooks: 2 hook(s) registered`, both hooks logged
> `invoked and handled` (confirming they actually ran, not just registered),
> **zero `mismatch` lines in either session**, no
> `error in 'mod_tech_val'`/`'mod_tech_ai'` lines. **Not yet done:**
> multi-session/multi-faction coverage beyond these two sessions (many
> `tech_val` branches — `climactic_battle`, `tech_balance_enabled`,
> weapon-preq loops — may be under-exercised so far); the real Phase 5.1/
> 5.2 machinery (golden traces, `lua_shadow` flag) this instrumentation
> stands in for; removing the temporary dual-run code once formal
> validation lands; provenance entries in `docs/LUA_PORTING.md` (Phase 6).

Each item follows the same cycle: port 1:1 → golden traces pass (5.2) → shadow
mode per class (5.1) until divergences reach zero at the applicable level →
enable Lua by default on the branch → next.

1. **Pilot — research AI** (`tech.cpp`: `mod_tech_val` scoring, `mod_tech_ai`;
   ~400 relevant loc). Pure query, small, easy to compare. Validates the whole
   pipeline (hook, FFI reads, host API, RNG, traces, shadow). See status note
   above.
2. **Social engineering** (`faction.cpp`: `mod_social_ai` scoring,
   `mod_wants_to_attack`). Transactional/pure, once per faction per turn.

   > **Status: ✅ in-game verified clean (2026-07-14).** Two Wine play
   > sessions (turns 9-13 and turns 80-89, all 7 AI factions, ~145
   > `mod_social_ai` calls combined, covering both `pop_boom` 0/1 and both
   > `sf=-1`/a real proposed-and-applied social-model change) — zero `lua/cpp
   > mod_social_ai mismatch` lines in either. See `IMPLEMENTATION_DETAILS.md`
   > 4.5 for the numbers. `mod_wants_to_attack` (item 2b) also in-game
   > verified clean now (123 calls, turns 90-92, zero mismatches, both
   > outcomes exercised) — see `IMPLEMENTATION_DETAILS.md` 4.6. Porting-order
   > item 2 and its 2b follow-up are both done in this sense; temporary
   > dual-run instrumentation still in place pending real Phase 5.1 shadow
   > mode, same as M4/tech.
   > `social_score()` + `mod_social_ai`'s selection loop ported to
   > `lua/ai/social.lua`, registered as a Class-2-shaped `mod_social_ai`
   > hook with the same temporary dual-run pattern as item 1 (M4); the
   > `pop_boom`/`want_pop` base-iteration stays in C++ (no `BASE` struct in
   > the FFI yet), passed in as a plain int hook argument. The proposal
   > (category + model choice) is a packed int (`sf*4+sm2`, or `-1` for "no
   > change"), so `lua_ai_hook`'s existing int-args/int-result signature
   > needed no changes. `mod_wants_to_attack` deferred to follow-up item
   > **2b** (large, self-contained, ~180 loc) — now implemented, see
   > `IMPLEMENTATION_DETAILS.md` 4.6. `LuaHostApi`
   > bumped to `api_version=4` with 11 new entries (`social_calc`,
   > `society_avail`, `social_upheaval`, `has_project`, `has_free_facility`,
   > `has_aircraft`, `mineral_factor`, `un_charter`, `defense_modifier`,
   > `keep_fungus`, `social_ai_bias`). `tools/gen_ffi.cpp` gained a 2D-array
   > `FieldShape` specialization (`Faction::social_psych` is `int32_t[8][9]`,
   > flattened to a `[72]` cdef field, indexed `i*9+j` from Lua). Full
   > detail, including corrections to the original scope found while
   > implementing (a few fields/enums it missed, a few it over-listed), is
   > in `IMPLEMENTATION_DETAILS.md` 4.5 — read that before touching this
   > again. Both build presets compile clean; every touched Lua file passed
   > a native-`luajit` syntax check.
3. **Production and plans** (`build.cpp` + `plan.cpp`): `governor_priorities`,
   `facility_score`, `unit_score`/`find_proto`, `select_colony`/`select_combat`,
   `select_build`, `find_project`, `mod_base_hurry`, then `plans_upkeep`,
   `design_units`, `former_plans`. The heart of the single-player challenge.

   > **Status: first and second slices ✅ in-game verified clean
   > (2026-07-14).** First slice (`unit_score`+`find_proto`,
   > `lua/ai/build.lua`): 769 calls over turns 93-100, all 7 AI factions,
   > zero mismatches — `IMPLEMENTATION_DETAILS.md` 4.7. Second slice
   > (`select_colony`+`select_combat`, same file): both hooked;
   > `select_build` itself was surveyed and found too large (454 loc,
   > ~45-item priority table, a `std::priority_queue`, ~57 distinct helper
   > calls) to scope in one pass, so these two internal helpers were
   > ported first instead, extending the helper library `select_build` will
   > eventually need. First in-game run caught a real bug fast (`BASE.x`/
   > `BASE.y` missing from the FFI since 4.7 — nothing had needed base
   > coordinates until now); fixed, re-verified clean over turns 101-105,
   > zero mismatches. Also switched `lua_strict` to `0` for iterative
   > testing (a single hook error no longer kills the whole session's Lua
   > AI). See `IMPLEMENTATION_DETAILS.md` 4.8. Third slice
   > (`governor_priorities`+`facility_score`): implemented as plain
   > unhooked library functions — neither fits `lua_ai_hook`'s int-in/
   > int-out contract (one takes a struct input, the other returns a
   > struct via out-param), so there's no dual-run seam possible for
   > these two; validated by inspection only, see `IMPLEMENTATION_
   > DETAILS.md` 4.9. **`select_build` itself: fully scoped**
   > (`IMPLEMENTATION_DETAILS.md` 4.10 has the complete dependency catalog —
   > full 467-loc read: `VEH`'s first-ever exposure, ~50 new
   > fields/enums/wrappers, a second `MAP`-touching loop needing the same
   > opaque-wrapper treatment as 4.8's, confirmation that the
   > `std::priority_queue` output mechanism needs no real port — a
   > running-best tracker suffices, the float-arithmetic block that's a
   > first for this project, and a recommended 4-stage implementation
   > order), **step 1 of that 4-stage order implemented (2026-07-14),
   > in-game verification pending.** `VEH` exposed in the FFI (first time,
   > `x`/`y`/`unit_id`/`faction_id`/`order`/`home_base_id`) plus the 8 new
   > `tech.lua` UNIT-level predicates and the new `lua/api/veh.lua` module
   > it backs; `select_build`'s own vehicle-count loop
   > (`build.cpp:913-955`) ported to `lua/ai/build.lua`'s
   > `vehicle_counts_check`, called from a temporary (non-hook) seam in
   > `select_build` that just logs its counters for manual comparison
   > against the C++ `debug("select_build ...")` line a few statements
   > later — `select_build` itself is still not hooked. `LuaHostApi` bumped
   > to `api_version=8` (`vehs_ptr`, mirroring `bases_ptr`). Both presets
   > build clean, every touched Lua file passed a native-`luajit`
   > `loadfile` syntax check, and the generated `VEH` offsets were hand
   > cross-checked against `engine_veh.h`'s field declarations (exact
   > match). **Not yet done: the actual in-game run** — needs a manual Wine
   > play session comparing `lua.log`'s `vehicle_counts base:N def:...
   > frm:... prb:...` lines against `debug.txt`'s `select_build ... def:
   > ... frm: ... prb: ...` lines for the same base/turn. See
   > `IMPLEMENTATION_DETAILS.md` 4.10.10 for the full session record and
   > exactly what to check when resuming. The rest of the 4-stage order
   > (push_item + running-best tracker, the `build_order` scoring loop
   > itself, then wiring the real hook) remains unimplemented, and
   > `find_project`/`mod_base_hurry`/`plans_upkeep`/`design_units`/
   > `former_plans` remain unsurveyed.
4. **Movement** (`move.cpp` + dispatch in `veh_turn.cpp` + `goal.cpp`): start
   with the isolated movers (`artifact_move` → `nuclear_move` → `crawler_move` →
   `colony_move` → `former_move` → `trans_move`) and finish with `combat_move` +
   `move_upkeep` + invasion plans. Class 3 territory: largest, most
   performance-sensitive, ported last with the C++ baseline already measured.
5. **AI probe decisions** (`probe.cpp`, partial — target/action choices only;
   resolution mechanics stay in C++).

### 4.3 What stays in C++ (primitives exposed via host API)

- All of `path.cpp` (A*, `Path::find`, low-level tactical movement).
- `TileSearch` and the `PMTable`/`mapdata` fill in `move_upkeep` (O(map) sweeps
  per turn). Lua orchestrates (*what* to do), C++ computes (*how*). If LuaJIT
  later proves fast enough, porting these is a measured decision, not a guess.
- Combat itself (`veh_combat.cpp`), engine mechanics, everything UI/render.

### 4.4 Conventions and upstream drift detection

- One module per domain (`ai/tech.lua`, `ai/social.lua`, `ai/build.lua`,
  `ai/move.lua`, `ai/plan.lua`), registering hooks in a central `ai.hooks`
  table read by `luaai.cpp` at (re)load.
- **Port provenance metadata**, machine-readable, in every ported function:

```lua
port.source = {
    file = "src/tech.cpp",
    func = "mod_tech_val",
    upstream_commit = "15418b2…",
}
```

- **Drift report** (`tools/port_drift.py`): extracts the body of each ported
  C++ function at the current upstream revision, computes a normalized hash
  (whitespace/comment-insensitive), and compares against the hash recorded at
  `upstream_commit`. Output: the list of ported functions whose C++ bodies
  changed and therefore need review. This catches semantic drift that clean
  Git merges hide — the real long-term maintenance cost of the fork.
- `luacheck` in CI (accidental globals) plus the integer-expression lint from
  Phase 3.1.

**Done when (per module):** golden traces pass; shadow mode clean at the
class-appropriate level over N autoplay turns on at least 3 distinct saves + 1
new game with a fixed seed; no noticeable turn-time regression; provenance
metadata present; drift report clean at the pinned upstream commit.

---

## Consolidation gate (2026-07-14)

**Porting is frozen** — no more of `select_build` (stages 2-4), movement, or
any later porting-order item — until the items below land, in this order.
Five domains (research, social engineering, war decisions, and two
production/plans slices) are ported and "in-game verified clean" in the
session-record sense, but every one of them is validated only by temporary
dual-run instrumentation over manual play sessions on a single game
trajectory. None has met its module-level "Done when" (golden traces, real
shadow mode, the 3-save + 1-new-game matrix). Accumulating a sixth and
seventh ported-but-not-formally-validated domain on top of that debt makes
the eventual validation pass strictly harder to attribute divergences in,
for no benefit — this gate exists to pay that debt down before it grows
further.

a. **Autoplay harness finished.** `autoplay_demote_human` retested (Phase
   5.3.1 left this as "rebuilt and redeployed; retest pending" after fixing
   the human-faction-exclusion bug), plus one real unattended all-AI run.
   Termination is always an **external kill by the harness script**, never
   an in-game exit: the per-turn state hash (below) gives an
   externally-observable progress signal, and the existing
   `autosave_interval=1` already makes every turn's state durable, so a
   kill from outside loses nothing needed for diagnosis or resumption. The
   previously deferred `autoplay_turns` internal-exit idea (auto-save-and-
   `ControlTurnA`/`ControlTurnB`-exit from inside `mod_turn_upkeep`,
   Phase 5.3) is **dropped** — external kill supersedes it, and it was
   already flagged as poorly-understood.

   > **Status (2026-07-15): retested for real, 4/4 clean runs, mostly
   > done.** `tools/autoplay_run.sh` (`--no-xvfb`, real desktop — Xvfb
   > itself still doesn't work on the dev machine, see
   > `IMPLEMENTATION_DETAILS.md` 5.3.2's KNOWN GAP #2) ran 3 distinct new
   > games plus a 4th with a recorded fixed seed (**15373264**), all
   > `COMPLETED`, zero Lua errors, `state_hash` sequential throughout. Two
   > real bugs found and fixed along the way: the watchdog was checking
   > the wrong PID (`thinker.exe`'s launcher exits by design after
   > spawning `terranx.exe`, not a crash — was misclassified as `CRASH`
   > every run), and `autoplay_try_end_turn` (5.3.1, marked experimental)
   > was **never once invoked** because the timer callback that calls it
   > is normally only installed under an unrelated `smooth_scrolling`
   > option, off by default — fixed, confirmed live: turns now advance
   > with no manual End Turn. The six-primitive dialog-bypass catalog
   > (5.3.1) was also found incomplete and corrected to nine (`X_pop`/
   > `X_pop_2`/`X_pops` added — see `IMPLEMENTATION_DETAILS.md` 5.3.3 for
   > why the original grep missed them).
   >
   > **Determinism (the fixed-seed run's actual purpose) attempted and
   > only partially achieved — see `IMPLEMENTATION_DETAILS.md` 5.3.4.** A
   > real gap surfaced along the way: the mod's own RNG
   > (`random_reseed`/`map_rand`) was seeded from `GetTickCount()` on
   > every process launch, independent of the save file — fixed with a
   > new `fixed_rng_seed` option, confirmed working (two separate launches
   > loading the same save now produce byte-identical `random_reseed`
   > values and an identical turn-1 state hash). But turn 2 still diverges
   > even with the seed pinned and the human's turn-1 actions deliberately
   > reproduced — traced to single-player pod-opening drawing from the
   > *main* sequential RNG stream (a `*MultiplayerActive`-only reseed
   > exists but doesn't apply here), so its outcome depends on everything
   > the other six AI-controlled factions already drew that turn, outside
   > the human's control. Root cause not found — candidate is
   > non-deterministic iteration somewhere in that turn-1 AI processing,
   > not confirmed. **Correction (external review, 2026-07-15): this is
   > NOT covered by the plan's "bit-exact only where achievable" framing**
   > — that framing is about Lua-vs-C++ tolerance (different
   > implementations of the same logic); this is the **same binary, same
   > save, same pinned seed** diverging across two launches. That's ambient
   > nondeterminism, not an equivalence-level question, and it makes gate
   > item (d)'s systemic comparison (state hashes at equivalence levels
   > 3-5) mathematically meaningless until fixed — you cannot tell port
   > divergence from background noise. Diagnostics to root-cause it
   > landed this session (5.3.5), then actually run: found and fixed a
   > real gap (`game_rand`, the engine's own RNG, was never pinned by
   > `fixed_rng_seed` — fixed), pushing the divergence from turn 2 to
   > turn 3 — progress, not a resolution.
   >
   > **Closed by decision (2026-07-16), not resolved — see
   > `IMPLEMENTATION_DETAILS.md` 5.3.6's closing note.** The full-trajectory
   > determinism chase this whole sub-section describes is dropped: item
   > (d)'s acceptance criterion no longer depends on it (changed to real
   > shadow mode, item b), and chasing engine-internal nondeterminism
   > further is out of this project's charter (engine debugging, not
   > AI porting). What the work permanently bought: `fixed_rng_seed` +
   > post-load `game_rand_restore()` give **single-turn** reproducibility
   > (confirmed: turn 1 *and* turn 2 byte-identical across launches before
   > this fix pushed the residual divergence to turn 3) — exactly the
   > prerequisite M6 (movement) will need for its own windowed determinism
   > method (reload the same autosave twice, compare one turn — not a full
   > trajectory). Not wasted, re-purposed. The turn-3 mystery itself is
   > parked, not forgotten — 5.3.6 has the resume point.
   >
   > **Honest framing (external review, 2026-07-15): item (a)'s own
   > definition — "one real unattended all-AI run" — has still never
   > happened.** All four rounds had the user manually clicking through:
   > the New Game screen every time, one manual End Turn per Load (before
   > the blink-timer fix, and even after it for the very first turn after
   > a load), and — every session — recurring clicks for tech-discovery
   > announcements and (before `minimal_popups`) secret-project
   > completion. What's actually done is the **mechanism**: dialog bypass
   > (nine primitives), demote-human, auto-End-Turn, the state-hash
   > harness, PID tracking, all confirmed working in combination over
   > several hours of AI-vs-AI play. What's **not** done is a run with
   > zero human interaction from launch to completion. Two concrete,
   > named sub-items close that gap, both **deferred to next session**:
   >
   > - **Harness menu bootstrap.** No mechanism exists to reach an
   >   in-progress game without a human clicking New Game (or Load) at
   >   least once. `tools/autoplay_run.sh --save FILE` forwards a save
   >   path as a bare `wine` argument on the chance the engine honors it —
   >   **presumed dead**, not just unverified: `cmd_parse()`
   >   (`src/main.cpp`) only recognizes four flags
   >   (`-smac`/`-native`/`-screen`/`-windowed`), nothing save-related, so
   >   there's no reason to expect a bare path argument does anything.
   >   Needs either a real load-by-path mechanism added to Thinker, or
   >   input automation (`xdotool`-style) against the New Game screen —
   >   not designed yet.
   > - **Tech-discovery popup.** Confirmed live as the actual recurring
   >   blocker in an otherwise-running all-AI session (not tech-discovery
   >   "eventually", but every few turns) — the demoted faction is still
   >   `MapWin->cOwner` after `autoplay_demote_human()` runs (that call
   >   only clears the human *bit*, not this pointer), so `tech_achieved`
   >   still treats it as the UI's owner faction for announcement
   >   purposes. A preference-flag experiment (some `GamePreferences`/
   >   `GameMorePreferences` bit might suppress the announcement, same
   >   family as 5.3.1's `MPREF_AUTO_ALWAYS_INSPECT_MONOLITH` fix) is the
   >   likely next move but **not attempted this session** — explicitly
   >   out of scope, see 5.3.5.
   >
   > **Xvfb (KNOWN GAP #2) demoted from blocking to nice-to-have.**
   > Re-attempted this session (5.3.5): higher screen depth/resolution,
   > the GDI renderer, and disabling PRACX's `ddraw.dll` override, each
   > alone and combined — none fixed it, still dies at the identical point
   > every time, ruling out the original DirectDraw/PRACX hypothesis (a
   > plain `wine notepad` survives fine under the same Xvfb, so it isn't
   > Xvfb-vs-wine in general either). Given `--no-xvfb` on the real desktop
   > already satisfies every run in this gate's validation matrix, and
   > headless operation only starts to matter for *parallel* runs (a later
   > concern, not this gate), Xvfb is no longer worth blocking on — pick
   > it back up only if/when parallelizing validation runs becomes the
   > actual bottleneck.
   >
   > **Also still open, none blocking:** secret-project completion down to
   > one click (was two) via `minimal_popups`, not fully solved. The
   > turn-2+ RNG divergence is **closed by decision (2026-07-16)** — no
   > longer tracked as blocking anything; see item (d) and
   > `IMPLEMENTATION_DETAILS.md` 5.3.6.

b. **Dual-run instrumentation promoted to real shadow mode.** Replace the
   hand-rolled per-hook mismatch-logging blocks (`src/tech.cpp`,
   `src/faction.cpp` x2, `src/build.cpp` x3) with the actual
   `lua_shadow`-gated generic wrapper from Phase 5.1, instead of deleting
   the temporary code once each is separately declared "done" — one
   generic mechanism, applied everywhere at once. Do the **typed
   hook-descriptor refactor (Phase 4.1)** in the same pass: 4.9 already
   proved the int-args-in/int-result-out contract is too narrow
   (`facility_score`/`governor_priorities` couldn't be hooked at all,
   and 4.10's vehicle-count check needed a 12-counter side-channel log
   instead of a real comparison) — fix the contract once, here, rather
   than carrying two hook-shape generations forward into shadow mode.

   > **Status (2026-07-16): done, not yet exercised live.**
   > `lua_ai_shadow_call`/`lua_ai_shadow_check` (`src/luaai.h`/`.cpp`) is
   > the one generic mechanism, gated on `conf.lua_shadow`
   > (`lua_shadow=0`: returns immediately, no Lua call, no RNG state
   > touched — zero overhead beyond the flag check). Snapshots
   > `game_rand_state()`/`random_state()` before the Lua call, restores
   > both after (the `game_rand_restore()` pair 5.3.6 added), and records
   > the Phase 5.3.5 draw-count deltas for the log line — implements
   > Plan 5.1's Class 1/2 procedure exactly. All seven existing hooks
   > (`mod_tech_val`/`mod_tech_ai`/`mod_social_ai`/`mod_wants_to_attack`/
   > `find_proto`/`select_colony`/`select_combat`) migrated off their
   > hand-rolled blocks onto it. Typed-descriptor refactor:
   > `lua_ai_hook` gained an `out_count` parameter (1 = single number,
   > unchanged for every existing hook; >1 = a 1-indexed Lua table) —
   > closes the 4.9 gap: `facility_score`/`governor_priorities` are now
   > hooked too (`src/plan.cpp`), via thin marshalling adapters
   > (`lua/ai/build.lua`) that flatten/unflatten `WItem`'s 5 fields in
   > its declared order, since the underlying Lua implementations keep
   > their natural named-table interface for any future internal caller.
   > Both presets rebuild clean; Lua files pass `luajit loadfile`
   > syntax checks. **Exercised live the same day
   > (`IMPLEMENTATION_DETAILS.md` 5.1.2):** `register_hooks: 11 hook(s)
   > registered`, zero `lua/cpp ... mismatch` lines over a full
   > `--lua-shadow` autoplay run. Found and fixed two real gaps along the
   > way — the harness was silently discarding `lua_shadow=1` (overwrote
   > `thinker.ini` with the shipped `lua_shadow=0` default and never
   > re-forced it, fixed with a new `--lua-shadow` flag), and there was no
   > way to confirm which config flags were actually in effect after the
   > fact (fixed with a `config: lua_ai=.. lua_shadow=.. lua_strict=..
   > autoplay=..` line at Lua runtime init). See 5.1.2 for detail.

c. **Golden traces (Phase 5.2), starting with the two functions currently
   "validated by inspection" only** — `governor_priorities` and
   `facility_score` (`IMPLEMENTATION_DETAILS.md` 4.9) — since they have no
   dual-run seam at all today and are therefore the least-validated code
   in the port so far, not the most.

d. **All five ported domains re-validated on the harness, by REAL shadow
   mode (item b), not by trajectory comparison.**
   **Acceptance criterion changed (2026-07-16, by decision — see
   `IMPLEMENTATION_DETAILS.md` 5.3.6's closing note for the full
   rationale):** zero `lua_shadow=1` divergences, at the class-appropriate
   level, over long autoplay runs on **3+ distinct saves/maps, including
   at least one game where `rule_psi` factions exist** (an
   under-exercised branch class across every dual-run session so far).
   **No longer** "byte-identical `state_hashes.log` across two same-seed
   runs" — that determinism prerequisite is dropped, not deferred (see
   below). Only then formally close M4 and porting-order items 1, 2, 2b,
   and 3-partial (the `find_proto`/`select_colony`/`select_combat`/
   `unit_score`/`facility_score`/`governor_priorities` slice — not the
   still-unfinished `select_build` itself).
   >
   > **Why per-call shadow comparison is the right acceptance test, and
   > trajectory comparison isn't:** shadow mode compares Lua against C++
   > on the *same call, same inputs, same turn* — it needs no
   > cross-launch determinism at all, since both sides run inside the
   > same process invocation. It is strictly stronger evidence of port
   > fidelity than "did two separate processes end up in the same state
   > after N turns", which conflates two different questions (does the
   > port match C++? does the engine reproduce itself?) into one signal
   > that can't tell them apart when it fails — exactly the problem
   > 5.3.4-5.3.6 ran into. Full history of the abandoned chase (turn-2/
   > turn-3 ambient nondeterminism, `fixed_rng_seed`, `game_rand_restore`)
   > is preserved in `IMPLEMENTATION_DETAILS.md` 5.3.4-5.3.6 — closed by
   > decision, not resolved; see there for what to do if it ever matters
   > again (M6).
   >
   > **Progress (2026-07-16):** two data points landed —
   > `IMPLEMENTATION_DETAILS.md` 5.1.2, two full autoplay runs on distinct
   > manually-started games (71 and 70 turns, all 9 hooked functions
   > exercised each time; the second deliberately included a `rule_psi`
   > faction), zero `lua_shadow=1` divergences in either. **2 of the
   > required 3+ saves/maps**, `rule_psi` requirement satisfied; still
   > need at least one more distinct save/map before this item can
   > formally close.

e. **`tools/port_drift.py` plus provenance entries in `docs/LUA_PORTING.md`**
   (Phase 4.4/6) — needed before any upstream merge is even attempted, and
   currently entirely unwritten despite five domains already carrying
   `port.source` metadata that nothing reads yet.

**Resuming after the gate:** `select_build` stages 2-4 pick up exactly
where `IMPLEMENTATION_DETAILS.md` 4.10.9's 4-stage order left off (step 1
done, steps 2-4 open); re-read 4.10's float-arithmetic note (3.7, below)
before touching `Wbase`/`Wthreat`.

---

## Phase 5 — Validation, testing and performance

### 5.1 Shadow mode (per hook class)

`lua_shadow=1` behavior depends on the hook class:

**Class 1 (pure query):** simple compare —

1. Save RNG states (`game_rand_state()`, `random_state()`).
2. Run Lua, capture result, **restore RNGs**.
3. Run C++ (which is what counts for the game).
4. Divergence → log: function, arguments, both results, RNG draws consumed.

Caveat honored: "pure" must be verified, not assumed — a scoring function that
updates a cache is Class 2. Classification review is part of porting each
function.

**Class 2 (transactional):** compare result *and* delta —

1. Snapshot RNG + the identified touched state (bounded by the propose-then-
   commit contract: since Lua only returns a proposal, in practice the Lua side
   has no delta; the comparison is proposal vs. what C++ decides, plus C++'s
   delta as ground truth).
2. Run Lua → capture proposal → restore RNG.
3. Run C++ → capture decision and delta.
4. Compare proposal vs decision; log divergences with the state fingerprint.

**Class 3 (command/effect):** never run both sides.

- Shadow-compare only the extracted **pure scoring functions** inside the
  domain (these are ported as Class 1 internally).
- Log a **decision trace** (unit, considered options, scores, chosen action)
  from both implementations in *separate runs* and diff.
- Whole-system fidelity comes from the determinism harness (5.3) toggling
  `lua_ai` between runs.

### 5.2 Golden traces first, mocks second

Tests outside the game must be anchored in real engine behavior, not in a mock
that can only confirm the port matches the mock. Priority order:

1. **Golden traces:** the C++ side (debug build) logs, per instrumented
   function, a JSON fixture:

```json
{
  "function": "mod_tech_val",
  "args": {"tech_id": 42, "faction_id": 3, "flag": 0},
  "observed_state": {"...": "the fields the function actually read"},
  "rng_before": 123, "rng_after": 456,
  "result": 87
}
```

2. **Replay runner:** Arch's native `luajit` (`pacman -S luajit`) loads
   fixtures, injects `observed_state` through a fixture-backed `api/`
   implementation, runs the ported function, compares result and RNG
   consumption. Runs in CI.
3. **Synthetic mocks** afterwards, to expand coverage into corner cases the
   traces don't reach (extreme values, empty maps, missing prerequisites).

### 5.3 Determinism and regression — graduated equivalence

> **Autoplay spike status: ✅ dialog-bypass mechanism implemented
> (2026-07-14), in-game verification pending.** Motivation: validating the
> social-engineering port (4.2 item 2) needs many turns/factions, and an
> all-AI game (every faction computer-controlled — a native game feature,
> `is_human()` just reads a setup-time bitmask, `faction.cpp:109`) can run
> unattended *except* that several event/announcement dialogs fire
> unconditionally, not gated on `is_human`, and block the message loop
> waiting for a click. Rather than trying to enumerate every such path up
> front (acknowledged as impossible in general — this is deliberately an
> iterative spike, not a project), a grep across all of `src/` found that
> every popup/dialog call funnels through exactly six raw engine
> primitives: `POP2`, `popp`, `popp_2`, `interlude`, `X_pop_9`,
> `X_pops_18`. New `conf.autoplay` option (0/1, `main.h`/`main.cpp`/
> `docs/thinker.ini`) + new `src/autoplay.cpp`/`.h`: `engine.cpp`'s
> definitions of those six globals now point at thin shims instead of the
> raw addresses (kept as `<name>_engine`) — a 6-line change, zero call
> sites touched, since the redirection happens once at the pointer
> definition, not per caller. When `conf.autoplay` is on, each shim logs
> the call (function + label argument) to `autoplay.log` in the game
> folder and returns a safe default (`0`) instead of opening the real
> modal; when off, it forwards to the real engine function unchanged —
> `autoplay=0` is a no-op by construction. Both build presets compile and
> link clean. **Iteration model, not a finished catalog:** if some path
> still hangs, `autoplay.log`'s last line names exactly which of the six
> primitives and which label was reached right before it — add a
> label-specific case in that one shim (`src/autoplay.cpp`), rebuild,
> retry. Expected to converge quickly given the funnel is this narrow.
> **Caveat (not a bug, a scope limit):** the shims key only on
> `conf.autoplay`, not on `is_human` — if a human faction exists in the
> same session with `autoplay=1`, dialogs meant for that human's own
> choices (diplomacy proposals, the SOCIETY social-engineering picker,
> event notices) are auto-dismissed too, same as AI-facing ones. This
> option is for unattended all-AI sessions only; leave it at the default
> `0` for normal human play. **Deliberately not implemented in this
> pass:** the `autoplay_turns=N` auto-save-and-exit idea below — forcing
> an exit via `ControlTurnA`/`ControlTurnB` outside `end_of_game`'s own
> sequence (which also does `report_score`/`hall_of_fame`/replay
> bookkeeping first) isn't well-understood enough yet to do blind; that
> was a separate ask from the dialog-hang problem this spike actually
> targets, and stopping unattended runs manually is sufficient for now.
> **Not yet done:** an actual unattended all-AI play session confirming
> turns advance without any hang; if one is found, treat it as the next
> iteration of this spike, not a regression.
>
> **Correction found on first test (2026-07-14):** the New Game screen has
> no "0 human players" option — a faction must always be picked to
> control. That faction then kept running with *no* Thinker AI at all
> (not just undismissed popups): `thinker_enabled()` (`faction.cpp:142`)
> separately excludes any human-marked faction from the whole AI stack.
> Fixed with `autoplay_demote_human()` (`src/autoplay.cpp`, called from
> the `mod_turn_upkeep` seam): with `conf.autoplay=1` it clears the picked
> faction's human bit every turn, handing it to Thinker AI like any other
> — see `IMPLEMENTATION_DETAILS.md` 5.3.1 for the mechanism. Rebuilt and
> redeployed; retest pending.

Bit-exact equality is the goal only where it is achievable. Known threats to
exactness even in a faithful port: float/double vs Lua number conversions,
integer division/modulo semantics (mitigated by 3.1's `idiv`/`imod` rule),
C++ overflow/UB present in the original, RNG call order, iteration order.
Therefore equivalence is measured in levels:

1. Same function output (per call).
2. Same state delta (per call).
3. Same state hash at end of phase.
4. Same state hash at end of turn.
5. Same trajectory over N turns.

**"Zero divergences" is required at level 1 for pure scoring and discrete
choices.** For systemic validation, the harness reports the *first level at
which divergence appears* — that localizes the bug instead of announcing "turn
40 differs".

Harness: same seed + same initial save, autoplay N turns (all factions AI;
investigate the debug build's facilities — `test.cpp`/`extra_setup` — and, if
needed, add an `autoplay_turns=N` flag that exits and saves on its own). State
hash (unit positions, bases, tech, energy per faction) extracted by a Lua
script at end of turn. Compare `lua_ai=1` vs `lua_ai=1` (Lua determinism) and
`lua_ai=0` vs `lua_ai=1` (port fidelity, valid while the port is 1:1).
Verbose `debug.txt` diffable between runs.

### 5.4 Performance

- Instrument time per turn phase (upkeep, production, movement) per faction.
  **Measure the C++ baseline before porting movement.**
- Budget: Lua AI turn ≤ 1.5x C++ on huge maps with 7 factions late-game (real
  target: imperceptible).
- Tools: `jit.p` profiler embeddable via script; `jit.v`/`jit.dump` in dev
  builds to check hot loops stay compiled. Specific watch item: **trace aborts
  caused by host-API calls inside hot loops** — the known LuaJIT failure mode
  for this workload. Mitigation if it appears: batch queries, move the loop
  body's data dependencies to FFI reads, or hoist the C call out of the loop.
- `jit.off()` vs `jit.on()` comparison retained as a diagnostic.

### 5.5 Compatibility

- Saves: the port does not change the save format (AI state lives in engine
  structs/`plans[]`). Validate loading vanilla and Thinker C++ saves.
- Multiplayer: **not supported during the porting phase** (see Scope). The RNG
  and determinism rules avoid gratuitous divergence, but no multiplayer
  validation or script-synchronization mechanism is built now.
- Native Windows: community smoke test before any release (Wine is the dev
  environment, not the only target).

---

## Phase 6 — Documentation, packaging and DX

1. `docs/LUA_API.md`: API reference (`game`, `map`, `veh`, `base`, `path`,
   `rules`, `rand`, `log`, `cmath`) + hook lifecycle and classes + project
   rules (RNG, `idiv`/`imod`, no `ffi` in `ai/`, ordered iteration).
2. `docs/LUA_PORTING.md`: C++ function → Lua module map, **hook class per
   function**, port status checklist, provenance/drift workflow, how to use
   shadow mode, golden traces and hot reload.
3. Update the fork's `Technical.md`: Arch build, pinned LuaJIT commit and build
   integration, cdef generator, deploy via Wine.
4. Packaging: include `lua/` in the zips (`tools/makedevzip.sh`,
   `tools/makerelzip.sh`) and in `deploy.sh`.
5. "Hello AI" example: a minimal commented script that overrides a simple
   Class-1 hook — the entry point for other modders and the fork's end product.

---

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| LuaJIT unviable in this process (mingw static, 32-bit, Wine) | Project-fatal by design | Phase 2A spike answers this first, cheaply, with `jit.off()`/`jit.on()` separation; **kill criterion accepted — no fallback interpreter** |
| Wrong cdef layout corrupts reads → wrong decisions | Silent misbehavior | cdefs generated by the build's own compiler; startup asserts on `sizeof`/`alignof`/`offsetof` per field; Lua AI refuses to enable on mismatch |
| Memory corruption from native access | Unrecoverable crash | Reads-only FFI; all writes and calls via ABI-safe `LuaHostApi` wrappers; ID validation at every wrapper; raw pointers confined to `ffi/` |
| Fallback over partially mutated state | Divergent game masked as "handled" | Hook taxonomy: propose-then-commit for Class 2; no-fallback-after-first-mutation for Class 3 |
| Loader-lock issues at init | Deadlock/UB at startup | Lua VM initialized lazily / post-init, never in `DllMain` proper |
| Integer semantics (div/mod, overflow) | Silent scoring divergence | `idiv`/`imod` mandatory in `ai/`; bare `/`/`%` banned on integers; `bit` for masks; `bit.tobit` where C++ relies on wrap |
| Thinker upstream semantic drift | Lua port silently stale after clean merges | Provenance metadata + normalized body-hash drift report per ported function |
| Movement performance in Lua | Slow late-game turns | Pathfinding/PMTable stay in C++; boundary crossings minimized in hot loops; C++ baseline measured first; movement ported last; profiler + trace-abort monitoring |
| Silent behavioral divergence | "Different" AI unnoticed | Golden traces; per-class shadow mode; graduated equivalence levels with first-divergence localization; fixed-seed harness |
| RNG consumed differently | Broken determinism/replays | `rand.*` mandatory, `math.random` raises; snapshot/restore in shadow mode; RNG draw counts compared in traces |

---

## Milestones (reordered)

- **M1 — Local build:** ✅ completed (2026-07-10) — game runs via Wine with a
  DLL compiled on Arch.
- **M2A — Runtime spike (gate):** ✅ completed (2026-07-13). LuaJIT stable
  in-process, init outside loader lock, error contained, JIT off and on
  verified (100+-turn criterion relaxed to manual play — see Phase 2A status).
  *Negative outcome here would have ended the project; outcome was positive.*
- **M2B — Production runtime:** ✅ completed (2026-07-13). Lifecycle,
  sandbox, `lua_strict` policy, dedup logging, safe-point hot reload — see
  Phase 2B status.
- **M3A — Minimal vertical API:** ✅ completed (2026-07-13). Generated
  cdefs + validation, `rand`, `cmath`, the required host-API *functions*
  (`has_tech`/`is_human`/etc.) and `UNIT`'s re-exposed methods
  (`lua/api/faction.lua`, `lua/api/tech.lua`, `lua/api/map.lua` — Phase 3.2
  status), and `log.debug`/`log.ver` (`lua/api/log.lua`, backed by a new
  `host_log_ver` gated on `conf.debug_verbose` — validated in-game on both
  presets: silent by default in `develop`, both lines visible in `debug`
  where `debug_verbose` defaults on). **Do not build the full map/veh/
  base/path API up front** — its ideal shape is discovered by porting.
  Nothing blocks M4 (research pilot) from starting now.
- **M4 — Research pilot:** 🔨 in progress (2026-07-13) — `mod_tech_val`/
  `mod_tech_ai` ported and hooked, both now with dual-run mismatch
  instrumentation, in-game verified clean (zero mismatches) over two manual
  play sessions (see Phase 4.2 item-1 status note). Still open: broader
  autoplay/multi-faction coverage, the real Phase 5.1/5.2 machinery (golden
  traces, `lua_shadow` flag) this temporary dual-run stands in for, and
  removing that temporary instrumentation once formal validation lands. Not
  yet "enabled by default" in the Done-when sense — treat as pilot-proven,
  not closed.
- **M3B — API expansion on demand:** the API grows as each subsequent domain
  requires, with the same generate-validate discipline.
- **M5 — Production/social in Lua:** porting-order modules 2 and 3 active.
- **M6 — Movement in Lua:** port complete; C++ becomes legacy fallback.
- **M7 — Fork release:** docs, zips with `lua/`, "Hello AI" example.
