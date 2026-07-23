# Implementation Plan — Thinker AI in Lua (rev 2)

> This file is normative: what's required, and one-line status per item.
> Tactical, code-grounded reference (scope, field/enum catalogs, resume
> points) lives in `IMPLEMENTATION_DETAILS.md` — read both before starting
> work on a phase. Session-by-session history (bugs found, dead ends,
> decision rationale) lives in `DEVELOPMENT_DIARY.md` — read only when the
> "why" behind a past decision matters, not needed to resume work.

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

**Status: ✅ completed (2026-07-10).** Day-to-day build/deploy/launch commands
are in `CLAUDE.md`. Toolchain quirks, exact versions and Wine setup notes:
`IMPLEMENTATION_DETAILS.md` "Phases 0–1".

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

**Status: ✅ completed (2026-07-13).** LuaJIT confirmed stable in-process
under mingw static-link + Wine; checklist items 1–7 and 9 verified, item 8
(100+ autoplayed turns) relaxed to manual play — no negative (project-ending)
outcome. Details and exact verification evidence:
`IMPLEMENTATION_DETAILS.md` 2.4.

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

**Status: ✅ completed (2026-07-13).** `src/luaai.cpp/.h` implements the
production lifecycle below (config options, sandboxing, error policy, dedup
logging, safe-point hot reload); in-game validated (contained/deduplicated
error, `lua_strict=1` session-disable). Implementation detail and what wasn't
separately exercised: `IMPLEMENTATION_DETAILS.md` 2.5–2.8.
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

**Status: ✅ completed (2026-07-13).** `tools/gen_ffi.cpp` generates
`lua/ffi/types.lua` (cdefs + validation table) from the real engine headers,
compiler-verified field types (caught a real `int16_t`/`int32_t` mismatch
before runtime). Startup validation asserts every `sizeof`/`alignof`/
`offsetof`. `LuaHostApi`/`cmath`/`rand` scoped to the tech-AI pilot per M3A,
validated in-game. Full implementation notes (including a real LuaJIT `ffi`
sandboxing quirk found along the way): `IMPLEMENTATION_DETAILS.md` 3.1–3.5.

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

