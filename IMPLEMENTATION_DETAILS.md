# Implementation Details — tactical notes per phase

Companion to `IMPLEMENTATION_PLAN.md` (rev 2). The plan says *what* and *why*;
this file pins down *where* and *how*: current scope, engine-surface
conventions, and resume points — not a session-by-session log. Facts here are
current-state, code-grounded (line numbers as of commit `15418b2`; re-verify
after upstream merges). Narrative — bug hunts, dead ends, verification run
counts, exact files-touched lists — lives in `DEVELOPMENT_DIARY.md`,
cross-referenced by date from the relevant section below; this file was
trimmed to that split on 2026-07-23 (it had grown to ~4300 lines by
re-narrating every session inline instead of linking the diary).

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

make -C third_party/luajit/src HOST_CC="gcc -m32" \
     CROSS=i686-w64-mingw32- TARGET_SYS=Windows BUILDMODE=static libluajit.a
```

Artifacts: `third_party/luajit/src/libluajit.a` + public headers `lua.h`,
`lauxlib.h`, `lualib.h`, `luajit.h` in the same directory.

### 2.2 CMake integration

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

LuaJIT's makefile is not parallel-safe across configs sharing the same source
dir — `debug`/`develop` share one `libluajit.a` (fine, always built optimized).
`make clean` in the submodule when switching LuaJIT versions.

### 2.3 Init point — outside the loader lock

**Never initialize Lua in `DllMain`** (`src/main.cpp:446`) — loader lock; file
I/O, CRT/runtime init and JIT activation there are deadlock/UB territory.
Instead: lazy init from `mod_turn_upkeep()` (`src/game.cpp:1010`, patched over
`control_turn`/`net_control_turn` at `patch.cpp:656-657`) — runs at the start
of every turn, well after process init. `src/luaai.h`/`.cpp` own the single
`lua_State*`: `lua_ai_init_once()` (idempotent), `lua_ai_shutdown()` (safe to
call from `DLL_PROCESS_DETACH`), `lua_ai_reload()` + safe-point flag (2.7),
`lua_ai_hook(...)`/`lua_ai_command_hook(...)` (Phase 4).

### 2.4 Phase 2A spike — passed, kept for reference only

Confirmed stable: static LuaJIT link, lazy init via `mod_turn_upkeep`,
`lua/init.lua` via `lua_pcall`+traceback, host↔Lua round trips both
directions, a deliberate Lua error contained, `jit.off()` and `jit.on()` both
exercised. No PUC Lua fallback needed — the kill criterion never triggered.

### 2.5 Config options

Three places per option (follow `social_ai`, `src/main.h:232`, as template):
1. Field in `struct Config`, `src/main.h`.
2. Parse branch in `option_handler`, `src/main.cpp` (`MATCH("lua_ai")` etc.).
3. Documented default in `docs/thinker.ini`.

Current: `lua_ai=1`, `lua_shadow=0`, `lua_strict=0` (0=disable failing
hook+fallback, 1=disable all Lua AI for the session+popup, 2=abort, dev only).

### 2.6 Logging reality check

`debug()`/`debug_ver()` compile to nothing outside `BUILD_DEBUG`. Lua's
`log.*` writes to its own always-available `lua.log`, and additionally
mirrors to `debug.txt` when `debug_log` exists. Prefix `lua:`, honors the
Alt+M verbose toggle.

### 2.7 Hot reload key

Alt+U (unused, available in all builds). Keypress only sets a flag; the
actual reload runs at the next safe point (start of `mod_turn_upkeep`, before
any AI phase), never inside a Lua callback. Generation counter increments on
reload; stale handles are rejected.

### 2.8 Sandboxing

Open only `base`, `table`, `string`, `math` (`math.random`/`randomseed`
replaced by raising stubs, 3.5), `bit`. `io`/`os`/`debug`/arbitrary `require`
only in development builds. `ffi` is used inside `lua/ffi/`+`lua/api/` and
never exposed to `lua/ai/`.

---

## Phase 3 — binding layer

Rev 2 principle — read/write asymmetry: **reads** of engine state are direct
FFI inside `api/`; **all writes and all engine-function calls** go through
`extern "C"` wrappers in `LuaHostApi`. Raw pointers never leave `ffi/`;
persistent references are numeric IDs, validated by every wrapper before
dereferencing.

### 3.1 cdefs are generated by the compiler, not parsed

Engine structs (`engine_veh.h` etc.) are C++ with inline methods — LuaJIT's
`ffi.cdef` only accepts C. `tools/gen_ffi.cpp` `#include`s the real engine
headers with the real build's defines/packing and *prints* `lua/ffi/types.lua`
(field-only C declarations + fixed global addresses) plus a validation table
(`sizeof`/`alignof` per struct, `offsetof` per exposed field, enum widths,
pointer size). `init.lua` asserts every entry at startup; any mismatch → Lua
AI refuses to enable, loud log, C++ runs. Inline C++ helpers dropped by
field-only generation are re-ported manually in `lua/api/` as needed (3.6).

**Convention: don't hand-verify a new field/enum against the header before
writing code** — let `gen_ffi`'s own compile step catch a typo or missing
name as a build error (this discipline has caught several real gaps faster
than manual cross-checking would have).

**Convention: some headers can't be `#include`d by `gen_ffi.cpp`.** `move.h`,
`path.h`, `veh_turn.h`, `main.h` pull in `windows.h` transitively, which the
natively-compiled (non-mingw) `gen_ffi` host tool can't process. Constants
from those headers (`VEH_SYNC`/`VEH_SKIP`/`PM_SAFE`, every `NodesetType`
value, `TSType`/`QueueSize`/`PathLimit`, `StackType`, `FormerMode`,
`VEH_REMOVE_TURNS`, `AerospaceDefenseRange`, ...) are hand-transcribed
directly into `gen_ffi.cpp`'s `printf` block instead — cross-check against
the source header if one of these is ever suspected to have drifted. **A
hand-transcribed enum used-but-never-added is a real, recurring bug class**
(found live three separate times across movement stages 4/5/6: `FormerMode`,
then `FORMER_NONE`/`FORMER_RAISE_LAND`) — `nil` is well-formed enough in Lua
that the gap doesn't error until the exact branch runs, so it survives a
clean build and a syntax check. When adding a batch of hand-transcribed
constants, grep the generated `types.lua` afterward to confirm each one
actually landed, don't just trust the edit.

### 3.2 Engine globals: two kinds, two mechanisms

- **Fixed-address constants** (`CurrentBase`, `Rules`, ...): safe to emit as
  generated `ffi.cast` constants.
- **Mutable/re-pointable pointers** (`Vehs`, `Bases`): the mod can re-point
  these (`VehsMod`/`ArrayVehs`). **Never hardcode these addresses in Lua.**
  Expose via the host API as pointers-to-pointers, dereferenced on every
  access in the Lua wrapper (`lua/api/veh.lua`/`base.lua`'s `get()` re-fetch
  the current pointer every call rather than caching one `ffi.cast`).

### 3.3 `LuaHostApi` — writes, calls, retained primitives

One versioned `extern "C"` struct of function pointers, `api_version` bumped
on any layout change, `init.lua` asserts it (current: 40, per the last
combat_move sub-stage — check `src/luaai.h` for the live number). Covers (a)
every engine function the AI calls, (b) every mutation of engine state, (c)
retained C++ primitives (pathfinding, `TileSearch`, `PMTable`). Every wrapper
validates IDs/coordinates before dereferencing. Never declare engine function
signatures in Lua FFI for *calling* — that's the dangerous FFI use the
asymmetry rule eliminates; only host-API wrappers call into the engine.

**Opaque-wrapper criterion, applied consistently across every domain since
tech.cpp:** ask "does this code make a *choice* an AI could reasonably do
differently, or does it just compute a fact about the world?" Facts/pure
engine mechanics (yield calculators, eligibility gates, `TileSearch`
mechanics, `Path_find`) stay as opaque host wrappers. Choices (scoring
formulas, which candidate wins) must be real Lua, even when they consume
opaque facts as inputs. Getting this wrong is a recurring, real mistake — it
happened to `want_convoy` (`crawler_move`, stage 2), `route_score`
(`artifact_move`/`colony_move`, deferred and fixed as its own stage), and
would have happened to `combat_move`'s 13 shared scoring helpers had they not
been re-derived directly once `veh.count()/get()`/`base.count()/get()`
already existed. When in doubt, read the function in full before deciding.

