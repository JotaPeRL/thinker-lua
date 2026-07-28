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

### 4.12–4.17 Movement (porting-order item 4) — ✅ all stages 0–8 closed; 0–7 live-verified, 8 pending live exercise

Full narrative for every stage below (exact field/enum/wrapper catalogs,
`api_version` history, verification run counts, files-touched lists, every
bug hunt): `DEVELOPMENT_DIARY.md`, 2026-07-20 through 2026-07-28. What
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

### 4.16 Stage 7 — faction-level orchestration (`land_raise_plan`/`invasion_plan`/`update_main_region`/`goal.cpp`) — ✅ closed, live-verified

Sub-staged 7A–7D (this file's own numbering, `IMPLEMENTATION_PLAN.md`
doesn't commit to sub-stage letters). All four done and live-verified.

**Truthiness bug (found and fixed live-testing, 2026-07-28):** several
`lua/ffi/funcs.lua` wrappers (`tile_is_ocean`, `tile_is_land_region`,
`tile_is_base`, `tile_is_base_radius`, `allow_move`, `has_ships`, …)
already convert the host API's raw `int32_t` into a real Lua boolean
(`return api.x(...) ~= 0`) — a deliberate convention used correctly
almost everywhere in `move.lua`. 7C, 7D and stage 8 (ported together)
instead re-compared several of these already-boolean results against `0`
(`== 0`/`~= 0`), which in Lua is always false/always true regardless of
the real value (no coercion between booleans and numbers). 11 call sites,
all confined to 7C/7D/8, had this pattern; the worst was `invasion_plan`'s
own `enemy` flag (`move.cpp:683` / `move.lua`'s `tile_is_ocean(...) == 0`
check) — always false, so `invasion_plan` returned before its real logic
on *every* call, in every game, independent of any war state. Found via
live-play evidence: 4 full-length autoplay runs (up to 200 turns, clear
wars, heavy combat) with zero `invasion`-decision log lines, which the
maintainer correctly read as "this looks like a bug, not bad luck" rather
than a coverage gap. Fixed by dropping the redundant comparison (`== 0` →
`not funcs.x(...)`, `~= 0` → bare `funcs.x(...)`) at all 11 sites,
including `has_ships`'s own gate (previously *always* false too, which in
that spot made `invasion_plan` wrongly skip its early-return for
non-naval factions — the opposite failure mode, over-permissive rather
than blocking). Re-verified: a 200-turn run fired `invasion` 1437 times,
`trans_invade` 154×, `colony_naval` 1046×, `trans_start` 88×,
`combat_invade` 25×, `combat_escort` 4×, 0 shadow-mode mismatches, 0
errors. This is a distinct bug class from the earlier `has_pact`
truthiness bug (stage 6, `IMPLEMENTATION_DETAILS.md` 4.12–4.15): that one
was a wrapper returning a raw int used as a Lua truthy value (`0` is
truthy in Lua); this one is the mirror case, a wrapper already returning
a real boolean being re-compared as if it were the raw int. Neither
shadow mode nor `luajit -bl` catches either shape — Class 3 hooks are
never shadow-run, and both are syntactically valid Lua.

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
- **7B (`land_raise_plan`)** — ✅ done, **live-verified** (its own code
  wasn't affected by the truthiness bug above; confirmed independently by
  `raise_goal` decision lines firing every run since testing began, tens
  to low hundreds per 200-turn game). `move.cpp:519-629`. New engine
  surface: `can_alter_level`
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
- **7C (`invasion_plan`)** — ✅ done, **live-verified** (2026-07-28, after
  the truthiness-bug fix above — this was the stage whose own `enemy`
  flag the bug permanently zeroed). `move.cpp:663-763`. Confirmed the 7A
  prediction: reused
  `target_priority` (stage 6) and 7A's `pick_scout_target`/
  `region_search_start_multi`/`region_search_next`/`region_search_get_route`/
  `find_priority_goal`/every `naval_*` plans[] setter directly — **zero new
  host-API surface**, only two hand-added enum constants
  (`AI_GOAL_NAVAL_END`/`AI_GOAL_NAVAL_SCOUT`, `engine_enums.h`, compiler-read
  like `AI_GOAL_RAISE_LAND`, not hand-transcribed numeric literals since
  that header isn't windows.h-blocked). Same hook shape/site convention as
  7B (`lua_ai_command_hook_faction`, hooked at the `move_upkeep` call site).
  - **A real C++ `continue` inside the `while` loop skips a *second,
    independent* check** (the scout-target block, written after/outside the
    scoring `if`) — not just the scoring itself. Lua has no `continue`;
    replicated with a `do_continue` flag set inside the scoring branch and
    checked before the scout-target block, rather than restructuring into
    nested `if/elseif` (this file's usual no-`goto` idiom) since the two
    blocks aren't mutually exclusive branches of the same condition. Read
    the *whole* function's control flow before assuming an `if/elseif`
    restatement is sufficient — this is the kind of gap the
    `former_move`/`combat_move` bug hunts were caused by.
  - **`p.naval_end_x`/`_y` read back via their getter after the loop**,
    not tracked in a local Lua variable — matches the original reading
    a *persistent* `plans[]` field (set on a previous call, possibly
    turns ago, if this call's loop never found a better score) rather
    than a fresh per-call local. A local shadow variable initialized to
    `-1` each call would have silently diverged from the original the
    first time a turn's `invasion_plan` call didn't update it.
  - `random(n)` → `rand.map(0, n)`, not `rand.map(n)` — confirmed against
    `pick_scout_target`'s own already-verified `random(16)` →
    `rand.map(0, 16)` translation before reusing the pattern here.
- **7D (`update_main_region`'s `prioritize_naval` decision)** — ✅ done,
  **hook invocation confirmed live since early testing; internal branch
  coverage still unconfirmed** (the function has no `log.debug` of its
  own, so which of its two branches ran isn't visible in the log — same
  blind spot as `route_score` before it got one). Its own `at_war`/
  `tile_is_ocean` check had the same truthiness bug as 7C (now fixed,
  see above), so the early-return-at-10-hostile-tiles branch was
  unreachable until 2026-07-28. `move.cpp:806-827`, the
  tail of `update_main_region` (`move.cpp:769-828`). Zero new host-API
  surface again — `region_search_start` (single-point, already exercised
  by `land_raise_plan`'s own first scan), `main_region_x`/`_y` getters,
  `set_prioritize_naval`, and `TS_TERRITORY_SHORE`/`MaxEnemyRange` were
  all already in place from 7A (`TS_TERRITORY_SHORE`'s own hand-
  transcription comment in `gen_ffi.cpp` literally named
  `update_main_region` as its future consumer).
  - **Different hook shape from 7B/7C**: `update_main_region` isn't a
    separately-callable function the way `land_raise_plan`/`invasion_plan`
    are — it's one function that does bulk fact computation (reset every
    faction's `main_region*` fields, then recompute them from a base
    scan) *and* the one real decision (`prioritize_naval`) in the same
    body. Only the decision tail is a hook candidate (Phase 4.3's opaque-
    wrapper criterion: the reset/recompute preamble is deterministic
    bookkeeping, not a choice). Hooked *inside* `update_main_region`'s own
    body, right after the `if (p.main_region < 0) return;` guard — the
    original Phase 4.1 seam-inside-a-function-body shape, which land_
    raise_plan/invasion_plan (hooked at their own external call sites)
    didn't end up needing.
  - The C++ early-return inside the hook's own fallback body
    (`p.prioritize_naval = 0; return;` when 10 nearby at-war land tiles
    are found) works unchanged as the *fallback* path — the hook wraps
    the whole decision block, so Lua's equivalent early-return (calling
    `set_prioritize_naval(faction_id, 0)` then `return`) is a normal Lua
    `return`, no special handling needed for the fact that the original
    exits the whole outer C++ function from inside a nested loop.
- `move_upkeep`'s own map/unit/base sweep (`move.cpp:852-1141`) and its
  goal→mapnode bookkeeping tail (`1157-1180`) stay C++ (fact computation,
  Phase 4.3) — only the `land_raise_plan(faction_id); invasion_plan
  (faction_id);` call site (`UM_Full` branch) and `update_main_region`'s
  own internal decision tail get hooks (all of stage 7 as of 7D).

`IMPLEMENTATION_PLAN.md` describes stage 7 as one unit without committing
to sub-stage letters; this file's own 7A–7D / 0–8 numbering is the
authoritative staging if a number is needed.

### 4.17 Stage 8 — `nuclear_move` — ✅ done, build-verified; still not live-exercised

`move.cpp:2735-2896`, the last Movement mover, ported in full. Same
per-vehicle Class 3 hook shape as every other mover (not faction-level
like stage 7) — hooked at its own call site in `veh_turn.cpp`'s
`mod_enemy_move` (`is_planet_buster()` branch), same convention as
`combat_move`/`trans_move`/etc.

**Real complexity was in the scoring formulas** (cross-faction
diplomatic/threat tallies, a full secret-project iteration over
`SP_ID_First..SP_ID_Last`), not new engine surface — only **5 new host
functions** needed, `api_version` 42→43:
- `is_alien(faction_id)` — one-line fact (`*ExpansionEnabled && rule_flags
  & RFLAG_ALIEN`, `faction.cpp`), same opaque tier as `is_alive`/`is_human`.
- `veh_lift(veh_id)` / `veh_drop(veh_id, x, y)` (`veh.cpp`'s own
  reimplementations, not raw engine pointers — stack-pointer/`BIT_VEH_
  IN_TILE`/`owner_set` mechanics) — pure relocation mechanism, no AI
  choice. `veh_lift` always returns the same `veh_id` it's given (per its
  own doc comment), so nothing needs threading through Lua — call both
  with the same id.
- `set_veh_visibility(veh_id, value)` — the one VEH field this mover
  *writes* (`visibility`, a per-faction bitmask), unlike every other VEH
  field this port reads directly via FFI.
- `nuclear_find_drop_tile(target_x, target_y, out_x, out_y)` — the
  `iterate_tiles(target_x, target_y, 1, 9)` + `anything_at() < 0` scan
  for a landing tile: first-match, no scoring, structural fact, same
  opaque tier as `has_base_sites`'s analogous scan. Whole scan stays
  host-side (`iterate_tiles` returns a real `std::vector<MapTile>`, no
  persistent `TileSearch` state to expose incrementally, unlike every
  TileSearch-based mover).

**Everything else was already exposed by prior stages**: `map_range` via
plain coordinates instead of the `VEH*`/`BASE*` overload the C++ uses (no
new overload needed — Lua just reads `.x`/`.y` off the `VEH`/`BASE`
objects it already has), `Facility[]`/`SP_ID_First`/`_Last`
(`tech.facility(id)`, already existed for `select_build`), `ally_near_
tile`/`defender_count`/`min_range_over` (already-ported Lua from earlier
stages), `has_pact`/`has_fac_built`/`is_alive`/`at_war`/`is_human`/
`project_base`/`move_to_base`/`set_move_to`/`veh_speed` (all pre-existing
host wrappers). `corner_market_active()` has no wrapper either — inlined
as `faction.get(id).corner_market_turn > game.turn()`, matching the exact
body of the C++ method and the identical idiom `target_priority` (stage
6) already used for the same method.

**RNG-order fidelity trap**: the "abandon rebase search" check
(`base->defend_goal < random(16)`) draws a *second*, independent RNG
value from the *same* stream as the score formula's own `random(16)`,
only when `defenders >= 2` (short-circuit `&&`) — order matters
(`score`'s draw always happens first, the abandon-check's draw only
conditionally after). Preserved by computing `score` (with its own
`rand.map(0, 16)` call) as a separate statement *before* the `if` that
may draw a second one, relying on Lua's `and` short-circuiting exactly
like C's `&&` to skip the second draw when `defenders < 2`.

**`airbases`** (a `std::set<Point>` in the original, used for both
`.insert()`/`.count()` membership and as `min_range`'s input) is a plain
Lua array here, reused directly with `min_range_over` (stage 7A) for the
distance check and a small explicit linear scan for the exact-membership
check — no new "set" abstraction needed, and Lua doesn't need to match
`std::set`'s O(log n) lookup, only its output.

Build-verified both presets, `luajit -bl` syntax-checked. This closes
Movement (porting-order item 4) entirely, but the function itself is
**still not live-exercised** — across every autoplay run to date, no
faction has ever built/launched a planet buster, so its hook has never
actually run (Class 3 hooks aren't shadow-run, so there's no other signal
either). Two bugs surfaced indirectly while chasing this:

- **`Faction.ODP_deployed` cdef gap** (found 2026-07-28): the field is
  real (`engine_types.h:394`) but `tools/gen_ffi.cpp` never named it, so
  it was silently folded into a padding blob in `lua/ffi/types.lua` —
  every invocation attempt errored (`'struct 243' has no member named
  'ODP_deployed'`) at `move.lua:3839`, always *before* any mutation, so
  each one safely fell back to the C++ body per the Class 3 contract
  (contained, not a crash, but it meant the Lua path had silently never
  run even once). Fixed by adding `FIELD(Faction, ODP_deployed)` next to
  `satellites_ODP` in `gen_ffi.cpp` (sort-by-offset means list position
  doesn't matter) — pure cdef naming, no layout change, no `api_version`
  bump needed. Two of the boolean-truthiness bug's 11 sites (4.16 above)
  were also in this function's own code (`tile_is_base`, `tile_is_ocean`)
  and got fixed in the same pass. Both fixes are build-verified; neither
  has live evidence yet since the function still hasn't fired.
- **Native (non-Lua) crash, open**: a 200-turn run (2026-07-28) crashed
  right after a nuclear strike (fallback C++ path, not Lua — occurred
  while the Lua side was still erroring on the bug above) killed ~15
  units in one base. The engine's own crash handler recorded an access
  violation (`ExceptionCode c0000005`) inside `terranx.exe` itself (not
  `thinker.dll`) at an address falling between two of the un-decompiled
  `Sprite_draw*` family's own known addresses (`engine.cpp:1861-1874`),
  i.e. native sprite-rendering code, most likely triggered by drawing the
  aftermath of a mass-casualty event. Same category as the `choose_
  defender` engine bug found testing stage 6 (a pre-existing engine
  fragility, not a Lua defect) — but unlike that one, **not yet
  root-caused to a specific fix or applied**; this is plausibly the first
  time in the project a planet buster has actually detonated on a
  garrisoned base. Left open since it's outside the Lua port's own scope
  and hasn't recurred (no repro beyond the one occurrence).

**Resume point:** Movement is done except live-exercising `nuclear_move`
itself, which needs a game where some faction actually researches and
uses planet busters — not yet reproduced on demand. Item 3's remaining
functions are now surveyed (4.18 below, user chose this over item 5
`probe.cpp` on 2026-07-28) — that survey is the next resume point.

### 4.18 Item 3's remaining scope (`mod_base_hurry`/`plans_upkeep`/`design_units`/`former_plans`) — all three ported and live-verified, `plans_upkeep` intentionally not

Survey done 2026-07-28 before writing any code (user request: read and
detail all four before porting), then user chose to implement all three
remaining functions in the recommended order, committing after each,
with live testing deferred to the end. Real sizes: `former_plans`
(`plan.cpp:448-467`) ~20 loc, `mod_base_hurry` (`build.cpp:42-215`) ~174
loc, `plans_upkeep` (`plan.cpp:469-629`) ~161 loc, `design_units`
(`plan.cpp:140-359`) ~220 loc.

- **`plans_upkeep` — likely not a porting target at all.** Read start to
  finish, it contains no independent AI decision of its own: it's a
  per-faction tally pass (military-strength sums, land/sea/air/probe/
  missile unit counts, contacted/enemy-faction counts, percentile-based
  `project_limit`/`median_limit`/`energy_limit`/`satellite_goal` derived
  from sorted per-base vectors) that produces the summary statistics
  `mod_base_hurry`/`design_units`/`select_build` already consume via
  `plans[]` (`p->enemy_factions`, `p->median_limit`, etc.). Its only two
  calls with any decision content are `update_main_region` (already
  ported, stage 7D) and `former_plans` (below) — both already handled
  elsewhere. This is the same shape as `move_upkeep`'s own map/unit/base
  sweep, which Phase 4.3 already decided stays C++ as fact computation,
  not AI policy. Recommendation: don't port `plans_upkeep` itself; Lua
  code that needs its outputs reads the resulting `plans[]`/`Faction`
  fields via FFI, same as it already does for fields `move_upkeep`
  computes. Revisit only if a real decision is found on closer reading
  during implementation.
- **`former_plans`** — ✅ done, live-verified (2026-07-28, clean — no bugs
  found in this one specifically).
  New file `lua/ai/plan.lua` (first module for `plan.cpp`-domain
  functions outside Movement, as Phase 4.4's own convention anticipated).
  `fungus_yield(faction_id, RES_NONE)` (`map.cpp:1505`) kept as an opaque
  host wrapper rather than re-implemented — it reads several `Faction`
  fields not yet named in the generated cdef (`tech_fungus_nutrient`/
  `_mineral`/`_energy`/`SE_economy_pending`) plus the
  `ManifoldHarmonicsBonus[][3]` lookup table, and this is its only
  call site. 3 new `plans[]` setters (`set_keep_fungus`/
  `set_plant_fungus`/`set_build_tubes`, same shape as stage 7A's 9 —
  none set `g_mutation_issued`, matching the established convention
  that `plans[]` writes aren't "mutation" for the no-fallback rule,
  same as every stage-7A setter). `api_version` 43→44. Classification:
  Class 3 via `lua_ai_command_hook_faction` (already built, stage 7B) —
  hooked at the call site in `plans_upkeep` (`plan.cpp`), same
  convention as `land_raise_plan`/`invasion_plan`, needing no new hook
  shape. `has_tech`/`has_terra`/`has_project` (all already exposed),
  `tech.facility(id)`/`tech.rules()` (already expose `.preq_tech`/
  `.cost`/`.maint` and `.tech_preq_improv_fungus`/
  `.tech_preq_build_road_fungus` directly) needed zero new surface.
- **`mod_base_hurry`** — ✅ done, live-verified (2026-07-28). A live run
  found one bug: the `FAC_CHILDREN_CRECHE` branch's `E.GrowthPopBoom`
  reference errored ("compare number with nil") 41 times — `GrowthPopBoom`
  is a plain `const int` under `types.counts`, never an enum, and was
  already exposed there before this batch (adding it again during this
  port, in the wrong table, created a harmless duplicate `gen_ffi.cpp`
  printf too). Every occurrence errored before any mutation, so the
  Class 3 no-fallback rule correctly fell back to the C++ body each time
  — contained, not a crash. Fixed by referencing `types.counts.
  GrowthPopBoom` and removing the redundant printf. Re-verified: 1042
  `hurry_item` calls in `debug.txt` over the run, 0 crashes, 0 shadow
  mismatches. Cheaper than its size suggested: `governor_priorities`/`facility_score`
  (already real Lua in `build.lua`, called directly, no shadow/hook
  indirection needed since mod_base_hurry now calls the same-file local
  functions) and `check_retool`/`proto_extra_cost`/`has_retool`/
  `skip_facility`/`base_can_riot`/`need_police` (same). `item()`/
  `drone_riots_active()`/`can_hurry_item()` inlined directly over
  `state_flags`/`queue_items[0]`, no wrapper, same treatment as
  `is_ocean(BASE*)`/`corner_market_active()` elsewhere. `defender_count`
  duplicated from `move.lua` into `build.lua` (both already-exposed-
  primitive small function, no new host surface) rather than shared
  cross-module, since `move.lua` already requires `build.lua` for
  `base_can_riot` and the reverse would be circular. `has_project`'s
  1-arg overload (`project_base(item_id) >= 0`) reused `project_base`,
  already exposed for `nuclear_move` — no new wrapper needed there either.
  Genuinely new: `mineral_cost`/`hurry_cost`/`mod_cost_factor` (pricing
  formulas, opaque), `hurry_item` (the mutator) and `base_hurry` (the
  *vanilla*, non-Thinker hurry logic — a raw engine function pointer,
  `engine.cpp:558`, called through unchanged when this hook's own two
  early branches decide Thinker shouldn't manage this base at all),
  `notify_project_done` (the whole DONEPROJECT popup gate folded into one
  opaque call so Lua doesn't need `GameState`/`MapWin`/`DIPLO_COMMLINK`
  exposed for a presentation side effect), `thinker_enabled`, and four
  trivial `conf.*` passthroughs (`simple_hurry_cost`/`design_units`/
  `manage_player_bases`/`base_hurry`, same tier as the existing
  `conf.tech_balance` etc.). `api_version` 44→45. Also needed 9 new
  `gen_ffi.cpp` enum entries (`GOV_ACTIVE`/`GOV_MAY_HURRY_PRODUCTION`/
  `BSTATE_COMBAT_LOSS_LAST_TURN`/`BSTATE_HURRY_PRODUCTION`/`TECH_Disable`/
  `STATE_GAME_DONE`/`DIFF_THINKER`/`RSC_MINERAL`/`GrowthPopBoom`, the last
  hand-transcribed since `main.h` is windows.h-blocked, same as
  `MaxEnemyRange`) plus one Faction cdef field (`hurry_cost_total`, same
  "silently padded until named" gap `ODP_deployed` had). Classification:
  Class 3 via a new `lua_ai_command_hook_base(name, out, base_id)` (not a
  reuse of `lua_ai_command_hook` — that one's error-after-mutation
  recovery calls `mod_veh_skip(veh_id)` unconditionally, which would
  corrupt an unrelated vehicle if a `base_id` flowed through it; the new
  variant's recovery is just "report handled, result 1", since there's no
  per-base "skip" action the way a vehicle can be skipped). Hooked at the
  *very top* of the C++ function (unlike `former_plans`/`land_raise_plan`/
  `invasion_plan`'s call-site hooks) — the two "delegate to the vanilla
  `base_hurry()`" branches are part of what Lua replicates, not a C++-side
  gate kept in front of the hook, so `conf.base_hurry`/
  `conf.manage_player_bases` needed their own trivial accessors rather
  than being resolved before the hook fires.
- **`design_units`** — ✅ done, live-verified (2026-07-28, clean — no bugs
  found in this one specifically; 2290 combined `create_proto`/
  `full_upgrade`/`part_upgrade` calls in `debug.txt` over the run). The
  heavy one, and the only one of the four with no existing dependency
  overlap with `select_build`'s prior work: 12 new host functions
  (`best_weapon`/`best_armor`/`has_chassis`/`has_ability`/`has_weapon`/
  `create_proto`/`veh_count`/`full_upgrade`/`part_upgrade`/`retire_proto`/
  `mod_upgrade_cost`/`use_nerve_gas`) — `best_reactor`/`need_police` were
  the only two already exposed (the latter real Lua in `build.lua`,
  called directly, no cross-module indirection). `api_version` 45→46.
  Also needed: a `CAbility` cdef (`.cost` only — `cost_increase_with_
  armor()`/`_with_speed()` inlined directly over it, same treatment as
  `BASE::can_hurry_item()`), its `Ability` global address (hand-found in
  `engine.cpp`, `engine.h` is windows.h-blocked like every other raw
  global address here), `CWeapon.cost`, `UNIT.obsolete_factions`, a new
  `tech.ability()`/`proto_is_active()` accessor pair (matching the
  established `proto_X` convention), `CRules.tech_preq_allow_2_spec_
  abil`, `MaxAbilityNum` (hand-transcribed, `main.h` windows.h-blocked)
  and 26 `VehChassis`/`VehWeapon`/`VehArmor`/`VehAbl`/`VehAblFlag`
  enum constants — all compiler-read from `engine_veh.h`, none
  hand-transcribed. Two static local C++ helpers ported as real Lua in
  `plan.lua` alongside it: `check_disband` (~26 loc — the two `std::set`
  membership checks became plain Lua tables keyed by `x*1000+y`, and
  the third set, `bases`, needed no separate collection at all since
  every base already occupies a distinct tile) and `upgrade_value`
  (~34 loc — a genuine `and/or`-ternary-idiom trap found and fixed while
  writing it: `atk_val > def_val ? atk_val < wpn_v : def_val < arm_v`
  has two *boolean* branches, so `cond and A or B` would silently return
  `B` whenever `A` is `false`, not just when `cond` is; written as an
  explicit `if/else` instead — see the file's own comment at that line
  for why, and 4.16's truthiness-bug entry for the general class of
  Lua/C boolean-vs-int traps this project keeps surfacing). Uses a
  priority-queue pattern twice (`score_max_queue_t`/`score_min_queue_t`,
  opposite pop orders — verified against `SItem::operator<`/`operator>`,
  `plan.h`) — same `table.sort` treatment as `land_raise_plan`'s
  `point_max_queue_t` (stage 7B). **Preserves one genuine original bug**
  (not fixed, per the port-before-improve rule, same disposition as
  Movement's `route_score` stale-`sq` bug): `arm_v = Weapon[arm].
  offense_value` indexes the *Weapon* table using an *armor* id, not
  `Armor[arm].defense_value` — kept exactly, with a comment at the one
  Lua line that reads it. This function directly creates and retires
  unit prototypes (`create_proto`/`retire_proto`) and upgrades fielded
  units (`full_upgrade`/`part_upgrade`) — unambiguously Class 3,
  per-faction, `lua_ai_command_hook_faction` (no new hook shape needed).
  Two call sites (`faction.cpp:1453`/`:1527`, unlike every other item-3-
  remainder function's single call site) — hooked *inside* the
  function's own body, right after its `conf.design_units`/`faction_id`/
  `is_human` guard (which stays C++-only), so one hook site covers both
  callers instead of duplicating the seam at each — same shape as
  `update_main_region_prioritize_naval` (stage 7D), for the same
  practical reason.

**Order** (cheapest/least-ambiguous first, same "lowest risk first"
principle as Movement's own staging): `former_plans` → `mod_base_hurry`
→ `design_units`, with `plans_upkeep` **not** ported (re-examine only if
a real decision surfaces later). All three ✅ done and live-verified
(above) — a 200-turn run found and fixed one bug (`mod_base_hurry`'s
`GrowthPopBoom` reference), then confirmed clean: 0 crashes, 0 shadow
mismatches, all three exercised.

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

- **`conf.autoplay=1`** bypasses every popup/dialog Thinker's own code
  funnels through (dedicated primitive shims, `write_call`-patched raw
  addresses, and a generic dismiss-whatever's-focused fallback — full
  current mechanism below), auto-demotes any human faction, and
  auto-advances End Turn (`Console_end_my_turn`, wired experimentally).
  **Gates on `conf.autoplay` alone, not `is_human`** — fine for an all-AI
  session, but dismisses a real human's own dialogs too if one is present.
  The monolith-inspection popup has its own preference-flag workaround
  (`MPREF_AUTO_ALWAYS_INSPECT_MONOLITH`, forced the same way as
  `MRULES_NO_PLANETARY_COUNCIL` below).
- **Unattended autoplay achieved (2026-07-25), after a long popup-blocking
  investigation.** Full narrative (five false starts, a failed live-gdb
  attempt under Wine's WoW64, the eventual strategy pivot):
  `DEVELOPMENT_DIARY.md` 2026-07-24/25. Current mechanism, in the order a
  popup would actually be intercepted:
  - **11 shimmed popup-family primitives** (`POP2`/`popp`/`popp_2`/
    `interlude`/`X_pop`/`X_pop_2`/`X_pop_9`/`X_pops`/`X_pops_18`/
    `NetMsg_pop`/`NetMsg_pop_2`) — `engine.cpp` points each public global at
    an `autoplay_*` wrapper (`src/autoplay.h`/`.cpp`) instead of the raw
    address (kept as the matching `*_engine` global); log to `autoplay.log`
    and return a safe default when `conf.autoplay` is set, forward to the
    real function otherwise. Only intercepts calls made *through* the
    redirectable global — raw addresses embedded in un-decompiled engine
    functions bypass this entirely (see next items).
  - **`tech_achieved` (`0x5BB000`, un-decompiled) internal `write_call`
    patches**: its own embedded `NetMsg_pop` calls (`0x5BBA0E`/`0x5BBB10`/
    `0x5BBBE2` → `autoplay_netmsg_pop`) and one `BasePop_exec_3` call
    (`0x5BBA37` → `autoplay_tech_achieved_basepop3`, return value confirmed
    discarded by the caller). Narrower than the fix below turned out to be
    necessary, kept as a harmless safety net.
  - **`SkipTechScreenA`** (`0x945F40`, a real engine flag: non-zero skips
    popups in both `tech_achieved` and `tech_advance`) set/cleared around
    every direct call to either function in Thinker's own recompiled code,
    gated on `conf.autoplay`: `tech.cpp:178`/`:191` (`tech_advance`, the
    actual dominant per-turn research-completion path), `base.cpp:3975`
    (`tech_advance` via `FAC_UNIVERSAL_TRANSLATOR`), and `tech_achieved`
    itself at `veh.cpp:1611`/`:1956` (pod tech), `probe.cpp:1249`
    (probe-stolen tech), `faction.cpp:766` (diplomatic sharing) and
    `:2189` (initial-spawn bonus techs), `net.cpp:124` (`net_tech`).
    `map.cpp:1944`'s `tech_advance` call already guards with the sibling
    flag `SkipTechScreenB` — no gap there.
  - **`monument`** (`0x476A50`, `void(int)`, previously declared but never
    called from this codebase) — the actual sink for `mon_tech_discovered`
    and 17 sibling "first to achieve X" world-event announcers scattered
    across the binary. All 18 call sites (found via `objdump -d terranx.exe
    | grep 'call.*0x476a50'`, not scoped to one function) `write_call`-patched
    to `autoplay_monument` in `patch.cpp`. Safe uniformly: `void` return,
    and for autoplay it doesn't matter which achievement triggered it.
  - **`autoplay_dismiss_dialog()`** (`src/autoplay.h`/`.cpp`) — the general
    catch-all, standing mechanism for anything not covered by the above
    (including future not-yet-catalogued popups, by construction).
    `win_dialog_open()` (`src/gui.h`/`.cpp`, wraps `current_window() ==
    GW_None`) is true whenever the focused window is neither the main map,
    base screen, nor design screen; when true under `conf.autoplay`, posts a
    synthetic `VK_RETURN` via `PostMessage` to `*phWnd` (the game's one real
    Win32 window handle, `gui.cpp:83`), reusing the same pattern already
    proven at `gui.cpp`'s `WM_MOUSEWHEEL`-to-arrow-key translation. Wired
    into `mod_blink_timer` alongside `autoplay_try_end_turn`. Live-verified:
    3 clean autoplay runs, zero blocking popups, zero crashes.
  - **`MRULES_NO_PLANETARY_COUNCIL`** (`GameMoreRules`/`0x9A681C`, bit
    `0x4`) forced whenever `conf.autoplay` is on (`autoplay_demote_human()`).
    The one exception to "hide the UI, mechanic still runs underneath" —
    `autoplay_dismiss_dialog` confirmed live *not* to resolve a Council
    interaction (likely `CouncilWindow`'s own modal loop doesn't pump the
    `WM_TIMER` the dismiss mechanism relies on — not investigated further),
    so Planetary Council is disabled outright for the session instead.
    User-confirmed tradeoff: unattended testing over mechanic fidelity for
    this one subsystem. `call_council` (`0x52C880`) also had its own
    unshimmed `NetMsg_pop` call, patched the same way as `tech_achieved`'s.
  - **Result**: a 100-turn autoplay run completed with zero manual
    intervention. **`conf.autoplay` still gates on `conf.autoplay` alone,
    not `is_human`** — fine for an all-AI session, but would also dismiss a
    real human's own dialogs if one were present (unchanged limitation, not
    revisited).
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
