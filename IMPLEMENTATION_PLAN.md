# Implementation Plan — Thinker AI in Lua (rev 2)

> This file is normative: what's required, and one-line status per item.
> Tactical, code-grounded reference (scope, field/enum catalogs, resume
> points) lives in `IMPLEMENTATION_DETAILS.md` — read both before starting
> work on a phase. Session-by-session history (bugs found, dead ends,
> decision rationale) lives in `DEVELOPMENT_DIARY.md` — read only when the
> "why" behind a past decision matters, not needed to resume work. Status
> blocks in this file summarize outcomes in a few lines and link to
> `DETAILS`/`DIARY` for specifics — don't re-expand narrative back into this
> file (both files were trimmed to this split on 2026-07-23; see the diary's
> `docs anti-bloat` convention).

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
2. Cross-compile for Windows i686, static link (requires multilib on Arch:
   `sudo pacman -S --needed multilib-devel lib32-glibc`).
3. Integrate into CMake as a custom target producing `libluajit.a`, linked
   into `thinkerlib`. Build details: `IMPLEMENTATION_DETAILS.md` 2.1–2.2.

### Phase 2A — Feasibility spike (gate for everything else)

**Status: ✅ completed (2026-07-13).** LuaJIT confirmed stable in-process
under mingw static-link + Wine; checklist items 1–7 and 9 verified, item 8
(100+ autoplayed turns) relaxed to manual play — no negative (project-ending)
outcome. Details: `IMPLEMENTATION_DETAILS.md` 2.4.

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
shadow framework, packaging, CI.

### Phase 2B — Production runtime

**Status: ✅ completed (2026-07-13).** `src/luaai.cpp/.h` implements the
production lifecycle below (config options, sandboxing, error policy, dedup
logging, safe-point hot reload); in-game validated. Implementation detail:
`IMPLEMENTATION_DETAILS.md` 2.5–2.8.

- **Init:** a `lua_init()` invoked from a safe point after process startup is
  complete (lazily on the first hook call, or from an existing patched engine
  callback that runs post-init). `DllMain` registers nothing Lua-related —
  loader-lock deadlock/UB territory otherwise.
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
- **`thinker.ini` options:** `lua_ai=1` (0 = pure C++), `lua_shadow=0` (Phase
  5 shadow mode), `lua_strict=0` (0 = log+disable hook+fallback where the
  class permits; 1 = log+popup+disable all Lua AI for the session; 2 =
  deliberate abort, development only).
- **Error handling:** every hook call goes through `lua_pcall` with a
  traceback handler. Log dedup key: `hook + traceback hash + turn`.