**`TileSearch` start/next iterator pattern** (first used for `crawler_move`,
stage 2; reused for `colony_move`/`escape`/`base`, `former_move`,
`trans_move`, `combat_move`'s generic re-initializable version): a C++-side
`TileSearch` can't cross into Lua (it's a stateful scan object, Phase 4.3),
but the *scoring loop* over its candidates should be Lua if the scoring is a
real choice. Solution: expose `X_search_start(...)`/`X_search_next()` as a
pair of host-API calls sharing one file-local static `TileSearch` between
calls (safe because movement dispatch is strictly sequential, same assumption
`g_mutation_issued` relies on) — Lua drives the loop and scores each
candidate itself. When a search step needs the parent-chain (`get_prev()`),
expose `prev_x`/`prev_y` as extra out-params rather than the raw path-node
array (`route_search_naval_pickup_next`, `combat_search_next`).

**Computed-address technique for a nested struct's single member:** when only
one field of a sub-struct is needed (`ResInfo.recycling_tanks.energy`,
`Terraform`'s per-item `rate`, ...) and `gen_ffi`'s `FIELD()`/`FieldShape`
can't `emit_struct` a nested member, expose one new global computed from
`offsetof` at generation time instead of pulling in the whole sub-struct.

### 3.4 `PMTable`/`NodeSet` are STL — not FFI-accessible

`PMTable` (`std::unordered_map<Point, PInfo>`) and `NodeSet`
(`std::set<MapNode>`) can't cross FFI. Access goes through host-API accessor
functions (`mapdata_get`, `mapnodes_check`/`_add`, and by now a `map_*`
family: `map_target`/`map_safety`/`map_enemy`/`map_enemy_near`/
`map_enemy_dist`/`map_enemy_rank`/`map_flags`/`map_roads`/`map_former`/
`map_target_incr`). `plans[]` (`AIPlans`, plain struct) has no such
problem — expose one field per accessor as needed (`psi_score`,
`defense_modifier`, `main_region`, ... — dozens by now, see `src/luaai.h`
for the live list, all following the same one-field-per-wrapper shape).

### 3.5 RNG bindings

`rand.game(n)` → `game_randv(n)`; `rand.map(n)` → the mod's own LCG
(`random_state()`/`random_reseed()`/`game_rand_restore()` exist for
shadow-mode snapshot/restore). `math.random`/`randomseed` raise in
`lua/ai/` — enforced, not convention.

### 3.6 High-level API

Mirror `veh.h`/`base.h`/`map.h` inline-method semantics exactly (e.g.
`map.tile(x,y)` must reproduce `mapsq()`'s odd/even parity + X-wrap).
Iterators are always index-ordered, never `pairs` over hash tables
(determinism rule). Built on demand per porting-order item, not up front —
current coverage: `lua/api/{game,map,faction,tech,base,veh,path,rand,log,
cmath}.lua`. `ai/` may not `require('ffi')`; `api/` objects may be FFI
metatypes crossing into `ai/` when it helps (LuaJIT is a hard dependency).

### 3.7 Integer and float semantics

- `api/cmath.lua`'s `idiv(a,b)`/`imod(a,b)` (C truncation) are mandatory for
  integer division/modulo in `lua/ai/`; bare `/`/`%` on integers are banned.
  Bitwise via `bit`; `bit.tobit` where C++ relies on 32-bit wrap.
- **Float-narrowing rule**, first and so far only relevant in
  `select_build`'s `Wbase`/`Wthreat` block (genuine C `float` locals, not
  integer truncation) — when the *original* C++ computes in `float`, use
  plain Lua `/` there, not `idiv`; using `idiv` on a genuinely-float
  expression is the mirror-image bug (introducing truncation the original
  never had). Double-check the C operand types before reflexively reaching
  for `idiv` on any division in newly-ported code.

---

## Phase 4 — porting

### 4.1 Hook plumbing

- **Hook classes** (plan 4.1): Class 1 pure query, Class 2 transactional
  (propose-then-commit), Class 3 command/effect (Lua mutates via host API;
  no fallback after the first mutation — finish the unit safely via
  `veh_skip` and log). Record the class per function in `docs/LUA_PORTING.md`.
- **Registry-based resolution:** hooks resolve once at (re)load into registry
  references; per call it's one `lua_rawgeti` + `lua_pcall`, no string lookup.
- One typed descriptor (`out_count`: 1 = single number, >1 = a 1-indexed
  table of `out_count` numbers) covers every hook shape — no
  `lua_ai_hook_i/_ii/_b/_v` zoo. This is what makes even `void`-with-struct-
  output functions (`governor_priorities`) hookable.
- Return protocol: `nil` → "not handled" → C++ fallback (per the class's
  rules). Non-nil is the decided value/proposal.
- Shared state during the transition: `plans[]`, `mapdata`, `mapnodes` stay
  canonical in C++, read by Lua via FFI/host API — a domain can be ported
  half-and-half without desync.
- **Class 3 specifics** (`lua_ai_command_hook`, `src/luaai.h`/`.cpp`): a
  `g_mutation_issued` flag, set by every mutating host wrapper as its first
  action and reset at hook entry. Error after a mutation → finish the unit
  safely (`mod_veh_skip`) and report "handled" (no C++ re-run over
  already-mutated state). Error before any mutation → report "not handled",
  C++ body runs unchanged. No RNG snapshot/restore (Class 3 never runs both
  sides — nothing to keep aligned).

### 4.2 Seam locations (verified)

| Hook | Function | File:line region |
|---|---|---|
| Research value | `mod_tech_val` | `tech.cpp` |
| Research pick | `mod_tech_ai` | `tech.cpp` |
| Social engineering | `mod_social_ai` | `faction.cpp:87` (decl) |
| War decisions | `mod_wants_to_attack` | `faction.cpp:88` (decl) |
| Production | `select_build` | `build.cpp` (decl `build.h:18`) |
| Hurry | `mod_base_hurry` | `build.cpp` (decl `build.h:5`) — unported |
| Unit design | `design_units` | `plan.cpp` (decl `plan.h:45`) — unported |
| Strategic upkeep | `plans_upkeep` | `plan.cpp` (decl `plan.h:47`) — unported |
| Unit dispatch | `mod_enemy_move` | `veh_turn.cpp:137` (per-class dispatch 164–189) |
| Per-class movers | `colony_move` … `combat_move` | `move.cpp` (decls `move.h:56-63`) |
| Move upkeep | `move_upkeep` | `move.cpp` (decl `move.h:40`) — unported |
| Nuclear | `nuclear_move` | `move.cpp` — unported, **current resume point** |

Hook the **per-class movers**, not `mod_enemy_move` itself — its body also
handles player-unit automation, alien factions, and an anti-infinite-loop
engine fallback that stays in C++.

### 4.3 Porting workflow per module

1. Read the C++ function in full; list every helper it calls; decide each:
   port to Lua, opaque host wrapper, or already available. Confirm the hook
   class ("pure" must be verified, not assumed).
2. Port 1:1, keeping C++ control flow recognizable; add
   `port.source = {file, func, upstream_commit}` provenance.
3. Golden traces / shadow mode until divergences are zero at the
   class-appropriate level.
4. Flip default, move on. Never port two modules in shadow simultaneously.

After every upstream merge: `tools/port_drift.py`, then re-run `gen_ffi` +
layout asserts.

### 4.4 Movement-specific notes

- `move_upkeep(faction_id, mode)` is both computation (fills `mapdata`/
  `mapnodes`/region info — stays C++) and decision prep (invasion/naval
  planning — the part that ports). Not yet started.
- `combat_move` interleaves decisions with engine actions — canonical
  Class 3. Its pure scoring helpers were extracted and ported as real Lua
  (Class 1 internally, see 4.15); whole-system fidelity comes from live
  autoplay + decision-trace logging, not per-call shadow comparison.

---

### 4.5–4.11 Production/plans (porting-order items 1–3) — ✅ all closed

Full narrative for each item (scope decisions, bug hunts, exact verification
counts): `DEVELOPMENT_DIARY.md`, 2026-07-14 through 2026-07-20.

- **4.5 Social engineering** (`mod_social_ai`) and **4.6 War decisions**
  (`mod_wants_to_attack`) — closed 2026-07-14. Both hooked via the plain
  int-args-in/int-result-out contract (social engineering packs
  `sf*MaxSocialModelNum+sm2`, `-1` = no proposal). `pop_boom`/`hq_region`/
  `great_beelzebub`/`great_satan`/`has_agenda` kept as opaque host
  wrappers (engine mechanics, not the AI decision itself).
- **4.7 `unit_score`+`find_proto`**, **4.8 `select_colony`/`select_combat`**,
  **4.9 `facility_score`/`governor_priorities`** — closed 2026-07-14/16.
  First-ever `BASE`/`VEH` FFI exposure happened here. Durable naming trap:
  `UNIT::offense_value()`/`defense_value()` (raw weapon/armor field) vs.
  `proto_offense()`/`proto_defense()` (`veh.cpp`, reactor-multiplier +
  planet-buster special case) are genuinely different functions, both kept,
  don't collapse them. `defend`-as-bool-shaped-int must be normalized on
  entry (`lua_ai_hook` passes bools as raw 0/1 ints; Lua's `0` is truthy).
  `facility_score`/`governor_priorities` initially shipped unhooked (no hook
  shape could express a `WItem&` in/out) — fixed by the `out_count`
  typed-descriptor refactor (5.1.1), which is now the standing mechanism.
- **4.10 `select_build`** (`build.cpp:867-1334`, ~467 loc) — closed
  2026-07-20, the last and largest piece of item 3. Full field/enum/wrapper
  catalog is not reproduced here (see `gen_ffi.cpp`/`src/luaai.h` for current
  state) — what still matters for future work:
  - The C++ `std::priority_queue` output mechanism is *not* a real heap —
    `select_build` only ever calls `.top()`/`.size()` once, at the very end.
    Lua just tracks `(best_item_id, best_score)`, no heap needed.
  - **RNG-hazard hook-argument threading**: a per-call-once C++ local that
    consumes RNG when derived (e.g. `allow_units`) cannot be re-derived
    inside a prologue that gets shadow-called fresh per item (up to 38× per
    real call) — it must be computed once in C++ and threaded through as a
    hook argument (same precedent as `mod_social_ai`'s `pop_boom`). A local
    that's provably RNG-free is safe to re-derive per item instead.
  - **Split-block facilities**: a single facility ID can be gated by more
    than one separate `if (t == FAC_X)` block in `build.cpp` (found for
    `FAC_NAVAL_YARD`, `FAC_BIOLOGY_LAB`). Check for a second block before
    calling any facility "done".
  - `FormerUnit`'s dependency `select_item` (~472 loc) was deliberately
    **not** ported here — within `select_build` its return value is only
    ever used as a `>=0` eligibility tally, never scored. Wrapped as one
    opaque host call (`former_tile_tally`); the real port happened later in
    `former_move` (4.13), where the terraform choice actually is real
    AI policy.
  - `has_project(...) ~= 0` is always wrong — `has_project` is declared
    `bool` in `LuaHostApi`, and LuaJIT converts a C `_Bool` to a genuine Lua
    boolean, never `~= 0`-comparable (that idiom is only for raw `int32_t`
    host calls). Same trap applies to any bool-returning host wrapper.
  - **Verification methodology, now a standing project rule**: absence of a
    `lua/cpp ... mismatch` line is not evidence of correctness — a shadow
    hook only fires if the surrounding C++ loop already decided the branch
    is eligible. Cross-check an independent "this was actually considered"
    signal (e.g. `push_item`'s own debug line, grep for the item name) before
    trusting a clean run. Both `lua.log`/`debug.txt` truncate on every
    launch, so this must be checked per-run.
  - `select_build` was the project's **first** hook wired via `lua_ai_hook`
    (not `lua_ai_shadow_call`) — the first whose Lua return value actually
    drives the game. Verification for this class of hook needs a different
    question than "0 mismatches": is the hook *governing* (compare a
    "real call happened" debug line against the C++-fallback-only debug
    line — 0 fallback lines means 100% Lua-handled), not just callable
    without crashing.
  - **Deprioritized, not a known defect** (explicit user direction,
    2026-07-20 — revisit opportunistically, not scheduled): 5 late-tier
    facilities (`FAC_ROBOTIC_ASSEMBLY_PLANT`/`FAC_NANOREPLICATOR`/
    `FAC_QUANTUM_CONVERTER`/`FAC_PARADISE_GARDEN`/`FAC_PSI_GATE`) and the
    `Satellites` unit branch lack direct exercise evidence.
  - `mod_base_hurry`/`plans_upkeep`/`design_units`/`former_plans` remain
    **unsurveyed** — next piece of porting-order item 3 if it's ever
    resumed (currently deprioritized vs. finishing Movement).
- **4.11 Port drift tooling** (`tools/port_drift.py`, `docs/LUA_PORTING.md`)
  — done 2026-07-16. Extracts each `port.source`-tracked C++ function body at
  the pinned commit vs. current `upstream/master`, normalized-hash compares.
  Verified against real clean/drifted/error outcomes. Run after every
  upstream merge.

---

### 4.12–4.16 Movement (porting-order item 4) — stages 0–6 closed; stage 7 (7A/7B done, pending live test) in progress; stage 8 (nuclear_move) not started

Full narrative for every stage below (exact field/enum/wrapper catalogs,
`api_version` history, verification run counts, files-touched lists, every
bug hunt): `DEVELOPMENT_DIARY.md`, 2026-07-20 through 2026-07-24. What
follows is what still matters for resuming or extending this work.

**Dispatch:** `mod_enemy_move` (`veh_turn.cpp:147`) routes each vehicle to
exactly one mover by type. Each mover is Class 3: it calls host mutators
directly and returns an action code (`VEH_SYNC`/`VEH_SKIP`) the C++ caller
uses as-is. Native life (fauna/aliens, `veh_turn.cpp:261-887`) is explicitly
out of scope (user decision, 2026-07-20) — not strategic faction AI.

**Real sizes (loc):** `artifact_move` ~23, `crawler_move` ~67, `colony_move`
~125 (+`escape_score`/`search_escape`/`search_base`/`base_tile_score`
dependencies), `former_move` ~157 (+`select_item` ~200 +12 tile-eligibility
helpers ~270 +`former_tile_score` ~42 — ~670 total, the one stage with a
genuinely large new port), `trans_move` ~253 (+`near_landing`/
`make_landing`), `combat_move` ~726 — by far the largest function in the
project — (+~190 loc pure-scoring dependency cluster +`airdrop_move` ~66),
`nuclear_move` ~163 **but with real complexity undersold by loc**: full
cross-faction diplomatic/threat scoring, a complete secret-project
iteration (comparable to `find_project`/`select_build`), spatial containers
for base-target search, and several new primitives
(`veh_drop`/`veh_lift`/`ally_near_tile`/`min_range`/a `VEH*`↔`BASE*`
`map_range` overload). `move_upkeep` ~354 (unported — table fills stay C++
per plan 4.3; the invasion/naval planning that consumes them is what would
port). Faction-level: `land_raise_plan` ~115 (✅ ported, stage 7B),
`invasion_plan` ~106, `update_main_region` ~61, `goal.cpp` ~180 (small
state helpers, consumed by this planning, not by movers) — the latter
three still unported, see 4.16.

**Status per stage:**
- Stage 0 (Class 3 hook infra) — ✅ done (4.1 above).
- Stage 1 `artifact_move` — ✅ closed, live-verified (the pilot).
- Stage 2 `crawler_move` — ✅ closed, live-verified. `want_convoy`'s scoring
  formula is real Lua (see 3.3's opaque-wrapper criterion — this is where
  it was first violated then corrected); its `TileSearch` scan is the
  project's first start/next iterator (3.3).
- Stage 3 `colony_move` (+`escape_score`/`search_escape`/`search_base`/
  `base_tile_score`/`defender_count`) — ✅ closed, live-verified.
  `search_route`'s own `route_score`-opaque-wrapping defect was found here
  (same mistake class as `want_convoy`) and deliberately deferred to its own
  stage rather than fixed inline — resolved before stage 4 started (see the
  `route_score` entry below).
  - **`route_score`/`search_route` fix** (`path.cpp:659-885`, 210 loc) —
    ✅ closed 2026-07-22, in two sub-stages (A: `route_score` itself + two
    `Bases[]` scans; B: the three `TileSearch`-driven scans, incl. a
    parent-chain walk via `get_prev()`, plus full reassembly and rewiring
    `artifact_move`/`colony_move` to call it). Kept a genuine 1:1-fidelity
    bug from the original (a stale-`sq` reuse, `path.cpp:760`) rather than
    fixing it, per the project's port-before-improve rule — see the diary
    entry for how that was represented (`route_score`'s optional
    `sq_x,sq_y` override).
- Stage 4 `former_move` (+`select_item`, 12 `can_*` tile-eligibility
  helpers, `former_tile_score`) — ✅ closed, live-verified, across 4
  sub-stages. `has_terra`/`can_bridge` stay opaque (structural eligibility
  gates); the other 12 helpers + `select_item` + `former_tile_score` are
  real Lua (they're where the actual terraform choice lives). This stage's
  live bug hunt (two enum gaps, a NULL-pointer FFI-arity crash, a
  forward-reference gap) is the most instructive one in the project so
  far for how a build-clean, syntax-checked change can still fail live —
  see the diary.
- Stage 5 `trans_move` (+`near_landing`/`make_landing`) — ✅ closed,
  live-verified clean, no new bugs. `choose_defender`/`battle_priority`
  confirmed to belong to `combat_move`'s own family and kept opaque here
  (both call `Path_find`, a C++-only primitive) — this classification
  turned out to be exactly right for stage 6 too.
- Stage 6 `combat_move` (+13 shared scoring helpers +`airdrop_move`) — ✅
  closed 2026-07-23, across 4 sub-stages (A: engine surface + the 13
  helpers, all ported as real Lua per 3.3's criterion, zero opaque wrappers
  needed for their own logic; B: `airdrop_move`+`allow_airdrop`; C: the
  remaining engine surface incl. a generic re-initializable `TileSearch`
  iterator, since this function reuses one `TileSearch` object across three
  loops — the reason the original 4-way line-range split (sub-stages C-F)
  was abandoned mid-planning, see the diary; D: whole-function assembly +
  hook wiring). Found and fixed one pre-existing `has_pact` truthiness bug
  in two *already-closed* stages (`colony_move`, `make_landing` — a raw
  int used as a boolean, Lua's `0` is truthy) — lesson: "live-verified
  clean" only covers branches actually exercised, not the whole function.
  Found and fixed a real native crash (`assert` abort in `battle_priority`,
  not a Lua defect) — `choose_defender`'s `at_war` check was skippable for
  base targets, letting a same-faction/allied unit be picked as
  "defender"; fixed unconditionally for every caller, native and Lua alike.
  Re-verified live over 151 turns, 0 crashes. **Two narrow branches
  (`combat_change`, `combat_gate`) and `airdrop_move` did not fire this
  run** — coverage gap, not a known defect, revisit opportunistically
  (same disposition as `select_build`'s deprioritized facilities).

### 4.16 Stage 7 — faction-level orchestration (`land_raise_plan`/`invasion_plan`/`update_main_region`/`goal.cpp`)

Sub-staged 7A–7D (this file's own numbering, `IMPLEMENTATION_PLAN.md`
doesn't commit to sub-stage letters).

- **7A (engine surface)** — ✅ done, build-verified. First Lua *writes* to
  `plans[]` (9 setters: `main_region`/`main_sea_region`/
  `target_land_region`/`prioritize_naval`/`naval_scout`/`naval_airbase`/
  `naval_start`/`naval_end`/`naval_beach`, the last of these also missing
  its getter until now). New `TileSearch` primitives: `region_search_start`
  (single point) / `region_search_start_multi` (point-list init, `land_
  raise_plan`/`invasion_plan`'s own need — no prior mover used the list
  overload) / `region_search_next` / `region_search_get_route` (first time
  a full `PointList` route crosses into Lua, not just `get_prev()` —
  `land_raise_plan` iterates the whole route, not just the last step) /
  `region_search_adjust_roads`. `goal.cpp` accessors `has_goal`/
  `find_priority_goal` (`add_goal` already existed). `Continents[]` turned
  out to already be fully exposed (`lua/api/map.lua`'s `map.continent`) —
  no new work needed there. `compare_might`/`faction_might` (`src/
  plan.cpp:365-371`, 2-line formulas, ported as real Lua not opaque, same
  tier as `target_priority`) and `pick_scout_target` (`move.cpp:634-657`)
  ported in `lua/ai/move.lua`, not a new `ai/plan.lua` (Movement is their
  only consumer so far). `api_version` 40→41.
- **7B (`land_raise_plan`)** — ✅ done, **build-verified only, not yet
  live-tested**. `move.cpp:519-629`. New engine surface: `can_alter_level`
  (opaque, pure altitude arithmetic + neighbor scan), `mapdata_set_overlay`
  (new setter — the field is debug/visualization-only, read only by
  `move_upkeep`'s `UM_Visual` block, but written unconditionally in the
  original for every popped shore candidate, kept for 1:1 fidelity),
  `land_raise_search_start`/`_next` (a host-side iterator over the real
  `mapdata` unordered_map doing every structural check from `move.cpp:598-
  619` including the inner `iterate_tiles` break-on-first-ocean-match —
  Lua only scores the yielded candidates). New constants: `AI_GOAL_RAISE_
  LAND`, `PM_LandBaseRds`, `PREF_AUTO_FORMER_RAISE_LWR_TERRAIN` (previously
  *deliberately* unexposed — `can_bridge` was its only reader and stayed
  opaque; `land_raise_plan` now reads it directly), `LM_CRATER`/
  `LM_URANIUM`. `api_version` 41→42.
  - **New hook shape:** `lua_ai_command_hook_faction(name, faction_id)` —
    every prior Class 3 hook is `(veh_id) -> int`; this is the first
    `(faction_id) -> void` one. Same no-fallback-after-first-mutation rule,
    but no per-unit `mod_veh_skip` exists to recover with, so an error
    after a mutation is just logged and reported handled. Return protocol:
    a Lua `false` means "not handled" (mirrors Class 1/2's nil), anything
    else (including no return) means handled — chosen so the function's
    own legitimate early-return branches don't all need `return true`.
  - **Hook site:** unlike the generic seam example in `IMPLEMENTATION_
    PLAN.md` Phase 4.1 (hook inside the function body), this follows
    Movement's own actual precedent — hooked at the *call site*
    (`move_upkeep`, `move.cpp`, where `land_raise_plan`/`invasion_plan`
    are invoked), same as the per-vehicle movers' seams in `veh_turn.cpp`'s
    `mod_enemy_move`. `land_raise_plan`'s own C++ body is untouched
    fallback.
  - **`point_max_queue_t` → `table.sort`:** `MItem::operator<` (`plan.h:19-
    32`) orders by `(score, x, y)` ascending, so `top()`/`pop()` yields
    descending score, ties broken by descending x then y. Verified this
    ordering is a total order over the candidate set (no two tiles share
    `(x,y)`), so the *result* of "top 8" is insertion-order-independent —
    Lua doesn't need to replicate the C++ `unordered_map`'s own iteration
    order to get identical output, just collect every candidate then sort.
  - `min_range`'s empty-set sentinel is `9999` (`map.cpp:70-76`), not
    `INT_MAX`/`math.huge` — matched exactly in the Lua port
    (`min_range_over`) even though the difference can't matter against the
    `>= 2` comparison it's used in, for exact fidelity.
- **7C (`invasion_plan`)** and **7D (`update_main_region`'s `prioritize_
  naval` decision)** — not started. `invasion_plan` reuses `target_priority`
  (already ported, stage 6) and 7A's `pick_scout_target`/multi-point search/
  route-retrieval primitives directly; expect fewer new primitives needed
  than 7B took.
- `move_upkeep`'s own map/unit/base sweep (`move.cpp:852-1141`) and its
  goal→mapnode bookkeeping tail (`1157-1180`) stay C++ (fact computation,
  Phase 4.3) — only the `land_raise_plan(faction_id); invasion_plan
  (faction_id);` call site (`UM_Full` branch) gets a hook.

**Resume point:** stage 7C (`invasion_plan`, `move.cpp:662-762`) next, then
7D, then stage 8 (`nuclear_move`, deliberately ordered last — see its size
note above). `IMPLEMENTATION_PLAN.md` describes stage 7 as one unit without
committing to sub-stage letters; this file's own 7A–7D / 0–8 numbering is
the authoritative staging if a number is needed.

---

## Phase 5 — validation

The Consolidation gate (`IMPLEMENTATION_PLAN.md`, opened 2026-07-14, closed
2026-07-16) replaced ad hoc dual-run instrumentation with the real mechanisms
below. Implementation narrative for all of 5.1–5.3: `DEVELOPMENT_DIARY.md`,
2026-07-14 through 2026-07-16 (autoplay harness bugs), plus 2026-07-15/16 for
the determinism-chase-then-abandoned story (5.3's own note below).

### 5.1 Shadow mode (Class 1/2 hooks)

`src/luaai.h`/`.cpp`: `LuaShadowCall lua_ai_shadow_call(name, out_count,
args)` (before the C++ body runs) + `lua_ai_shadow_check(name, shadow,
cpp_out, out_count)` (once the C++ result is known). `_call` snapshots
`game_rand_state()`/`random_state()`, calls the hook, restores both streams
unconditionally (zero manual per-hook RNG bookkeeping needed anymore),
records RNG-draw-count deltas. `_check` logs one line per divergence:
`lua/cpp <hook> mismatch: args=[...] lua=[...] cpp=[...] rng_draws: ...`
via `lua_logf` (lands in `lua.log`, not just `debug.txt`).

The `out_count` typed-descriptor (1 = single number, >1 = a table) is what
makes `void`/struct-output functions hookable — no hook-shape zoo (4.1).

Class 3 hooks are never shadow-run (nothing to compare once mutations
happen) — see 5.3's decision-trace approach instead.

**Consolidation gate acceptance (closed 2026-07-16):** zero `lua_shadow=1`
divergences over long autoplay runs on 3+ distinct saves/maps including one
`rule_psi` game. This is per-call, same-process comparison — it needs no
cross-launch determinism at all, which is why the determinism-chase below
(5.3's RNG-pinning work) was abandoned as a *gate* prerequisite once this
existed (it's strictly stronger evidence of port fidelity).

### 5.2 Golden traces

- C++ side (`src/golden_trace.h`/`.cpp`, gated on `conf.golden_trace`,
  zero-overhead when unset): appends one JSON-Lines fixture per instrumented
  call to `golden_traces.jsonl` (append-mode, accumulates across sessions) —
  args, observed state, RNG before/after, result.
- Replay runner (`tools/golden_trace_replay.lua`): runs under Arch's *native*
  `luajit` (no Wine/Xvfb/save file, in principle CI-runnable). Loads
  `lua/ai/*.lua` through an overridden `dofile` that substitutes
  fixture-backed stand-ins for `lua/api/{base,faction,tech}.lua` (the modules
  that touch live engine memory) while loading `cmath.lua` for real (pure Lua,
  no host dependency). Any enum table a tested function reads unconditionally
  at module load (not just inside a branch) needs its real values
  hand-copied into the stub, not left as an empty table — an empty stub
  crashes on first use, not at load time.
- Currently implemented for `facility_score`/`governor_priorities` only
  (1265/1265 fixtures passed against a real captured corpus, plus
  deliberately-wrong fixtures to prove the checker isn't vacuous). Extending
  to more hooks is future work, not yet started for any Movement hook.
- `lua/ai/*` must only reach engine access via `lua/api/*` (never `ffi`
  directly) — that's what makes the fixture substitution possible at all.

### 5.3 Autoplay harness and determinism — what's actually usable today

- **`conf.autoplay=1`** bypasses the 11 raw popup primitives Thinker's own
  code funnels every dialog through (redirected at their *definition* site,
  not call sites — `src/autoplay.h`/`.cpp`), plus auto-demotes any human
  faction and auto-advances End Turn (`Console_end_my_turn`, wired
  experimentally). **Gates on `conf.autoplay` alone, not `is_human`** — fine
  for an all-AI session, but dismisses a real human's own dialogs too if one
  is present. Two dialog classes remain unfixable this way (they live
  entirely inside the un-decompiled engine binary, not reachable by
  redirecting a global function pointer): the monolith-inspection popup
  (worked around via a preference flag) and the tech-discovery announcement
  (no workaround, still needs a manual click, lower frequency than End Turn
  was — a real fix needs disassembly/`write_call`-patching not done).
- **Probe-mission popup flood, root-caused and fixed 2026-07-24.** Live
  autoplay (`conf.autoplay=1`) still showed dozens of popups per run, several
  per turn once probe teams became common — invisible in `autoplay.log`,
  proving they bypassed every shim above (`is_human` gates alone don't
  explain it: `autoplay_demote_human()` already made every one of
  `probe.cpp`'s *decision* dialogs — `EXCUSE`/`PACTEXCUSE`/the probe-action
  menu, via `BasePop_exec_2`/`_3` — unreachable for the whole game, so those
  were never the actual problem). Root cause: `probe.cpp`'s *mission-report*
  messages (`BUSTED`, `STOLENOTHING`, `GOTENERGY`/`TOOKENERGY`,
  `PROBECAUGHT`, `ASSASSINATED`, `FRAMEJOB`/`FRAMED`, `DRONEINCITE*`, …) go
  through `NetMsg_pop`/`NetMsg_pop_2`, gated only on `veh_fc_id ==
  MapWin->cOwner || tgt_fc_id == MapWin->cOwner` — `MapWin->cOwner` stays
  pinned to the original New-Game human pick for the whole session,
  untouched by demotion, so any probe mission touching that faction (either
  side) still popped. Fixed by adding `NetMsg_pop`/`NetMsg_pop_2` as a 10th
  and 11th shimmed primitive, same mechanism as the other nine (`src/
  autoplay.h`/`.cpp`, `api_version`-independent — engine-side only, no Lua
  involved). Safe uniform default (log + return 0, no real popup): confirmed
  by grep that no caller anywhere in the codebase consumes either function's
  return value, unlike `BasePop_exec_2`/`_3` (real decision outcomes, e.g.
  `FREEWHO`'s `capture_id` — deliberately left unshimmed since they're
  already unreachable via `is_human` and a wrong uniform default would
  silently change game state). `NetMsg_pop` is also the general "flash a
  message" primitive used ~150 places outside `probe.cpp` (combat, goodie
  pods, morale, terraforming, …) — shimming it quiets those too. Live-
  confirmed (2026-07-24): user-run autoplay session showed the probe flood
  gone, `NetMsg_pop label=... delay=...` lines appearing in `autoplay.log`
  instead of blocking popups.
- **Tech-discovery announcement, root-caused 2026-07-24** (previously
  "still open… needs disassembly work not done", `IMPLEMENTATION_PLAN.md`
  Phase 5.3 intro / diary 2026-07-14). Confirmed by disassembly (`objdump
  -d`, `terranx.exe`, no relocation/ASLR — file addresses equal runtime
  addresses, matching every other hardcoded address in this codebase) that
  `tech_achieved` (`0x5BB000`, entirely un-decompiled — `Ftech_achieved
  tech_achieved = (Ftech_achieved)0x5BB000` with no Thinker-side
  reimplementation, unlike `probe()`) contains **its own embedded calls to
  the raw popup-primitive addresses**, bypassing every redirectable global
  in `engine.cpp` entirely (autoplay.h's standing point: "redirecting the
  variable is not the same as redirecting the function" — this is that
  same architectural gap, just not yet exploited by a real fix before now).
  One such internal call (`0x5BBEB0`, originally `X_pop_2`) was *already*
  `write_call`-patched to `tech_achieved_pop3` pre-2026-07-24 for an
  unrelated reason (skip the `SOCIETY` SE-model dialog while diplomacy is
  open) — proving the technique already works inside this exact function,
  just not applied to the announcement itself.
  - **Method**: `objdump -d -M intel --start-address=0x5bb000
    --stop-address=0x5bd400 terranx.exe`, grep every `call 0x<addr>`
    instruction, cross-reference targets against the full table of known
    raw popup addresses in `engine.cpp` (`POP2`/`popp`/`popp_2`/
    `interlude`/`X_pop`/`X_pop_2`/`X_pop_9`/`X_pops`/`X_pops_18`/
    `BasePop_exec`/`_2`/`_3`/`NetMsg_pop`/`_2` — every one of them has a
    fixed, documented address). Found 15 internal popup calls total inside
    `tech_achieved`: 1×`popp` (`SOCIETY`/`SEEMAP2` — a second, unguarded
    path to the same dialog `0x5BBEB0` already partially covers), 5×
    `interlude` (event IDs 1/2/0xf/0x10/0x24 — likely per-tech cutscene
    triggers, condition not fully decoded), 4×`X_pop`
    (`WEGETSHARETECH`/`ASKSEEDESIGN`×2/one buffer-text call), 1×`X_pop_2`
    (`TREETIME`, the one *not* already covered by the `SOCIETY` patch),
    1×`BasePop_exec_3` (a real decision dialog, arguments/branch not
    decoded), and **3×`NetMsg_pop`** — resolved their label-string
    arguments by reading `.data` directly (`objdump -s
    --start-address=<addr>`): `TECHOBTAINED` (`0x5BBA0E`), `FREEFACTECH`
    (`0x5BBB10`), `FREEABILTECH` (`0x5BBBE2`) — the actual "faction X has
    acquired technology Y" banners, confirmed to fire on every single tech
    (researched or granted), exactly matching what was reported live as
    "the tech acquisition popup."
  - **First pass fixed**: the 3 `NetMsg_pop` sites, via 3 new `write_call`
    lines in `patch.cpp` pointing directly at the already-existing,
    already-tested `autoplay_netmsg_pop` (no new shim function needed —
    exact same ABI, drop-in ready). `write_call` self-validates the target
    address holds a real `0xE8` call opcode before patching (`exit_fail`
    otherwise) — wrong-address risk is a loud startup failure, not silent
    corruption. **This alone proved insufficient, confirmed by a live run**
    (2026-07-24): popups persisted, and `autoplay.log` showed zero
    `TECHOBTAINED`/`FREEFACTECH`/`FREEABILTECH` lines despite ~50 turns and
    confirmed tech-research activity (`tech_pick`/`tech_val` in
    `debug.txt`) — proving the branch these 3 patches cover simply wasn't
    the one being hit. Re-reading the disassembly: the branch guarding
    `TECHOBTAINED` (`0x5BBA0E`) only fires when the achieving faction
    equals one specific tracked global (`ds:0x939284`); every other
    faction's completions — the common case with 7 AI factions in an
    autoplay game — fall through to a **second, unshimmed path**:
    `BasePop_exec_3` at `0x5BBA37`, a real dialog call, not a toast.
    Confirmed by disassembly that *this specific call site's* return
    value is discarded by the caller (`xor eax,eax` immediately follows
    the call, at `0x5BBA3F`, never read before being overwritten) —
    unlike `BasePop_exec_2`/`_3`'s other call sites (`probe.cpp`,
    `veh_action.cpp`, `base.cpp`), which do consume the choice and remain
    deliberately unshimmed. Fixed with a 4th targeted `write_call`
    (`0x5BBA37` → a new `autoplay_tech_achieved_basepop3`, `src/
    autoplay.h`/`.cpp`) — single call-site patch, not a redirect of the
    global `BasePop_exec_3` pointer, so those other call sites are
    unaffected. Build-verified both presets, deployed; **not yet
    live-tested** — this was the second round-trip on this exact gap, so
    don't assume it's the last branch either until confirmed clean.
  - **Still deliberately not fixed**: the remaining 11 internal calls.
    Different risk profile — the `X_pop_2`/`popp` (`SOCIETY`) calls carry
    real decision outcomes (same class of risk as `BasePop_exec_2` in
    `probe.cpp`, left unshimmed there for the same reason: a uniform
    default could silently change game state), and the 5 `interlude`
    event-IDs and remaining `X_pop` calls weren't decoded far enough to be
    confident what condition gates them or how frequently they actually
    fire. **User direction (2026-07-24): don't bother** — `interlude`
    popups have an existing in-game preference toggle to disable them, so
    this residual gap doesn't need chasing further via disassembly.
  - **Second live run (with the `BasePop_exec_3` fix) still showed
    popups, and still zero matching lines in `autoplay.log`** (`TECHOBTAINED`/
    `FREEFACTECH`/`FREEABILTECH`/`BasePop_exec_3 (tech_achieved)` all
    absent) — proving `tech_achieved` wasn't the actual source being hit
    at all, despite being the function this whole investigation started
    from. **Real root cause, found via a completely different route**:
    the engine already exposes a documented suppression flag,
    `SkipTechScreenA` (`0x945F40`, "non-zero skips popups, used in
    `tech_achieved` and `tech_advance`" — `src/engine.cpp:159`), and
    Thinker's own code already uses it (`src/game.cpp:1921-1925`, wrapping
    the turn-1 starting-tech grant loop). `tech_advance` (`0x5BE530`,
    also entirely un-decompiled, a *different* function from
    `tech_achieved`) is the actual per-turn research-completion call —
    `src/tech.cpp:178` and `:191`, inside the periodic tech-accumulation
    upkeep, unconditionally, once per faction per turn once accumulated
    research crosses the threshold. This is the real dominant path (every
    faction, every turn a tech completes), far more universal than any of
    `tech_achieved`'s narrower branches — explains why chasing
    `tech_achieved` branch-by-branch never converged. Fixed by wrapping
    both call sites (plus `src/base.cpp:3976`'s `FAC_UNIVERSAL_TRANSLATOR`
    facility, a third, rarer `tech_advance` call site with the same gap)
    with `if (conf.autoplay) *SkipTechScreenA = 1; tech_advance(...); if
    (conf.autoplay) *SkipTechScreenA = 0;` — no disassembly, no
    `write_call`, just the engine's own documented flag, gated on
    `conf.autoplay` so normal play is unaffected (unlike `game.cpp`'s
    unconditional use for turn-1 setup, where suppression is always
    wanted). `map.cpp:1944`'s `tech_advance` call (a `time_warp_mod`
    scenario path) already guards with the sibling flag `SkipTechScreenB`
    — no gap there. Build-verified both presets, deployed; not yet
    live-tested. **Methodological note for next time**: should have
    grepped every `tech_advance`/`tech_achieved` call site in Thinker's
    own recompiled code *before* reaching for disassembly — the fix that
    actually worked needed no reverse engineering at all, and the existing
    `SkipTechScreenA`/`B` convention in `game.cpp`/`map.cpp` was sitting
    in the codebase the whole time.
  - **Third live run (30 turns) still showed 2 popups** — user's own
    hypothesis (diplomatic tech trade / unity pods) turned out right, and
    exposed the real shape of the gap: `tech_achieved` is called directly
    (not via `tech_advance`) from several other sites in Thinker's own
    recompiled code that weren't guarded — `veh.cpp:1611`/`:1954` (pod
    tech grants), `probe.cpp:1249` (probe-stolen tech), `faction.cpp:766`
    (diplomatic/pact tech sharing), `faction.cpp:2190-2204` (initial-spawn
    faction bonus techs), `net.cpp:124` (`net_tech`, the non-multiplayer
    branch). **Confirmed by disassembly this time, not guessed**: at
    `0x5BB490`/`0x5BB49D` (near the very start of `tech_achieved`,
    `ds:0x945F40` == `SkipTechScreenA`), the function does `je 0x5BCAB3` /
    `jne 0x5BCAB3` — both branches converge on the *same* target, right
    after one of the function's `ret`s. Every one of the 15 popup calls
    catalogued above falls inside `[0x5BB4A3, 0x5BCAB3)`. So
    `SkipTechScreenA` doesn't gate one branch, it **skips this entire
    middle chunk of the function outright** — confirms its doc comment
    ("non-zero skips popups") literally, and means the write_call patches
    above were always narrower than necessary: guarding the *caller* is
    both simpler and strictly more complete than patching individual
    internal addresses one at a time. Fixed by wrapping all 6 remaining
    call sites the same way as `tech.cpp`'s. `net.cpp` needed nothing
    extra (`net.h` already pulls in `main.h` for `conf`). Build-verified
    both presets, deployed; not yet live-tested. The 4 earlier write_call
    patches are now redundant whenever the caller properly sets the flag
    (execution never reaches those addresses) but harmless to leave as a
    safety net for any caller that doesn't.
  - **Fourth live run (30 turns) still showed 2 popups — user supplied
    the exact on-screen text this time** ("WE HAVE ACQUIRED
    TECHNOLOGY!"), which finally broke the guessing cycle. That string is
    *not* in any named-label text file (`modmenu.txt`, `alphax.txt`, …)
    that `TECHOBTAINED` and friends resolve through — it's `labels.txt`
    line 553 (`RESEARCH BREAKTHROUGH` / `OUR RESEARCHERS HAVE MADE A
    BREAKTHROUGH!` / `WE HAVE ACQUIRED TECHNOLOGY!`, lines 551-553), an
    older **index-based** text system, proving this popup was never
    `tech_achieved` at all — a completely different function. Traced it
    to `mon_tech_discovered` (`0x476C90`), called from `tech.cpp` lines
    183/198 right after `tech_advance()`, **outside** the
    `SkipTechScreenA`-guarded block (that guard only wraps `tech_advance`
    itself) — and confirmed by disassembly this function has no
    `SkipTechScreenA` check of its own at all. Its only externally-visible
    call, gated by the same `achieving faction == ds:0x939284` pattern
    seen throughout `tech_achieved`, targets `0x476A50` — which turned out
    to already be declared in this codebase as `monument`
    (`void __cdecl(int)`, `src/engine.cpp:401`) with **zero callers
    anywhere in Thinker's own recompiled code** until now (upstream had
    already named/typed the raw function but never wired it to anything).
    `void` return — nothing to discard, so uniform suppression needed no
    return-value analysis this time. Fixed with a 6th targeted
    `write_call` (`0x476D85` → new `autoplay_monument`, forwards to the
    real `monument` when `!conf.autoplay`). Build-verified both presets,
    deployed; not yet live-tested.
  - **Fifth live run: the exact same popup still fired even with the
    `monument` patch in place.** `objdump -d terranx.exe | grep
    'call.*0x476a50'` (searching the *whole* binary, not just
    `tech_achieved`'s address range this time) found **18 total call
    sites** to `monument`, not one — a whole family of sibling
    "`mon_X_discovered`"-style world-event announcers (tech breakthroughs
    are just one category among presumably several "first to..."
    achievement types), each a raw address embedded independently, none
    reachable through the single `0x476D85` site patched before. One
    (`0x5BBC14`, inside `tech_achieved`, calling a sibling wrapper at
    `0x476DA0` which itself reaches `monument` at `0x476ED0`) is already
    covered whenever the caller sets `SkipTechScreenA` correctly; the
    other 16 are not provably covered by anything already in place, and
    two (`0x51A852`, `0x51C327`) are far outside this address cluster
    entirely, likely a different subsystem. Rather than tracing each
    caller individually again, redirected **all 17 remaining sites** to
    `autoplay_monument` (`src/patch.cpp`) — safe uniformly because
    `monument` is `void`-returning everywhere and, for autoplay
    specifically, correctness doesn't depend on which achievement type
    triggered it: any popup defeats unattended play regardless. Every
    address re-verified by diffing the patched list against a fresh
    `objdump` extraction (no manual retyping) before building — with 18
    `write_call`s in one pass, `write_call`'s self-validation (loud
    `exit_fail` on any address that isn't a real `0xE8` call to the
    expected target) is the safety net if any single one were wrong.
    Build-verified both presets, deployed; not yet live-tested.
  - **Standing lesson across all 5 rounds on this one gap**: when static
    analysis stalls, ask the user for the literal on-screen text before
    guessing another call site — it took one exact string to jump straight
    to the right *function* on the 4th try, and finding *every* caller of
    that function (not just the one reached from the known code path)
    was still needed on the 5th. Each earlier fix was real and worth
    keeping, but none of them was *this* popup until the full 18-site
    picture was in hand.
  - **Sixth live run: still fires, repeatedly. Live gdb attach attempted
    (2026-07-25).** `sudo gdb -p <pid>` (needed because `ptrace_scope=1`
    blocks attaching to a non-child process without it) successfully
    attached and resolved all candidate raw popup addresses correctly
    (proof the address model is right), but **Wine ≥ 11's WoW64
    architecture broke the resume-after-breakpoint step**: gdb logs
    `warning: Selected architecture i386:x86-64 is not compatible with
    reported target architecture i386:x64-32` on attach, and continuing
    past a software breakpoint (`X_pop_engine`/`PLANETFALL`, a real,
    correctly-caught hit unrelated to this bug) crashed the process with
    SIGSEGV at the breakpoint's own address — Thinker's own crash handler
    caught it and wrote a diagnostic dump to `debug.txt` (`EIP 005bf310`).
    **Correction: the game recovered fully, not just cosmetically** — the
    autoplay session continued normally afterward all the way to its
    planned turn 50, and turn logging did continue past that point (an
    earlier draft of this entry wrongly assumed logging had stalled and
    that the session was left in a suspect state; it hadn't — that
    assumption was wrong and has been corrected here). `set architecture
    i386:x64-32` before inspecting did not improve backtraces — background
    threads are all parked inside symbol-less Wine host binaries (`?? ()`
    frames, backtrace unwinding fails immediately past frame 0)
    regardless, so gdb never yielded a usable call stack for the actual
    popup-showing code.
    **A passive, read-only attach (no breakpoints, just examining fixed
    global addresses) is safe and did work**: read `StrBuffer`/
    `ParseStrBuffer` (`0x9B86A0`/`0x9BB5E8`) live while a "WE HAVE
    ACQUIRED TECHNOLOGY!" popup was on screen and found `ParseStrBuffer`
    containing `"Biogenetics"` — **confirmed genuine** (the popup was
    real, for that real tech; not a stale/corrupted artifact as
    speculated in an earlier draft of this entry). `debug.txt` still had
    no `Biogenetics`-mentioning lines to correlate against, so this by
    itself didn't identify the triggering function, but it does confirm
    the memory-inspection technique is sound. **Confirmed after resuming
    autoplay: further instances of this same popup kept appearing for the
    rest of the run** (session-wide, not a one-off) — this remains a
    real, frequent, unresolved bug, not an artifact of the gdb session.
    **Root cause remains unidentified.** If retried in a future session:
    don't set software breakpoints on this WoW64 build (confirmed to
    crash on resume, though recovery from that crash turned out to be
    clean); a passive attach + register/memory dump at the moment the
    popup appears is the only demonstrated technique so far, and hardware
    watchpoints (`watch`, not `break`) on `StrBuffer`/`ParseStrBuffer`
    were never tried and might survive a resume since they don't patch
    code bytes — worth trying next, and safe to try on a process that
    already had a software breakpoint cycle (recovery is clean, per the
    correction above).
  - **Strategy change (2026-07-25): stop chasing individual popup sources,
    dismiss generically instead.** After six rounds of disassembly still
    left this one announcement (and, by construction, any future
    not-yet-found one) able to block autoplay, switched approach: rather
    than finding and redirecting every raw call site, detect "some window
    other than the map/base/design screen currently has focus" and inject
    a synthetic Enter keypress, mirroring how `autoplay_try_end_turn`
    already handles End Turn the same way (call the *effect*, don't chase
    every trigger). Built on two pieces already in this codebase:
    `Win_get_key_window()` (`0x5F6A50`, previously read-only, used by
    gui.cpp's own `current_window()` to classify focus as `GW_World`/
    `GW_Base`/`GW_Design`/`GW_None`) and the `PostMessage(hwnd,
    WM_KEYDOWN/WM_KEYUP, key, 0)` pattern already proven working
    (non-autoplay) at `gui.cpp`'s `WM_MOUSEWHEEL`-to-arrow-key
    translation. New: `gui.h`/`gui.cpp`'s `win_dialog_open()` (a 3-line
    wrapper exposing `current_window() == GW_None`) and
    `autoplay.h`/`.cpp`'s `autoplay_dismiss_dialog()` (posts a synthetic
    `VK_RETURN` to `*phWnd`, the game's single real Win32 window handle,
    already declared at `gui.cpp:83`, `0x9B7B28`, extern'd for reuse),
    wired into `mod_blink_timer` alongside `autoplay_try_end_turn` (same
    idle-callback cadence). **EXPERIMENTAL, unverified — same disclaimer
    `autoplay_try_end_turn` shipped with**: `GW_None` covers "some other
    window has focus," which in a fully-autoplay all-AI session should
    only ever be a blocking dialog, but isn't proven exhaustive; sending
    Enter could in principle confirm/submit something unintended on a
    window this reasoning doesn't actually cover.
    **Live-verified (2026-07-25): 3 separate autoplay runs, zero blocking
    popups, zero crashes.** This is now the standing mechanism for popup
    dismissal — future not-yet-catalogued announcements should be covered
    by construction, not by adding more individual `write_call` patches.
  - **Standing disposition of the chased-individually fixes above**: all
    real, verified improvements (probe-mission `NetMsg_pop`/`NetMsg_pop_2`
    global shim, the 3 `tech_achieved` `NetMsg_pop` sites, its
    `BasePop_exec_3` site, the 6 direct `tech_achieved` callers'
    `SkipTechScreenA` guards, `monument`'s 18 sites) — kept regardless of
    how `autoplay_dismiss_dialog` pans out, since they reduce *how often*
    dismissal is even needed, which still matters (each dismissal is a
    real synthetic input event, not free).
  - **Remaining manual-intervention point identified (2026-07-25): the
    Planetary Council.** Confirmed live (one of the 3 clean runs above):
    `autoplay_dismiss_dialog`'s generic Enter-dismiss does *not* resolve a
    Council interaction — it still required a manual click, despite the
    mechanism being active. Root cause not chased into `CouncilWindow`
    itself (`0x6FEC80`, `typedef GraphicWin CouncilWindow` — zero
    reverse-engineering investment in this codebase, unlike `BasePop`/
    `Popup`, which have dozens of already-mapped methods; would likely
    need another multi-round disassembly effort like the tech-announcement
    saga above, this time for a subsystem with real strategic stakes
    — electing a Planetary Governor, Global Trade Pact, Melt Polar Caps,
    etc., `enum CouncilProposal`, `engine_enums.h`). Found a much better
    fix instead: `can_call_council` (`0x52C670`) tests a real, documented
    scenario-rules flag — `MRULES_NO_PLANETARY_COUNCIL` (`0x4`, applies to
    `GameMoreRules`/`0x9A681C`) — and returns false unconditionally when
    set (confirmed by disassembly: `0x52C695 test byte ptr
    ds:0x9a681c,0x4` → early `xor eax,eax; ret`). Also fixed in passing:
    `call_council` (`0x52C880`, invoked unconditionally for every
    non-human faction every eligible turn — `game.cpp:1672-1673`) had its
    own embedded, unshimmed `NetMsg_pop` call (`0x52CC99`, "SIMULNO"
    label) — same raw-address-bypasses-the-global gap as everywhere else,
    patched to `autoplay_netmsg_pop` like the rest.
  - **User-confirmed tradeoff, deliberate (2026-07-25): force
    `MRULES_NO_PLANETARY_COUNCIL` whenever `conf.autoplay` is on**
    (`autoplay_demote_human()`, alongside the existing
    `MPREF_AUTO_ALWAYS_INSPECT_MONOLITH` force). Unlike every other
    autoplay fix in this file, this is not "hide the UI, mechanic still
    happens underneath" — it disables Planetary Council outright for the
    whole session (no faction ever calls or votes). Accepted explicitly
    because autoplay's job is unattended testing, not full mechanic
    fidelity, and this is far lower-risk than simulating a real vote
    through a UI class with no prior investigation. **Revisit only if a
    future session specifically needs Council mechanics exercised under
    autoplay** — at that point the right move is investigating
    `CouncilWindow`'s actual modal-loop/focus behavior (candidate leads:
    does it even pump `WM_TIMER` while its own loop is active — if not,
    `autoplay_dismiss_dialog`'s reliance on `mod_blink_timer` firing
    explains the observed failure outright, and a synthetic keypress
    would need a different injection point), not by reapplying the
    generic dismiss mechanism as-is. Build-verified both presets, deployed.
    **Live-verified (2026-07-25): 100-turn autoplay run completed with
    zero manual intervention.**
  - **Milestone: unattended autoplay achieved.** The full chain that got
    here (probe-mission popups → `NetMsg_pop`/`NetMsg_pop_2` global shim →
    `tech_achieved`'s internal `NetMsg_pop`/`BasePop_exec_3` sites →
    `SkipTechScreenA` at every direct `tech_achieved` caller → `monument`'s
    18 sites → the generic `autoplay_dismiss_dialog` mechanism →
    `MRULES_NO_PLANETARY_COUNCIL`) is finished as of this 100-turn clean
    run. Future sessions: a genuinely new blocking dialog should already
    be caught by `autoplay_dismiss_dialog` (it's generic by construction);
    only add another individually-chased fix if that generic mechanism is
    confirmed *not* to catch a specific new case, the way Council's own
    modal loop turned out not to.
- **`tools/autoplay_run.sh --no-xvfb [--lua-shadow] [--golden-trace]
  [--rng-seed N]`**: deploy → force `thinker.ini` settings → launch → poll
  `lua.log`'s `state_hash turn=N` line as a progress signal → classify
  COMPLETED/STALL/CRASH → collect logs to `runs/<timestamp>-<preset>/` →
  restore the original `thinker.ini`. **Known gap, still open:** cannot
  bootstrap into an in-progress game on its own — no flag skips the New
  Game/Load menu, so one manual click is still needed to reach a running
  game before the harness's own automation takes over. **Xvfb (headless)
  does not work on the dev machine** — every launch dies ~1-2s in,
  regardless of graphics config, confirmed not a DirectDraw/PRACX issue
  specifically (plain `wine notepad` survives fine under the same Xvfb); no
  replacement hypothesis found or needed, since `--no-xvfb` on the real
  desktop already satisfies every validation this project runs. Only matters
  again if parallelizing runs becomes an actual goal.
- **`state_hash` per-turn dump** (`lua/harness/state_hash.lua`): index-ordered
  hash of every base/veh/faction's key fields, FNV-1a-style mix using only
  `bit.bxor`/`bit.rol` (no multiply — avoids a double-precision rounding
  question a textbook FNV multiply step would raise on a Lua number).
- **`fixed_rng_seed`**: pins the mod's own LCG seed (normally
  `GetTickCount()`-derived) across launches. **Cross-launch full-trajectory
  determinism was chased and then explicitly abandoned as a goal** (decision
  recorded 2026-07-16, not a bug left open) — even with the seed pinned and
  `game_rand_restore()` added, two identical-save launches diverge starting
  turn 3 (traced one contributing mechanism: single-player pod-opening draws
  from the shared sequential RNG stream, so it depends on every other AI
  faction's own turn-1 draws). This is *not* covered by the project's
  "bit-exact only where achievable" Lua-vs-C++ tolerance framing — it's a
  single C++ binary diverging from itself, i.e. engine-internal
  nondeterminism, out of this project's charter to chase further. Shadow
  mode (5.1) needs none of this and is the actual validation mechanism now.
  The only future consumer of any trajectory-style comparison is a
  hypothetical *windowed* method for Movement (reload once, compare exactly
  one turn) — its prerequisite, single-turn reproducibility, is already
  satisfied (turns 1–2 come back byte-identical with the seed + restore in
  place). Do not restart general determinism-chasing without a concrete
  trigger tracing back to that windowed method actually failing.

### 5.4 Performance instrumentation

Not yet built. Plan: wrap AI phases in `mod_turn_upkeep`/`move_upkeep`/
production loops with `GetTickCount()` deltas per faction per turn (debug
builds); baseline the C++ numbers before any further movement work if
performance becomes a concern; `jit.p`/`jit.v`/`jit.dump` to watch for trace
aborts from host-API calls inside hot loops (batch queries / hoist the C
call / move loop-body data to FFI reads if this appears).

---

## Phase 6 — docs, packaging, CI (not started)

- Packaging: add `lua/` sync to `tools/makedevzip.sh`/`makerelzip.sh`/
  `deploy.sh`.
- CI sketch: ubuntu-latest, mingw-w64-i686 + gcc-multilib, build LuaJIT,
  both CMake presets, `luacheck lua/` + integer-expression lint,
  `luajit lua/test/run.lua` (golden-trace replay).
- Docs to write: `docs/LUA_API.md` (full API reference); `docs/LUA_PORTING.md`
  already exists (started 4.11) but needs the module-checklist table kept
  current as Movement closes.
- "Hello AI" example: override one Class-1 hook, small enough to read in one
  sitting.

---

## Known traps (collected)

1. **Never init Lua in `DllMain`** — loader lock. Lazy init from
   `mod_turn_upkeep` (2.3).
2. `Vehs`/`Bases` are re-pointable — never bake their addresses into Lua (3.2).
3. `PMTable`/`NodeSet` are STL — host accessors only (3.4).
4. Engine structs have C++ methods — cdefs need field-only generation, done
   by the compiler-based generator, never by parsing (3.1).
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
    just AI factions (5.3).
14. A hand-transcribed enum (windows.h-blocked headers) that's referenced but
    never actually added to `gen_ffi.cpp`'s emit list is `nil`, not an error,
    until the exact branch runs live — happened 3 times across movement
    stages 4-5 (3.1). Grep the generated `types.lua` to confirm a batch of
    new constants actually landed.
15. A host wrapper's declared C return type determines the Lua-side idiom:
    `bool`-declared wrappers return real Lua booleans (never `~= 0`); raw
    `int32_t` wrappers need the `~= 0`/`== 0` idiom (Lua's `0` is truthy,
    unlike C). Mixing these up is silent and has shipped at least twice
    (`has_project`, `has_pact`) in already-"closed" code (4.10, 4.15).
16. An FFI wrapper with output-pointer parameters (`tile_neighbor(x,y,i,
    tx,ty)`-style) is not the same calling convention as a Lua
    multi-return — calling it with too few arguments silently passes NULL
    for the missing pointer instead of erroring, and a host-side
    unconditional write through it is an uncatchable native crash, not a
    `pcall`-able Lua error (4.13). Check a wrapper's real arity in
    `funcs.lua` before writing a new call site, don't pattern-match a
    similar-looking one.
17. "Live-verified clean" only covers the branches actually exercised that
    specific run — a bug in an unreached sub-condition survives indefinitely
    (4.15). Absence of a mismatch line is not evidence of correctness unless
    there's independent proof the branch fired (Phase 5's own methodology
    note, `IMPLEMENTATION_PLAN.md`'s Phase 5 intro).

## Launch with:
WINEPREFIX=~/.wine-smac wine ~/.wine-smac/drive_c/Games/SMAC/thinker.exe