**Status: 🔨 built on demand, per module, as each porting-order item needs
it** (started 2026-07-13, per M3A's "do not build the full API up front").
The full engine-wide `game`/`map`/`veh`/`base`/`path`/`rules` API described
below is the target shape; actual coverage tracks the porting order (Phase
4.2) and lags intentionally. Current coverage and file-level detail:
`IMPLEMENTATION_DETAILS.md` 3.6 and the per-module sections under Phase 4.2.

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

Each item follows the same cycle: port 1:1 → golden traces pass (5.2) → shadow
mode per class (5.1) until divergences reach zero at the applicable level →
enable Lua by default on the branch → next.

1. **Pilot — research AI** (`tech.cpp`: `mod_tech_val` scoring, `mod_tech_ai`;
   ~400 relevant loc). Pure query, small, easy to compare. Validates the whole
   pipeline (hook, FFI reads, host API, RNG, traces, shadow).

   **Status: 🔨 pilot-proven (2026-07-13), zero mismatches over two manual
   sessions; not yet formally closed** (real Phase 5.1/5.2 machinery —
   golden traces, `lua_shadow` — still stood in for by temporary dual-run
   instrumentation at that point). Superseded by the Consolidation gate
   below, which closes this formally. Detail: `IMPLEMENTATION_DETAILS.md`
   4.2's seam table and Phase 5 sections.
2. **Social engineering** (`faction.cpp`: `mod_social_ai` scoring,
   `mod_wants_to_attack`). Transactional/pure, once per faction per turn.

   **Status: ✅ in-game verified clean (2026-07-14)**, zero mismatches
   across ~145 `mod_social_ai` calls and 123 `mod_wants_to_attack` calls
   (item 2b). `LuaHostApi` bumped to `api_version=4`. Formally closed by the
   Consolidation gate below. Detail: `IMPLEMENTATION_DETAILS.md` 4.5–4.6.
3. **Production and plans** (`build.cpp` + `plan.cpp`): `governor_priorities`,
   `facility_score`, `unit_score`/`find_proto`, `select_colony`/`select_combat`,
   `select_build`, `find_project`, `mod_base_hurry`, then `plans_upkeep`,
   `design_units`, `former_plans`. The heart of the single-player challenge.

   **Status: 🔨 in progress.** `unit_score`/`find_proto`,
   `select_colony`/`select_combat`, `governor_priorities`/`facility_score`
   are ✅ closed by the Consolidation gate below (`IMPLEMENTATION_DETAILS.md`
   4.7–4.9). `select_build` itself: steps 1–2 done; step 3's
   `build_order[]` catalog is **fully ported** — all 38 facility branches
   and all 9 unit-type branches have real Lua implementations
   (`IMPLEMENTATION_DETAILS.md` 4.10). Live-exercise evidence: 33/38
   facilities and 8/9 unit branches confirmed with 0 mismatches; 5
   facilities (late-tier prereq tech: `FAC_ROBOTIC_ASSEMBLY_PLANT`/
   `FAC_NANOREPLICATOR`/`FAC_QUANTUM_CONVERTER`/`FAC_PARADISE_GARDEN`/
   `FAC_PSI_GATE`) and `Satellites` remain unconfirmed — not known
   defects, deprioritized by explicit user direction (2026-07-20),
   revisit opportunistically rather than as scheduled work.
   `FormerUnit`'s dependency (`select_item`, ~472 loc) was deliberately
   wrapped as an opaque host call (`former_tile_tally`) instead of
   ported — its return value is only ever used as a `>= 0` eligibility
   check within this branch; the real port is deferred to Movement's
   `former_move`, where its terraform-choice value actually matters
   (`IMPLEMENTATION_DETAILS.md` 4.10.15–4.10.30). **Step 4 (wiring the
   real hook) is ✅ done and live-verified**: `select_build` is now a
   genuine Class 2 hook via `lua_ai_hook` — the first hook in the whole
   project whose return value actually drives the game rather than only
   feeding a shadow-mode comparison log. A 60-turn `--lua-shadow`
   autoplay run confirmed it: 698 real `select_build` calls across all
   7 factions, 100% handled by the Lua hook (0 fallback-path debug
   lines), 0 errors, 0 mismatches anywhere (`IMPLEMENTATION_DETAILS.md`
   4.10.31). `select_build` itself is fully closed. `mod_base_hurry`/
   `plans_upkeep`/`design_units`/`former_plans` remain unsurveyed.
4. **Movement** (`move.cpp` + dispatch in `veh_turn.cpp` + `goal.cpp`): start
   with the isolated movers (`artifact_move` → `crawler_move` →
   `colony_move` → `former_move` → `trans_move`), then `combat_move` +
   `move_upkeep` + invasion plans, and finish with `nuclear_move` last —
   reordered by user direction (2026-07-21) since it turned out closer
   in weight to `find_project`/`select_build` than an isolated mover, so
   its complexity shouldn't block the rest of the phase. Class 3
   territory: largest, most performance-sensitive, ported last with the
   C++ baseline already measured.

   **Status: 🔨 stages 0-6 done and live-verified (`artifact_move`
   through `combat_move`); only `nuclear_move` (stage 7) remains for
   Movement to be complete.** The `route_score`/`search_route` pending
   item (below) is now fully resolved and closed
   (2026-07-22) — sub-stage A (`route_score` + its two `Bases[]` scans)
   and sub-stage B (the three `TileSearch` scans, full reassembly, hook
   wiring into `artifact_move`/`colony_move`) both done, build-verified
   and live-verified: 885 real decision lines over an 80-turn run (883
   the ordinary path, 2 the deepest/riskiest new primitive — the
   `TileSearch` parent-chain walk), 0 errors, 0 mismatches; see
   `IMPLEMENTATION_DETAILS.md` 4.12's sub-stage A/B entries (sub-stage
   B's entry also records a real 1:1-fidelity bug found and fixed while
   assembling the full function — a stale-`sq` reuse in the original's
   own artifact-at-home-base baseline, `path.cpp:760` — and a live-
   verification instrumentation gap found and fixed on the first
   attempt: the ordinary success path had no log line at all). **Stage 4
   (`former_move`) is closed (2026-07-22)** — all 4 sub-stages done,
   build-verified, and live-verified clean over two consecutive runs
   (1050 then 1061 real decision lines, 60-61 turns each, 0 mismatches
   in the second), after a live bug hunt across several attempts: two
   missing enum values (`FormerMode`, then `FORMER_NONE`/
   `FORMER_RAISE_LAND`), a genuine native crash (an FFI wrapper called
   with the wrong argument count, `tile_near8`/`tile_neighbor` — a NULL-
   pointer write `pcall` couldn't catch), and a forward-reference bug
   (`escape_move`/`search_base` called before their own definitions,
   caught safely by `pcall` every time but never actually running) —
   see `IMPLEMENTATION_DETAILS.md` 4.13 for the full bug-hunt narrative.
   Stage 5 (`trans_move`) is closed (2026-07-22) — both sub-stages
   done: sub-stage 1 (engine surface + `near_landing`/`make_landing`)
   and sub-stage 2 (`trans_move` itself, its Class 3 hook in
   `veh_turn.cpp`, registration in `lua/ai/init.lua`) —
   `choose_defender`/`battle_priority` (used by `trans_move` for
   invasion-attack decisions) confirmed to belong to `combat_move`'s
   own family (6 call sites total, movement stage 6) and kept opaque,
   respecting the classification `IMPLEMENTATION_DETAILS.md` 4.12
   already made. Build-verified (both C++ presets, all 3 scripted
   sweeps, native `luajit` syntax check) and live-verified clean: no
   crash, 0 errors in `lua.log`, 423 real `trans_move` decision lines
   plus branch outcomes (`trans_patrol`/`trans_invade`/`trans_heals`/
   `trans_scout`/`trans_link`) — see `IMPLEMENTATION_DETAILS.md` 4.14.
   **Stage 6 (`combat_move`, ~726 loc — the largest single function in
   the project) is under way** (2026-07-22): a 6 sub-stage breakdown
   (engine-surface/shared-helpers, `airdrop_move`, then the 726-loc
   dispatcher itself split into 4 reviewable parts following its own
   control-flow phases, hook wiring landing in the last part) — see
   `IMPLEMENTATION_DETAILS.md` 4.15. **Sub-stage A (engine surface +
   13 shared scoring/fact helpers: `cover_score`/`target_priority`/
   `flank_score`/`teleport_score`/`defender_goal`/`veh_base_check`/
   `needlejet_check`/`ally_near_tile`/`stack_search`/`allow_probe`/
   `allow_attack`/`allow_combat`/`allow_conv_missile`) is done and
   build-verified** — narrower than first estimated, since most
   `Vehs[]`/`Bases[]` scans and tile/AIPlans facts already existed
   (`veh.count()/get()`/`base.count()/get()` from `select_build`); all
   13 helpers landed with zero new opaque wrappers of their own, only 6
   new atomic-fact host-API entries (`api_version` 36→37). Not yet
   live-verified (no caller reaches these until later sub-stages wire
   them in). A pre-existing, unrelated `has_pact` truthiness bug (found
   while researching this sub-stage, in already-closed stage 3/stage 5
   code) was fixed at the user's direction and is now **live-verified
   clean** (82-turn `--lua-shadow` autoplay run, both fixed sites —
   `colony_move`'s `skip_owner`, `make_landing`'s neighbor filter —
   genuinely exercised, 0 errors/mismatches across `lua.log`/
   `debug.txt`); detail in `IMPLEMENTATION_DETAILS.md` 4.15. **Sub-stage
   B (`airdrop_move` + its own `allow_airdrop` dependency, both real AI
   judgment, ported directly not opaque) is done and build-verified** —
   5 new opaque host-API entries (`mod_stack_check`/`mod_zoc_move`/
   `has_orbital_drops`/`veh_at`/`map_target_incr`, `api_version` 37→38)
   plus 2 `CRules` fields, 1 enum, 1 hand-transcribed constant; not yet
   live-verified (no caller until `combat_move`'s own hook exists).
   **The original plan to then split `combat_move`'s own 726-loc body
   into 4 sub-stages (C-F) turned out not to work** — the whole function
   shares one `TileSearch` object's cursor state across three separate
   loops before re-initializing it twice more later, which every prior
   mover's single-purpose search pairs never had to deal with; splitting
   the body into independently-committed partial functions would mean
   threading that plus ~15 other shared locals through call boundaries,
   against the plan's own "keep the C++ control flow recognizable" rule.
   **Revised and back on every prior mover's own precedent instead:
   sub-stage C (remaining engine surface — a generic re-initializable
   `TileSearch` iterator, `api_version` 38→39, 19 new entries) is done
   and build-verified. Sub-stage D (`combat_move` itself, whole-function
   assembly + the Class 3 hook in `veh_turn.cpp`) is done and
   build-verified (2026-07-22)** — pure translation of `move.cpp:2931-
   3654`, plus two small engine-surface gaps found only while
   translating (a new `arty_table_range` wrapper folding
   `TableRange[arty_range(...)]` into one call; `combat_search_start`
   gained a `ts_skip` parameter for the final base-search scan's "skip
   pole tiles" case), `api_version` 39→40. Native `luajit` syntax-check
   and a full manual `funcs.*`/`E.*` arity and enum-coverage
   cross-check stand in for live testing, same as sub-stages A-C — **not
   yet live-verified** (no `DISPLAY` in this session); live verification
   is handed off to the maintainer and, once clean, closes sub-stage B's
   still-unexercised `airdrop_move`/`allow_airdrop` together with
   sub-stage D and the whole of movement stage 6. **First live-testing
   attempt found a real crash (2026-07-22)** — a native `assert()` abort
   in `battle_priority`, unrelated to the Lua port itself (`lua.log`/
   `debug.txt` showed zero hook errors up to the crash): `choose_defender`
   could return a same-faction or pact-partner unit as "defender" when
   the target was an enemy-owned base, because `find_defender`
   (`veh_combat.cpp`) scores every unit in a tile's stack with no
   hostility filter at all. **Fixed at the root** — `choose_defender`'s
   `at_war` check is now unconditional, closing the gap for every caller
   (native and Lua alike). **Re-verified live and closed (2026-07-23):**
   a 151-turn `--lua-shadow` autoplay run, 0 crashes, 0 errors/mismatches
   in `lua.log`/`debug.txt`, nearly the entire `combat_move` decision
   surface exercised (`combat_attack` 15591, `combat_defend` 5359,
   `arty_score`/`combat_arty` 3207/560, `combat_probe` 2838, and more).
   Two narrow branches (`combat_change`, `combat_gate`) and sub-stage
   B's `airdrop_move` didn't fire this run — a coverage gap, not a known
   defect, revisit opportunistically. **Movement stage 6 is closed** —
   full detail and rationale in `IMPLEMENTATION_DETAILS.md` 4.15.**
   Stage 3 (`colony_move`, plus its own `escape_score`/
   `search_escape`/`search_base`/`escape_move`/`base_tile_score`
   dependencies) closed 2026-07-22: 613 real decision-trace lines across
   an 80-turn run, 0 errors, 0 fallback, base count climbing 7→142 — see
   `IMPLEMENTATION_DETAILS.md` 4.12. Before starting stage 3, a
   user-directed audit of `move.cpp`/`path.cpp` found the `want_convoy`
   mistake already shipped in stage 1 too: `search_route` (used by
   `artifact_move`) wraps `route_score`, a real scoring formula, opaquely
   — and a whole family of similar `*_score` functions exists across the
   file. `route_score`/`search_route` turned out comparable in size to
   `nuclear_move` (210 loc, 5 scoring loops, deep `TileSearch` path-node
   coupling), so it's deferred to its own stage rather than fixed inline
   (`colony_move` keeps calling the existing, flagged `path.search_route`
   for its one fallback call site until that stage lands); `escape_score`/
   `base_tile_score` (both needed by `colony_move` directly) were smaller
   and came first, folded into stage 3 as planned. See
   `IMPLEMENTATION_DETAILS.md` 4.12 for the full classification. Real
   function sizes read (not
   estimated) and a concrete stage-by-stage breakdown agreed with the
   user — see `IMPLEMENTATION_DETAILS.md` 4.12. Stage 0 (the Class 3
   hook mechanism, `lua_ai_command_hook`) and stage 1 (`artifact_move`,
   the pilot) are done and live-verified: 5 real invocations, all
   handled by Lua, 0 fallback to C++, 0 errors, a coherent multi-turn
   movement trajectory logged. Stage 2 (`crawler_move`) is done and
   live-verified too — after an explicit correction from the user
   (2026-07-21): the first pass had wrapped `want_convoy`'s scoring
   formula opaquely, but crawlers are the game's single biggest economic
   lever and this project's stated priority area, so that formula now
   lives fully in Lua; only the yield calculators and the `TileSearch`
   scan mechanics (Phase 4.3) stay in C++, the latter as a new
   incremental start/next iterator pattern rather than one opaque call.
   730 real decision-trace log lines confirmed across a live run, 0
   errors, all three resource choices firing with plausible scores.
   Native life (fauna/aliens —
   `mod_alien_move`/`mod_alien_fauna`/`mod_do_fungal_towers`,
   `veh_turn.cpp`) is explicitly out of scope, by user decision
   (2026-07-20): not strategic faction AI, revisit later if it ever
   makes sense to. `goal.cpp` is folded into the final stage (consumed
   by faction-level planning, not the per-unit movers).
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

## Consolidation gate (2026-07-14, closed 2026-07-16)

**Was:** porting frozen — no more of `select_build` (stages 2-4), movement,
or any later porting-order item — until items (a)-(e) below landed. Reason:
five ported domains were "in-game verified clean" only by temporary dual-run
instrumentation over manual play, none had met its module-level "Done when"
(golden traces, real shadow mode, a multi-save matrix). Full rationale for
opening the gate: `IMPLEMENTATION_DETAILS.md`'s Phase 5 intro.

**Now: closed.** All five items done; porting resumed (see "Resuming after
the gate" below). Session-by-session history of how each item was reached —
including the abandoned cross-launch determinism chase and the autoplay
harness bug hunts — lives in `DEVELOPMENT_DIARY.md` (2026-07-14 through
2026-07-16 entries) and is cross-referenced from each `IMPLEMENTATION_
DETAILS.md` section below; not repeated here.

a. **Autoplay harness finished** (real unattended all-AI runs, dialog
   bypass, state-hash progress signal, external-kill termination). ✅ done
   in the sense needed for this gate: 4/4 clean `--no-xvfb` runs on the real
   desktop, nine-primitive dialog bypass, auto-End-Turn. **Two sub-items
   explicitly deferred, non-blocking:** a harness menu-bootstrap mechanism
   (no way to reach an in-progress game without one manual New-Game click),
   and the tech-discovery popup (still requires manual clicks — root cause
   identified, fix not attempted). Xvfb itself (headless launch) doesn't
   work on the dev machine; demoted to nice-to-have since `--no-xvfb`
   already covers this gate's validation matrix — only matters once
   parallelizing runs becomes the actual goal. Detail: `IMPLEMENTATION_
   DETAILS.md` 5.3.1–5.3.3, diary entries 2026-07-14/15.
b. **Dual-run instrumentation promoted to real shadow mode**
   (`lua_ai_shadow_call`/`_check`, gated on `conf.lua_shadow`), plus the
   **typed hook-descriptor refactor** (Phase 4.1: `out_count` param,
   closing the gap that left `facility_score`/`governor_priorities`
   unhookable). ✅ done and exercised live: all 9 decision hooks migrated,
   zero mismatches over a full `--lua-shadow` autoplay run. Detail:
   `IMPLEMENTATION_DETAILS.md` 5.1.1–5.1.2.
c. **Golden traces (Phase 5.2), first slice** — `governor_priorities`/
   `facility_score`, the two functions with no dual-run seam before item
   (b). ✅ done: capture side (`src/golden_trace.h`/`.cpp`,
   `conf.golden_trace`) + native-`luajit` replay runner
   (`tools/golden_trace_replay.lua`), verified against a real captured
   corpus — 1265/1265 passed. Complementary to shadow mode: runs offline,
   no Wine/Xvfb, in principle CI-runnable. Extending to more hooks is
   future work. Detail: `IMPLEMENTATION_DETAILS.md` 5.2.1.
d. **All five ported domains re-validated by real shadow mode, not
   trajectory comparison.** ✅ done. **Acceptance criterion changed
   (2026-07-16):** zero `lua_shadow=1` divergences over long autoplay runs
   on 3+ distinct saves/maps including one `rule_psi` game — **no longer**
   "byte-identical `state_hashes.log` across two same-seed runs" (that
   determinism prerequisite is dropped, not deferred; see below). Per-call
   shadow comparison needs no cross-launch determinism at all (both sides
   run in the same process invocation) and is strictly stronger evidence of
   port fidelity than trajectory comparison, which conflates "does the port
   match C++" with "does the engine reproduce itself." Met in full: three
   autoplay runs, three distinct games, one with `rule_psi`, zero
   divergences. Formally closes M4 and porting-order items 1, 2, 2b, and
   3-partial (`find_proto`/`select_colony`/`select_combat`/`unit_score`/
   `facility_score`/`governor_priorities`) — not `select_build` itself.
   Detail: `IMPLEMENTATION_DETAILS.md` 5.1.2, diary 2026-07-15/16 for why
   the cross-launch determinism approach was dropped.
e. **`tools/port_drift.py` + provenance entries in `docs/LUA_PORTING.md`.**
   ✅ done: drift script verified against all three real outcomes (clean,
   drifted, error), `docs/LUA_PORTING.md` written, 11 tracked functions.
   Detail: `IMPLEMENTATION_DETAILS.md` 4.11.

**Resuming after the gate:** `select_build` (Phase 4.2 item 3) is now fully
ported — see item 3's status above for current state and next step.
Design notes worth re-reading before touching this code further:
`IMPLEMENTATION_DETAILS.md` 4.10 (RNG-hazard hook-argument threading,
multi-block facility gating, the `FormerUnit`/`select_item` scope
decision) and 3.7 (float-narrowing rule, `Wbase`/`Wthreat`). Bug hunts and
decision rationale from this stretch of work: `DEVELOPMENT_DIARY.md`,
2026-07-14 through 2026-07-20.

---

## Phase 5 — Validation, testing and performance

> **Current testing reality:** every in-game run referenced below (manual
> play, `--lua-shadow`/`--no-xvfb` autoplay sessions, live verification of
> a newly-ported branch) is performed by the human maintainer, not by an
> agent session. Coding sessions routinely have no `DISPLAY` and cannot
> drive Wine/the game GUI (no autoplay-menu-bootstrap path exists yet —
> Consolidation gate item a's still-open sub-item, `IMPLEMENTATION_
> DETAILS.md` 5.3.1–5.3.3 — and headless Xvfb launch itself doesn't work
> on the dev machine, same section). Until that's solved, a session that
> implements a new branch/hook should build-verify (both presets) and
> native-`luajit` syntax-check it, then say so explicitly and hand off
> live verification rather than claim "live-verified" — see
> `IMPLEMENTATION_DETAILS.md` 4.10.15–4.10.30 for the convention this follows.
>
> **Handoff protocol:** the maintainer runs the game/autoplay session
> themselves and reports back when it's done — the agent does not wait on
> or poll for that. Once told a run is complete, the agent's job is to
> read the results, not take the "it's done" report at face value: check
> `lua.log` (game folder root, `lua/cpp <hook> mismatch: ...` lines,
> `lua_ai_shadow_check`/`src/luaai.cpp:472`) and, on debug builds,
> `debug.txt` (mirrors the same lines, `IMPLEMENTATION_DETAILS.md` 2.6),
> for mismatches on the specific hook(s)/facility branch(es) that session
> just implemented. Report exactly what was found (or that logs weren't
> present where expected), not just "the maintainer confirmed it works."
>
> **Absence of a mismatch line is not, by itself, evidence of
> correctness — confirm the branch was actually exercised too**
> (`IMPLEMENTATION_DETAILS.md` 4.10.20, found 2026-07-17 after several
> earlier sessions' "0 mismatches, confirmed by absence" claims turned
> out to rest on this gap). `lua_shadow`'s per-item shadow call only
> fires if the surrounding C++ loop already decided the item is
> eligible (e.g. `build_order_item_score`'s hook sits behind
> `can_build(base_id, item_id)`, itself gated on the facility's
> prerequisite tech being researched) — an unreached branch and a
> correctly-handled one produce the exact same "no mismatch line"
> output. For hooks with an existing debug-line signal of "this item was
> actually considered" (`build_order_item_score`: grep `debug.txt` for
> `push_item.*<Facility Name>` and require a nonzero count, not just zero
> mismatches), cross-check both. Both `lua.log` and `debug.txt` truncate
> on every launch (`fopen(..., "w")`) — there is no way to retroactively
> audit a past run once a new one starts, so get this right per-run, not
> after the fact. A late-game/high-tech-prereq/high-cost branch may
> simply need a much longer run (100+ turns) or a later save before it is
> ever exercised at all; that is a test-coverage gap to report, not
> something to paper over by treating silence as a pass.
> Revisit this note if/when autoplay gets a real headless or
> agent-drivable path.

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

**Autoplay harness status: ✅ implemented and validated** — dialog-bypass
shims (nine engine popup primitives redirected via a pointer-swap at their
definition site, not their call sites), `autoplay_demote_human()`, auto-End-
Turn, and the state-hash progress signal, all confirmed working in
combination over multiple unattended AI-vs-AI sessions (Consolidation gate
item a, above). Mechanism, scope limits (`conf.autoplay` doesn't check
`is_human`), and the still-open sub-items (harness menu bootstrap,
tech-discovery popup): `IMPLEMENTATION_DETAILS.md` 5.3.1–5.3.3.

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
- **M4 — Research pilot:** ✅ formally closed (2026-07-16) by the
  Consolidation gate's item (d) — `mod_tech_val`/`mod_tech_ai` shadow-clean
  over the full 3-save + `rule_psi` matrix. See Phase 4.2 item 1.
- **M3B — API expansion on demand:** the API grows as each subsequent domain
  requires, with the same generate-validate discipline.
- **M5 — Production/social in Lua:** porting-order modules 2 and 3 active.
- **M6 — Movement in Lua:** port complete; C++ becomes legacy fallback.
- **M7 — Fork release:** docs, zips with `lua/`, "Hello AI" example.