- **Containment statement:** *errors raised through the Lua runtime are
  contained and must not terminate the game. Memory corruption from unsafe
  native access cannot be recovered at runtime and is prevented by API design
  (Phase 3's read/write asymmetry) and startup validation — not by `pcall`.*
- **Hot reload:** developer shortcut (Alt+U) that discards the `lua_State` and
  reloads `lua/`, subject to hard rules: only at a safe point (never inside a
  Lua callback, never mid-faction-movement); no state required to continue
  the game may live exclusively in the `lua_State` (canonical state stays in
  engine structs and `plans[]`); a generation counter rejects stale
  handles/caches; no FFI callbacks are ever registered with C++ (hook flow is
  always C++→Lua via the registry), so no dangling-callback problem.
- **Logging:** `log.debug(...)`/`log.ver(...)` write to their own always-on
  `lua.log`, additionally mirroring to `debug.txt` when present (`debug.txt`
  only exists in debug builds).

**Done when:** Phase 2A spike passes (gate); production runtime has safe init,
sandbox, error policy, dedup logging and safe-point hot reload; a deliberate
script error does not bring the game down and is logged exactly once per
distinct traceback per turn. ✅

---

## Phase 3 — Binding layer (host API + FFI reads)

Guiding principle: **Lua is a client of a versioned Thinker API.** Three layers,
with a strict asymmetry between reads and everything else:

- **Reads of engine state:** direct FFI against the mapped structs, inside
  `api/` only. Reads with startup-validated layouts cannot corrupt memory; the
  worst case is a wrong decision, which is exactly what shadow mode detects.
- **All writes to engine state and all calls to engine functions:** through
  `extern "C"` wrappers in a `LuaHostApi` struct of function pointers, passed
  to Lua at init. This eliminates the two genuinely dangerous FFI uses:
  hand-declared calling conventions on x86-32 and unchecked writes.
- **Raw pointers never leave `ffi/`; persistent references are numeric IDs.**

### 3.1 Low layer: generated cdefs and the host API

**Status: ✅ completed (2026-07-13).** `tools/gen_ffi.cpp` generates
`lua/ffi/types.lua` (cdefs + validation table) from the real engine headers,
compiler-verified field types. Startup validation asserts every
`sizeof`/`alignof`/`offsetof`. Full implementation notes, plus recurring
conventions worth knowing before touching engine surface again (hand-
transcribed constants for `windows.h`-blocked headers, the computed-address
technique for a single nested-struct field): `IMPLEMENTATION_DETAILS.md`
3.1–3.5.

1. **cdef generator — generate from the compiler, not from parsing.**
   `tools/gen_ffi.cpp` `#include`s the same engine headers with the same
   defines/packing as the real build and *prints* `lua/ffi/types.lua`
   (C-syntax struct/enum declarations plus fixed global addresses) and a
   validation table (`sizeof`/`alignof`/`offsetof`, enum widths, pointer
   size). Avoids writing a C++ header parser entirely.
2. **Startup validation:** `init.lua` asserts every generated entry against
   `ffi.sizeof`/`ffi.alignof`/`ffi.offsetof`. Any mismatch: Lua AI refuses to
   enable, loud log, C++ runs.
3. **`LuaHostApi`:** versioned struct of `extern "C"` function pointers
   covering every engine function the AI calls, every mutation of engine
   state, and the retained C++ primitives (pathfinding, `TileSearch`,
   `PMTable`). Includes `api_version`; `init.lua` checks it. Every wrapper
   validates incoming IDs/coordinates before dereferencing.
4. **RNG:** `rand.game(n)` → `game_randv(n)`, `rand.map(n)` → the mod's own
   LCG. **`math.random` is forbidden in `lua/ai/`** — `init.lua` replaces it
   with a function that raises.
5. **Integer semantics (project rule).** C truncates division/modulo toward
   zero; Lua floors — a scoring codebase full of integer arithmetic makes
   this a silent-divergence trap. `api/cmath.lua` provides `idiv`/`imod` with
   C semantics; bare `/`/`%` are **banned** on integers in `lua/ai/`; bitwise
   work uses `bit` (with `bit.tobit` where C++ relies on wrap/truncation).
6. **Float-narrowing rule.** Lua numbers are always doubles; C++ `float`
   locals narrow on every assignment/operation. Where the original C++
   computes in `float` (so far only `select_build`'s `Wbase`/`Wthreat`
   block), the Lua port must use plain `/`, not `idiv` — the mirror-image
   trap of the integer rule above. Detail: `IMPLEMENTATION_DETAILS.md` 3.7.

### 3.2 High layer: idiomatic API

**Status: 🔨 built on demand, per module, as each porting-order item needs
it** (started 2026-07-13, per M3A's "do not build the full API up front").
Current coverage: `lua/api/{game,map,faction,tech,base,veh,path,rand,log,
cmath}.lua` — actual coverage tracks the porting order and lags
intentionally. Detail: `IMPLEMENTATION_DETAILS.md` 3.6.

Thin Lua modules over the FFI reads + host API calls, with the semantics of the
helpers already in `veh.h`/`base.h`/`map.h`. Boundary rules:

- **`lua/ai/` may not `require('ffi')`** — enforced by the sandbox and
  luacheck. All native access goes through `api/`. `api/` objects **may** be
  FFI metatypes crossing into `ai/` when measurement favors it.
- **Determinism:** decisions must never depend on hash-table iteration order
  (`pairs`). The API provides index-ordered iterators.

**Done when:** from inside the game, a script can list a faction's bases and
units, read tiles, call `path.find` via the host API and get the same values
the C++ `debug.txt` reports. All layout asserts pass; `api_version` handshake
works; a stale ID passed to a wrapper is rejected, not dereferenced. ✅

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
  into registry references — no per-call string lookup.
- Avoid a zoo of `lua_ai_hook_i/_ii/_b/_v` variants: a small set of typed
  argument/result descriptors (or per-domain structs) keeps call sites uniform.
- Shared state during the transition: `plans[]` (AIPlans), `mapdata` (PMTable)
  and `mapnodes` remain canonical in C++, read by Lua via FFI — both sides see
  the same state, so half of a domain can be ported without desync.

Full plumbing detail (registry resolution, `g_mutation_issued`, the typed
`out_count` descriptor): `IMPLEMENTATION_DETAILS.md` 4.1.

### 4.2 Porting order (lowest risk to highest)

Each item follows the same cycle: port 1:1 → golden traces pass (5.2) → shadow
mode per class (5.1) until divergences reach zero at the applicable level →
enable Lua by default on the branch → next.

1. **Pilot — research AI** (`tech.cpp`: `mod_tech_val` scoring, `mod_tech_ai`;
   ~400 relevant loc). Pure query, small, easy to compare. Validates the whole
   pipeline (hook, FFI reads, host API, RNG, traces, shadow).

   **Status: ✅ closed** by the Consolidation gate below. Detail:
   `IMPLEMENTATION_DETAILS.md` 4.5–4.11.
2. **Social engineering** (`faction.cpp`: `mod_social_ai` scoring,
   `mod_wants_to_attack`). Transactional/pure, once per faction per turn.

   **Status: ✅ closed.** Zero mismatches across ~145 `mod_social_ai` calls
   and 123 `mod_wants_to_attack` calls. Detail: `IMPLEMENTATION_DETAILS.md`
   4.5–4.11.
3. **Production and plans** (`build.cpp` + `plan.cpp`): `governor_priorities`,
   `facility_score`, `unit_score`/`find_proto`, `select_colony`/`select_combat`,
   `select_build`, `find_project`, `mod_base_hurry`, then `plans_upkeep`,
   `design_units`, `former_plans`. The heart of the single-player challenge.

   **Status: 🔨 mostly closed.** `unit_score`/`find_proto`,
   `select_colony`/`select_combat`, `governor_priorities`/`facility_score`,
   and `select_build` itself are all ✅ closed — `select_build` as a real
   Class 2 hook (`lua_ai_hook`, not just shadow-compared): the first hook in
   the project whose Lua return value actually drives the game, confirmed by
   a 60-turn autoplay run with 0 fallback to the C++ body. A handful of
   late-tier facility branches and the `Satellites` unit branch lack direct
   live-exercise evidence — not known defects, deprioritized by explicit user
   direction (2026-07-20), revisit opportunistically. **Item 3's
   remainder, surveyed 2026-07-28: `former_plans`/`mod_base_hurry`/
   `design_units` ✅ all done and live-verified** (a 200-turn run found
   and fixed one bug — `mod_base_hurry`'s `GrowthPopBoom` reference
   pointed at the wrong table — then confirmed clean: 0 crashes, 0 shadow
   mismatches, all three functions exercised. `design_units` kept one
   genuine original bug 1:1 per the port-before-improve rule — `arm_v`
   reads the Weapon table with an armor id). **`plans_upkeep` deliberately
   not ported** — pure fact computation, same category as `move_upkeep`'s
   own sweep. Detail: `IMPLEMENTATION_DETAILS.md` 4.18 (this survey),
   4.5–4.11 (the
   `FormerUnit`/`select_item` scope decision
   and the float-narrowing rule's only live case), 3.7.
4. **Movement** (`move.cpp` + dispatch in `veh_turn.cpp` + `goal.cpp`): start
   with the isolated movers (`artifact_move` → `crawler_move` →
   `colony_move` → `former_move` → `trans_move`), then `combat_move` +
   `move_upkeep` + invasion plans, and finish with `nuclear_move` last —
   reordered by user direction (2026-07-21) since it turned out closer
   in weight to `find_project`/`select_build` than an isolated mover, so
   its complexity shouldn't block the rest of the phase. Class 3
   territory: largest, most performance-sensitive, ported last with the
   C++ baseline already measured.

   **Status: ✅ all stages 0–8 done — Movement fully ported; stage 8
   (`nuclear_move`) still pending live exercise.** Stages 0–6 closed and
   live-verified (Class 3 hook
   infrastructure, then `artifact_move`, `crawler_move`, `colony_move`,
   `former_move`, `trans_move`, `combat_move`, in that order — including a
   deferred fix for a `route_score`/`search_route` scoring-formula-
   wrapped-opaquely defect found partway through, resolved as its own
   stage before `former_move`). **Stage 7, sub-staged 7A–7D, all done:**
   7A (engine surface: 9 `AIPlans` setters, multi-point `TileSearch` init,
   full-route retrieval, `goal.cpp` accessors, `pick_scout_target`/
   `compare_might`/`faction_might`), 7B (`land_raise_plan`, plus the first
   faction-level Class 3 hook, `lua_ai_command_hook_faction`, for the
   `(faction_id) -> void` shape none of the per-vehicle movers have), 7C
   (`invasion_plan`, confirming 7A's engine surface needed zero
   additions — reused directly), and 7D (`update_main_region`'s
   `prioritize_naval` decision — hooked *inside* the function's own body,
   the one sub-stage that needed the original seam-in-body shape rather
   than a call-site hook, since the decision isn't a separately-callable
   function). **Stage 7 (7A–7D) is closed and live-verified** — a
   boolean/int truthiness bug that silently blocked 7C/7D's own decision
   branches (funcs.lua wrappers already returning real Lua booleans,
   re-compared against `0` as if raw ints) was found and fixed via live
   testing; a 200-turn re-run confirmed `invasion_plan` firing 1400+
   times with 0 shadow-mode mismatches (root cause and full call-site
   list: `IMPLEMENTATION_DETAILS.md` 4.16). **Stage 8 (`nuclear_move`,
   deliberately ported last — its real complexity, a full diplomatic/
   threat scoring pass plus a secret-project iteration, is closer to
   `find_project`/`select_build` than an isolated mover) is done** — real
   complexity was in the scoring formulas, not new engine surface (only 5
   new host functions needed: `is_alien`/`veh_lift`/`veh_drop`/
   `set_veh_visibility`/`nuclear_find_drop_tile`). **Build-verified, still
   not live-exercised** — no faction has launched a planet buster in any
   run yet; a cdef gap (`Faction.ODP_deployed` silently folded into
   padding) that broke every invocation attempt was found and fixed, but
   the fixed path itself remains unconfirmed (`IMPLEMENTATION_DETAILS.md`
   4.17). Native life (fauna/aliens) is explicitly out of scope (user
   decision, 2026-07-20) — not strategic faction AI. Two native (non-Lua)
   crashes found live-testing Movement: `combat_move`'s `choose_defender`
   missing hostility filter, root-caused and fixed for every caller; and
   a sprite-rendering access violation surfacing right after a mass-
   casualty nuclear strike, root-caused to an address range but not yet
   fixed (open, `IMPLEMENTATION_DETAILS.md` 4.17). Full staging, real
   function sizes, and per-stage classification decisions:
   `IMPLEMENTATION_DETAILS.md` 4.12–4.17.
5. **AI probe decisions** (`probe.cpp`, partial — target/action choices only;
   resolution mechanics stay in C++). **✅ done and live-verified
   (2026-07-29).** `probe()` turned out to be a single ~1590-loc
   decompiled, goto-driven function that can't be ported as a whole unit
   (unlike every prior item) — only 3 small, genuinely isolable
   pure-decision fragments exist inside it, everything else (roughly
   half the function, `MOV_DEFEND` onward) is resolution mechanics/UI
   staying in C++. All three (`MOV_CHECK`'s `action_id` choice,
   `MOV_SABOTAGE`'s `sabotage_id` choice, `MOV_FRAME`'s frame-target
   choice), all Class 1, ✅ done and confirmed live: a 120-turn run fired
   all three with 0 errors, 0 shadow mismatches. This closes item 5's
   scope. Detail: `IMPLEMENTATION_DETAILS.md` 4.19.

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
opening the gate: `DEVELOPMENT_DIARY.md`, 2026-07-14 through 2026-07-16.

**Now: closed.** All five items done; porting resumed (see "Resuming after
the gate" below).

a. **Autoplay harness finished** (unattended all-AI runs, dialog bypass,
   state-hash progress signal, external-kill termination). ✅ done in the
   sense needed for this gate: 4/4 clean `--no-xvfb` runs on the real
   desktop, nine-primitive dialog bypass, auto-End-Turn. Two sub-items
   deferred, non-blocking: a harness menu-bootstrap mechanism (no way to
   reach an in-progress game without one manual New-Game click), and the
   tech-discovery popup (still requires manual clicks — root cause
   identified, fix not attempted). Headless Xvfb launch doesn't work on the
   dev machine, ruled out as a graphics-config problem specifically; demoted
   to nice-to-have since `--no-xvfb` already covers this gate's matrix.
   Detail: `IMPLEMENTATION_DETAILS.md` 5.3.
b. **Dual-run instrumentation promoted to real shadow mode**
   (`lua_ai_shadow_call`/`_check`, gated on `conf.lua_shadow`), plus the
   **typed hook-descriptor refactor** (Phase 4.1: `out_count` param,
   closing the gap that left `facility_score`/`governor_priorities`
   unhookable). ✅ done and exercised live: all 9 decision hooks migrated,
   zero mismatches over a full `--lua-shadow` autoplay run. Detail:
   `IMPLEMENTATION_DETAILS.md` 5.1.
c. **Golden traces (Phase 5.2), first slice** — `governor_priorities`/
   `facility_score`, the two functions with no dual-run seam before item
   (b). ✅ done: capture side (`src/golden_trace.h`/`.cpp`,
   `conf.golden_trace`) + native-`luajit` replay runner
   (`tools/golden_trace_replay.lua`), verified against a real captured
   corpus — 1265/1265 passed. Complementary to shadow mode: runs offline,
   no Wine/Xvfb, in principle CI-runnable. Extending to more hooks is
   future work, not yet done for any Movement hook. Detail:
   `IMPLEMENTATION_DETAILS.md` 5.2.
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
   Detail: `IMPLEMENTATION_DETAILS.md` 5.1, 5.3.
e. **`tools/port_drift.py` + provenance entries in `docs/LUA_PORTING.md`.**
   ✅ done: drift script verified against all three real outcomes (clean,
   drifted, error), `docs/LUA_PORTING.md` written, 11 tracked functions at
   the time (grows with every subsequent ported function). Detail:
   `IMPLEMENTATION_DETAILS.md` 4.5–4.11.

**Resuming after the gate:** `select_build` (Phase 4.2 item 3) is now fully
ported, and Movement (item 4) is now fully ported and live-verified too
(stages 0–7 confirmed; stage 8 `nuclear_move` build-verified only, still
pending live exercise — see item 4's status above). Item 3's remainder
(user choice, 2026-07-28, over item 5 `probe.cpp`) is now fully ported
too, and live-verified (2026-07-28) — `former_plans`/`mod_base_hurry`/
`design_units` all done, `plans_upkeep` deliberately left unported; see
`IMPLEMENTATION_DETAILS.md` 4.18. Porting-order item 5 (`probe.cpp`, not
started) is what's left, plus live-exercising `nuclear_move` itself
whenever a game produces a planet buster. Design notes worth re-reading
before touching production-domain code further:
`IMPLEMENTATION_DETAILS.md` 4.5–4.11 (RNG-hazard hook-argument threading,
multi-block facility gating, the `FormerUnit`/`select_item` scope decision)
and 3.7 (float-narrowing rule).

---

## Phase 5 — Validation, testing and performance

> **Current testing reality:** every in-game run referenced below (manual
> play, `--lua-shadow`/`--no-xvfb` autoplay sessions, live verification of a
> newly-ported branch) is performed by the human maintainer, not by an agent
> session. Coding sessions routinely have no `DISPLAY` and cannot drive
> Wine/the game GUI (no autoplay-menu-bootstrap path exists yet, and headless
> Xvfb launch doesn't work on the dev machine — `IMPLEMENTATION_DETAILS.md`
> 5.3). Until that's solved, a session that implements a new branch/hook
> should build-verify (both presets) and native-`luajit` syntax-check it,
> then say so explicitly and hand off live verification rather than claim
> "live-verified".
>
> **Handoff protocol:** the maintainer runs the game/autoplay session
> themselves and reports back when it's done — the agent does not wait on or
> poll for that. Once told a run is complete, the agent's job is to read the
> results, not take the "it's done" report at face value: check `lua.log`
> (game folder root, `lua/cpp <hook> mismatch: ...` lines) and, on debug
> builds, `debug.txt` (mirrors the same lines), for mismatches on the
> specific hook(s)/branch(es) that session just implemented. Report exactly
> what was found (or that logs weren't present where expected), not just "the
> maintainer confirmed it works."
>
> **Absence of a mismatch is not, by itself, evidence of correctness —
> confirm the branch was actually exercised too** (found 2026-07-17, after
> several earlier sessions' "0 mismatches, confirmed by absence" claims
> turned out to rest on this gap; recurred again in movement stage 6, in
> code from two *already-closed* stages — see `IMPLEMENTATION_DETAILS.md`'s
> "Known traps"). A hook's shadow call only fires if the surrounding C++
> loop already decided the branch is eligible — an unreached branch and a
> correctly-handled one produce the exact same "no mismatch line" output.
> Cross-check an independent "this was actually considered" signal (an
> existing debug line naming the specific item/branch) before trusting a
> clean run. Both `lua.log`/`debug.txt` truncate on every launch — there is
> no way to retroactively audit a past run once a new one starts, so get
> this right per-run. A late-game/high-prereq/high-cost branch may simply
> need a much longer run or a later save before it's ever exercised at all;
> that's a coverage gap to report, not something to paper over.

### 5.1 Shadow mode (per hook class)

`lua_shadow=1` behavior depends on the hook class:

**Class 1 (pure query):** simple compare — save RNG states, run Lua, restore
RNG, run C++ (which is what counts for the game), log any divergence
(function, args, both results, RNG draws consumed).

Caveat honored: "pure" must be verified, not assumed — a scoring function that
updates a cache is Class 2.

**Class 2 (transactional):** compare proposal vs. decision, plus C++'s delta
as ground truth (the propose-then-commit contract means Lua has no delta of
its own to compare).

**Class 3 (command/effect):** never run both sides.

- Shadow-compare only the extracted **pure scoring functions** inside the
  domain (these are ported as Class 1 internally).
- Log a **decision trace** (unit, considered options, scores, chosen action)
  from both implementations in *separate* runs and diff.
- Whole-system fidelity comes from the determinism harness (5.3) toggling
  `lua_ai` between runs.

Implementation (`lua_ai_shadow_call`/`_check`, the `out_count` typed
descriptor): `IMPLEMENTATION_DETAILS.md` 5.1.

### 5.2 Golden traces first, mocks second

Tests outside the game must be anchored in real engine behavior, not in a mock
that can only confirm the port matches the mock. Priority order:

1. **Golden traces:** the C++ side (debug build) logs, per instrumented
   function, a JSON fixture: args, observed state, RNG before/after, result.
2. **Replay runner:** Arch's native `luajit` loads fixtures, injects
   `observed_state` through a fixture-backed `api/` implementation, runs the
   ported function, compares result and RNG consumption. Runs in CI.
3. **Synthetic mocks** afterwards, to expand coverage into corner cases the
   traces don't reach.

Implementation status (only `facility_score`/`governor_priorities` covered so
far), fixture format, replay-runner design: `IMPLEMENTATION_DETAILS.md` 5.2.

### 5.3 Determinism and regression — graduated equivalence

**Autoplay harness status: ✅ implemented and validated, unattended runs
confirmed** — dialog-bypass shims, `autoplay_demote_human()`,
`autoplay_dismiss_dialog()` (generic popup dismissal, 2026-07-25),
`MRULES_NO_PLANETARY_COUNCIL`, auto-End-Turn, and the state-hash progress
signal, together took a 100-turn autoplay run to completion with zero
manual intervention (2026-07-25) — the popup-blocking problem that took
several rounds to fully chase down is closed. Mechanism, scope limits
(`conf.autoplay` doesn't check `is_human`), and open sub-items:
`IMPLEMENTATION_DETAILS.md` 5.3.

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
which divergence appears* to localize the bug instead of announcing "turn
40 differs".

**Cross-launch full-trajectory determinism (levels 3-5) was chased and then
explicitly dropped as a goal (2026-07-16)**, not left open — per-call shadow
mode is strictly stronger port-fidelity evidence and needs no cross-launch
reproducibility at all. The RNG-pinning work done while chasing it
(`fixed_rng_seed`, `game_rand_restore`) is not wasted: it delivers
single-turn reproducibility, the actual prerequisite for the one remaining
consumer of trajectory-style comparison (a hypothetical windowed method for
Movement — reload once, compare exactly one turn). Do not restart general
determinism-chasing without a concrete trigger tracing back to that method
failing. Full story: `IMPLEMENTATION_DETAILS.md` 5.3, `DEVELOPMENT_DIARY.md`
2026-07-15/16.

Harness: same seed + same initial save, autoplay N turns (all factions AI).
State hash (unit positions, bases, tech, energy per faction) extracted by a
Lua script at end of turn. Compare `lua_ai=1` vs `lua_ai=1` (Lua determinism)
and `lua_ai=0` vs `lua_ai=1` (port fidelity, valid while the port is 1:1).

### 5.4 Performance

**Instrumentation ✅ built (2026-07-29); first baseline ✅ measured
(2026-07-30).** `src/perf_trace.h`/`.cpp` (`conf.perf_trace`, off by
default, zero overhead when unset) times four phases per turn —
production, movement-planning, movement-dispatch (the per-vehicle
Class 3 movers), base-upkeep — to `perf_trace.log`. `tools/perf_run.sh
--mode cpp|lua` (a sibling of `tools/autoplay_run.sh`) automates a
same-turn-count comparison run for each mode. **First result (100 turns,
one run each, no fixed seed):** the per-vehicle cost of
`movement_dispatch` — the phase the ported Class 3 movers actually run,
and the most trustworthy number in this pass since the two games'
vehicle counts diverged — came out *lower* for Lua (10.5 ms/vehicle)
than C++ (14.8 ms/vehicle). `production` showed a real ~38% per-base
slowdown surviving normalization, plausibly genuine Lua/host-API call
overhead. Full numbers, the normalization method, and why raw totals are
confounded by the two games' diverging state: `IMPLEMENTATION_DETAILS.md`
5.4.

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
  structs/`plans[]`). Loading vanilla and Thinker C++ saves ✅ tested by the
  user (2026-07-30), works normally.
- Multiplayer: **not supported during the porting phase** (see Scope). The RNG
  and determinism rules avoid gratuitous divergence, but no multiplayer
  validation or script-synchronization mechanism is built now.
- Native Windows: community smoke test before any release (Wine is the dev
  environment, not the only target) — deferred until a Windows machine is
  available.

---

## Phase 6 — Documentation, packaging and DX

**Status: done**, except `docs/LUA_PORTING.md`'s module checklist, which stays
a living document updated per porting item rather than a one-time deliverable.
Items 1, 3, 4, 5 ✅ done (2026-07-30).

1. ✅ `docs/LUA_API.md`: API reference (`game`, `map`, `veh`, `base`, `path`,
   `rand`, `log`, `cmath`, `faction`, `tech`) + hook lifecycle and classes +
   project rules (RNG, `idiv`/`imod`, no `ffi` in `ai/`, ordered iteration).
   Expanded (2026-07-31) into a self-contained modder reference — added the
   `types.lua`/`funcs.lua` catalogs, a full table of every registered hook
   with its live-vs-shadow-only status (a fact not tabulated anywhere else:
   items 1/2 and most of item 3's first three slices are shadow-validated
   only, never actually driving the game yet), and a "developing or
   extending" workflow — so this doc + `docs/LUA_PORTING.md` are sufficient
   to work on the Lua AI without reading this plan or the details doc.
2. `docs/LUA_PORTING.md`: keep the C++ function → Lua module map, hook class
   per function, port status checklist, provenance/drift workflow current.
3. ✅ `Readme.md` rewritten (fork banner/status/relationship to upstream, rest
   of upstream content kept) and `Technical.md` updated: Arch build, pinned
   LuaJIT submodule commit and build integration, cdef generator, deploy via
   Wine, runtime config, pointers to the Lua docs.
4. ✅ Packaging: `lua/` included in the zips (`tools/makedevzip.sh`,
   `tools/makerelzip.sh`, one `cp -fr ../../lua .` line each) and in
   `deploy.sh` (already did this, wholesale replace to avoid stale files).
5. ✅ "Hello AI" example: a minimal commented script that overrides a simple
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
  and `UNIT`'s re-exposed methods, and `log.debug`/`log.ver`. **Do not
  build the full map/veh/base/path API up front** — its ideal shape is
  discovered by porting.
- **M4 — Research pilot:** ✅ formally closed (2026-07-16) by the
  Consolidation gate's item (d). See Phase 4.2 item 1.
- **M3B — API expansion on demand:** ongoing, the API grows as each
  subsequent domain requires, same generate-validate discipline.
- **M5 — Production/social in Lua:** ✅ items 2 and 3 done and
  live-verified — item 3's remainder (`former_plans`/`mod_base_hurry`/
  `design_units`) ported and live-tested 2026-07-28, `plans_upkeep`
  deliberately left unported (see item 3's status).
- **M6 — Movement in Lua:** ✅ all stages 0-8 done and fully ported; stages
  0-7 live-verified, stage 8 (`nuclear_move`) build-verified only, still
  pending live exercise (item 4's status above).
- **M7 — Fork release:** docs, zips with `lua/`, "Hello AI" example. Not
  started.
