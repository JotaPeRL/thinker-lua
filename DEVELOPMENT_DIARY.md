# Development diary

Chronological session log: what was tried, what broke, what was found, and
why decisions were made — the narrative history behind `IMPLEMENTATION_
PLAN.md` (normative status) and `IMPLEMENTATION_DETAILS.md` (tactical
reference). Not needed to resume work day-to-day; read when the "why" behind
a design choice matters, or out of curiosity about how a bug was found.

Entries are grouped by date, then by topic, referencing the
`IMPLEMENTATION_DETAILS.md` section they support. Facts that remain true
today (current scope, field catalogs, resume points) live in `DETAILS`, not
here — this file is a record of the path taken, not the destination.

---

## 2026-07-14

### Dialog-bypass spike, round 2 (supports `IMPLEMENTATION_DETAILS.md` 5.3)

First real play session with `conf.autoplay=1` after the initial six-primitive
spike and the `autoplay_demote_human()` fix. Three findings:

1. **Quit did nothing.** `autoplay.log` showed `X_pop_9 ... label=REALLYQUIT`
   every time Quit was clicked — the shim's blanket default of `0` answers
   "no" to this confirmation dialog. Fixed with a label-specific override in
   `autoplay_x_pop_9`: `REALLYQUIT` now returns `1`. This is the "add a case"
   iteration the spike was designed around.
2. **Monolith/tech popups still appeared.** Root cause is architectural, not
   a missing label: the six shimmed primitives only intercept calls made
   *through Thinker's own recompiled source*. Code that still lives entirely
   inside the original, un-decompiled engine binary (most of `tech_achieved`
   at `0x5BB000`, for instance) calls the same popup functions via hardcoded
   addresses baked into its own machine code, never touching the
   redirectable global variables — redirecting the variable is not the same
   as redirecting the function. Applied one targeted mitigation using the
   game's own existing preference toggle: `autoplay_demote_human()` now also
   sets `*GameMorePreferences |= MPREF_AUTO_ALWAYS_INSPECT_MONOLITH`. **Not
   fully solved** — a proper fix for popups originating entirely inside
   untouched engine code would need `write_call`-patching the specific call
   sites, disassembly/RE work not done yet.
3. **End Turn still required every turn.** Unrelated to `is_human`/
   `thinker_enabled()` — those only gate whether Thinker's AI decision code
   runs, not whether the UI loop waits for manual End Turn. Found a
   candidate, `Console_end_my_turn` (`engine.cpp:2135`), never called before
   in this codebase — wired as `autoplay_try_end_turn()`, called from
   `mod_blink_timer`. Flagged explicitly as experimental with real crash
   risk, not yet exercised.

### Tech pilot (M4) verification (supports `IMPLEMENTATION_DETAILS.md` 4.2 seam table)

`mod_tech_val`/`mod_tech_ai` ported to `lua/ai/tech.lua`, registered as Class
1 hooks, with temporary dual-run instrumentation (every call runs both Lua
and C++, C++ governs, mismatches logged). `mod_tech_ai` additionally
consumes the map RNG; its dual-run snapshots `random_state()` before the Lua
run and restores it before the real C++ run, so the comparison doesn't burn
the RNG stream twice. Verified via `lua.log`/`debug.txt` across two Wine
play sessions: both show `register_hooks: 2 hook(s) registered`, both hooks
logged `invoked and handled`, **zero mismatch lines in either session**.
Not yet done at the time: broader multi-session/multi-faction coverage
(`climactic_battle`, `tech_balance_enabled`, weapon-preq loops may have been
under-exercised), the real Phase 5.1/5.2 machinery this instrumentation
stood in for. Later formally closed by the Consolidation gate (see
2026-07-16 below).

### Social-engineering port session (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

Two Wine play sessions, made much longer/deeper than would normally be
practical thanks to the autoplay spike letting turns run with no human
clicking through popups:

- Session 1: turns 9-13, all 7 AI factions, 75 `mod_social_ai` calls, all
  with `pop_boom=0` and no available social-model alternative yet (`sf=-1`
  throughout) — zero mismatches.
- Session 2: turns 80-89, all 7 AI factions, 70 calls, all with `pop_boom=1`
  this time, including two real proposed-and-applied changes: turn 81
  BELIEVE Frontier→Fundamentalist (score 29), turn 82 GAIANS Simple→Green
  (score 18). Lua's proposed `sf`/`sm2` matched C++'s independently-computed
  value in both cases — zero mismatches across all 70 calls.

Combined: ~145 dual-run calls across both hook-relevant branches, zero
divergences — this cleared the "budget time to root-cause a mismatch"
concern the scoping pass had raised, since none showed up.

### War-decision port (`mod_wants_to_attack`, item 2b) — verification (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

In-game run (continued from the social-AI session, turn 90): `lua.log`
showed `register_hooks: 4 hook(s) registered`. `debug.txt`: 123
`wants_to_attack` calls across turns 90-92, **zero mismatches**. Both
outcomes exercised (46 `value=0`, 77 `value=1`). One path left unexercised:
`faction_id_unk` was `0` in all 123 calls, so the third-party-ally
adjustment branches never ran — not a problem, just untested (would need a
diplomacy-triggered call with a real third faction).

### Production/plans, first slice (`unit_score`+`find_proto`) — verification (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

In-game run (turns 93-100): `lua.log` showed `register_hooks: 5 hook(s)
registered`. `debug.txt`: **769** `find_proto` calls across all 7 AI
factions, **zero mismatches**, zero Lua errors. Coverage was broad: `defend`
both true/false (253/516), 6 distinct triad-flag combinations, 5 distinct
weapon modes. This was the deepest dependency chain ported at the time (two
new structs' worth of fields, a dozen-plus enums, 12 host wrappers) and it
came back clean on the first real session.

### Production/plans, second slice (`select_colony`/`select_combat`) — two rounds (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

**Round 1 found a real bug, fast:** `BASE.x`/`BASE.y` were never added to
the FFI back in the first slice — nothing had needed a base's coordinates
until `select_combat`'s enemy-base scan and `select_colony`'s
`has_base_sites` calls. This was the first real exercise of `lua_strict=1`'s
failure mode outside the Phase 2B smoke test: one hook's error disabled Lua
AI for the *entire* session. Switched the deployed `thinker.ini` to
`lua_strict=0` for iterative testing going forward. Fixed by adding `x`/`y`
to `BASE`'s `emit_struct` block — no C++ recompile needed, `types.lua` is
build-time-generated.

**Round 2, after the fix (turns 101-105, same session):** `lua.log` showed
`register_hooks: 7 hook(s) registered`, all three `build.lua` hooks in the
first-call diagnostic. Zero Lua errors, zero mismatches on any of the three
hooks. Neither `select_colony` nor `select_combat` calls `debug()` in the
original C++, so unlike `find_proto`'s 769-call count, there was no per-call
log to derive an exact volume from — confirmed invoked and clean, not
heavily-exercised the way the first slice was.

### `select_build` step 1 (VEH exposure + vehicle-count loop) — implementation session (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

Implements step 1 of the 4-stage plan: `VEH`'s first-ever FFI exposure plus
a standalone correctness check for `select_build`'s vehicle-count loop.
**Not a hook** — `select_build` itself stayed pure C++, unhooked. Validated
this session without a game launch: both presets build clean, every
touched/new Lua file passes a syntax check, `lua/ffi/types.lua` inspected
directly (`VEH`'s offsets hand cross-checked against `engine_veh.h` one by
one). Live verification (game launch, log check, counter diff) deferred to
later that session's `--golden-trace`/`--lua-shadow` autoplay runs — see the
2026-07-16 entry below, which found this held up: 986/986 vehicle-count
pairs matched exactly.

---

## 2026-07-15

### Autoplay harness script — addendum bugs (supports `IMPLEMENTATION_DETAILS.md` 5.3)

Two real bugs found while answering "how do I actually use this":

1. **Fixed — wrong `cwd` broke every Xvfb launch, silently.** `thinker.exe`
   checks for `terranx.exe` relative to its own process's cwd, not relative
   to the `.exe`'s own location. The first version of the harness script
   launched wine without `cd`-ing into the game dir, so it hit
   `FileExists(GameExeFile) == false` and got a plain Win32 `MessageBox`
   ("Cannot find terranx.exe"), confirmed by screenshot — a dialog **not**
   covered by the autoplay bypass shims, so it blocked forever even with
   `autoplay=1`. This means the earlier STALL-at-25s smoke test was almost
   certainly hitting this dialog the whole time, not sitting at the New Game
   menu as assumed when it was written. Fixed: the launch now runs as
   `(cd "$GAME_DIR" && exec setsid ...)`.
2. **Xvfb itself appears unable to run the game at all on this dev
   machine.** Even with the cwd fix, under Xvfb the process reliably exits
   ~1-2s after `patch_setup`/`random_reseed` lines land in `debug.txt` —
   before `mod_turn_upkeep`/Lua init ever runs (no `lua.log` created at all).
   `WINEDEBUG=+ddraw,+d3d,+seh` showed a burst of `RtlUnwindEx` activity
   around `wined3d_dll_init` right before the process disappears —
   consistent with a DirectDraw/PRACX surface-creation failure, not
   root-caused past that. `--no-xvfb` was the only launch mode confirmed to
   reach the game's window at all. **Re-attempted the same day** with three
   graphics-config suspects (higher screen depth/resolution, the GDI
   renderer, `WINEDLLOVERRIDES="ddraw=b"` to rule out PRACX), individually
   then combined — no change in any case, every variant dies at the exact
   same point regardless of configuration. A plain `wine notepad` survives
   fine under the identical Xvfb instance, ruling out Xvfb-vs-wine breakage
   in general. **Conclusion: the DirectDraw/PRACX hypothesis is ruled out,
   not just unconfirmed**; no replacement hypothesis tested. Since
   `--no-xvfb` on the real desktop already covers every run this project's
   validation needs, demoted to nice-to-have — only matters again if
   parallelizing runs becomes an actual goal.

### Real validation runs — 4 rounds, 3 bugs found (supports `IMPLEMENTATION_DETAILS.md` 5.3)

Four `--no-xvfb` sessions run end-to-end on the real desktop: 3 distinct new
games plus a 4th with a recorded fixed seed (`15373264`). All four finished
clean — `state_hash` lines sequential, zero `error in` lines, no leftover
processes after cleanup.

| Round | Demoted faction | Turns | Outcome | Notes |
|---|---|---|---|---|
| 1 | PEACE | 80 | manual stop | pre-dates the cwd fix and the `game_alive` fix below |
| 2 | USURPER | 100 | `COMPLETED` | first run of the actual script; revealed the End Turn problem |
| 3 | (unrecorded) | 80 | `COMPLETED` | first run after the blink-timer fix; confirmed End Turn now auto-advances |
| 4 | (unrecorded) | 80 | `COMPLETED` | fixed seed 15373264; meant to be re-run and `cmp`'d for the determinism check |

**Bug found and fixed: `game_alive()` — the watchdog was checking the wrong
PID.** `thinker.exe` is a launcher stub: it `CreateProcess`-suspends
`terranx.exe`, injects the DLL, resumes it, and **exits itself by design**
once that hand-off succeeds — not a crash. The watchdog originally only
checked the launcher's PID, so it declared `CRASH` within one poll interval
of *every* successful launch, and its cleanup step then skipped killing
anything, leaving `terranx.exe` running fully detached from the script.
Caught live: round 2's window kept accepting input for several minutes
after the script had already printed `CRASH` and exited. Fixed with a
`game_alive()` helper that also checks `pgrep -x terranx.exe`. Round 2's
`COMPLETED` result is from *after* this fix.

**Bug found and fixed: `autoplay_try_end_turn` was never once invoked.**
The user had to press End Turn manually every turn even with `autoplay=1`
and 80-100 turns completing "cleanly." Root cause: the `write_offset` call
that installs the periodic UI-timer callback lives inside
`if (cf->smooth_scrolling) { ... }` — an unrelated visual feature, off by
default. Since the callback was never installed, `autoplay_try_end_turn()`
was never called at all — not "failing silently," literally never invoked
(confirmed: zero `attempting Console_end_my_turn` lines in round 2's
`autoplay.log`). This had been sitting in the code since the dialog-bypass
spike, marked "needs an actual play session to know if it works" — the real
answer was "never gets the chance to." Fixed with an `else if (cf->autoplay)`
branch. Confirmed fixed live in round 3.

**Six-primitive catalog was incomplete — corrected to nine.** Round 3
surfaced two more interaction points: new-tech-discovered announcements,
and secret-project completion. Investigating found `engine.h` declares a
much larger family of raw popup primitives (~33 total) than the six
originally caught; the original spike's grep searched for Thinker's own
convenience-wrapper names and missed every call site using a bare numbered
primitive directly. Checked which of the ~33 actually have call sites in
Thinker's own recompiled source (the only ones a pointer redirect can
reach): `X_pop` (8 sites), `X_pop_2` (6 sites), `X_pops` (5 sites, confirmed
as the round-4 probe-click culprit) — the rest have zero call sites. Fixed
with three new shims.

**Still open: tech-discovery announcement.** `tech_achieved` lives entirely
inside the original, un-decompiled engine binary — same category of problem
as the monolith-popup gap, confirmed not fixable by pointer redirect. A real
fix needs disassembly work not done yet. Left for the user to keep clicking
through — lower frequency than End Turn was, not a blocker.

**Partial mitigation: secret-project completion, 2 clicks → 1** via the
pre-existing `minimal_popups` debug option, added to the harness's forced
settings.

---

## 2026-07-16

### Cross-launch RNG determinism: chased for two days (2026-07-15/16), then abandoned in favor of shadow mode (supports `IMPLEMENTATION_DETAILS.md` 5.3)

Attempting an actual determinism check (same save loaded twice, same seed)
surfaced a real architectural fact: **the mod's own RNG stream is not tied
to the save file at all** — `DLL_PROCESS_ATTACH` seeds both
`random_reseed()` and `map_rand` from `GetTickCount()` every DLL load,
independent of any save; turn 1 was byte-identical across two loads, turn 2
already diverged. Fixed with a new `fixed_rng_seed` config option (pins the
seed instead of `GetTickCount()`) — confirmed working (turn 1 now
byte-identical, `random_reseed` reads the pinned value in both runs), but
turn 2 still diverged. Root cause found in two steps: first, `game_rand`
(the engine's own RNG, separate from the mod's LCG) was never re-seeded by
the fix at all — calling the existing `game_rand_restore` from
`mod_load_daemon` pushed the divergence from turn 2 to turn 3. Second, a
real remaining mechanism: single-player pod-opening code (`veh.cpp`) draws
from the **main sequential** RNG stream rather than a position-independent
one (unlike multiplayer), so its outcome depends on every other AI
faction's own turn-1 draws — not root-caused further.

**Abandoned by decision, not because the turn-3 gap was closed:** external
review pointed out this isn't the project's "bit-exact only where
achievable" Lua-vs-C++ tolerance case — it's a single C++ binary diverging
from itself across two launches of the identical save and seed, i.e.
engine-internal nondeterminism, outside this project's charter to chase
further. Per-call shadow mode (implemented the same week) is strictly
stronger port-fidelity evidence than trajectory comparison anyway, and
needs no cross-launch determinism at all — both sides run inside the same
process invocation. The RNG-pinning work isn't wasted: it delivers
single-turn reproducibility, the prerequisite for a possible future
windowed comparison method for Movement (reload once, compare one turn).

**Dead end worth not retrying:** pausing the process with `SIGSTOP` to give
the user time to save mid-session doesn't work — it freezes the whole
process including the message loop, so the user can't even dismiss an open
popup. Had to `SIGKILL` and restart; `fixed_rng_seed` sidesteps the need for
this entirely.

### Shadow mode, golden traces, port drift — Consolidation gate closed (supports `IMPLEMENTATION_DETAILS.md` 5.1, 5.2, 4.5–4.11)

Replaced the hand-rolled dual-run blocks with real `lua_ai_shadow_call`/
`_check` plus the typed `out_count` descriptor refactor (closes the
`facility_score`/`governor_priorities` hookability gap). First live run
found the autoplay harness was silently discarding `lua_shadow=1`
(`tools/autoplay_run.sh` force-set `lua_ai`/`lua_strict` but not
`lua_shadow` when overwriting `thinker.ini`) — fixed with a `--lua-shadow`
flag and a `config: ...` line at Lua init so a run's actual flags are
always visible in the log, not just inferred from zero mismatches. Three
autoplay runs (one with `rule_psi`) then came back clean, closing gate
item (d). Golden traces (capture + native-`luajit` replay) verified
against a real captured corpus, 1265/1265 passed. `tools/port_drift.py`
verified against all three real outcomes (clean/drifted/error), not just
a smoke test — the synthetic "drifted" case correctly flagged exactly
the 3 functions touched by an intervening upstream commit.

### `select_build` steps 2–3.4 — four distinct bug classes, same discipline catches all of them (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

Porting `select_build`'s prologue, `DefendUnit`/`CombatUnit`, and the
first facility branch surfaced four unrelated failure classes, each
found only because a real diagnostic/shadow hook was run against live
data, not because the code "looked right" or built clean:

1. **Double-application** (step 2): the `push_item_check` hook sat
   *after* `push_item`'s own score adjustments, feeding Lua an
   already-adjusted value that its independent recomputation adjusted
   again. Fixed by moving the hook to the top of the function.
2. **Pure ordering bug** (step 3.1): `select_build_prologue` referenced
   `governor_priorities` before its `local function` declaration — Lua
   locals aren't hoisted, so the forward reference silently fell through
   to a nil global. Every call failed identically until reordered.
3. **Shadow-placement bug** (step 3.2): `lua_ai_shadow_call` for
   `combat_unit_early_return` was placed *after* C++'s own
   `select_combat` call had already consumed its RNG draws, desyncing
   the two sides even though the underlying logic was correct. Fixed by
   moving the shadow call before C++'s own call.
4. **Missing field in a shared return table** (step 3.4): `select_build_
   prologue` computed `defend_range` as an internal local but never
   returned it — invisible until the first facility branch that needed
   it externally. Since this was a shadow hook, the resulting Lua error
   was safely contained (logged and skipped) the whole time.

---

## 2026-07-17

### `allow_units` RNG hazard — the hook-argument-threading pattern (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

Caught before any run, while wiring `queue_items[0]`: the obvious port
would add `allow_units` to `select_build_prologue`'s return table, but
`select_build_prologue` isn't computed once per `select_build` call the
way its name suggests — `build_order_item_score` calls it fresh
internally and is itself shadow-called up to 38× per real invocation
(once per `build_order[]` item). `allow_units`'s backing function
(`can_build_unit`) contains a conditional `random(32)` draw; real C++
computes it once before the loop and reuses that single value for all 38
items. Re-deriving it per item in Lua would draw RNG up to 38× instead of
once, and could resolve to a different boolean on different items within
the same call — something C++ structurally cannot do. Fixed by threading
the already-computed C++ value through as a hook argument instead (same
precedent as `mod_social_ai`'s `pop_boom`). General rule going forward:
a per-call-once C++ local is only safe to re-derive inside a
per-item-called prologue if it's pure/RNG-free; confirmed safe cases
found the same session (`drone_riots`, `drones`, `mod_psych_check`,
`main_region`, `target_land_region`) by actually reading each function's
body for a `random()` call, not by pattern-matching the "computed once
before a loop" shape.

### Split-block facilities: a second `if (t == FAC_X)` block can hide (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

`FAC_NAVAL_YARD` had been reported "0 mismatches" after porting only
`build.cpp:1322-1331`; a second, separate block at `1333-1334` (also
gated on `FAC_NAVAL_YARD`) went untranscribed and unnoticed because the
first block's own gate (`!allow_ships → continue`) filtered out most
bases before they'd ever reach the second. Same shape recurred
immediately with `FAC_BIOLOGY_LAB` (`1302-1306` and `1307-1310`, the
second shared with `FAC_CENTAURI_PRESERVE`) — caught this time by
deliberately checking for a second block before calling the facility
done, specifically because the `FAC_NAVAL_YARD` gap had just been found.
Standing rule: a facility ID appearing in more than one `if` block in
`build.cpp` is not fully ported until every block is.

### Verification methodology correction: absence of a mismatch is not evidence of correctness (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

The user asked whether late-game facilities could even be reached in a
60-turn test — checking the code (not guessing) showed `can_build`
gates the entire per-item loop body *before* `build_order_item_score`'s
shadow call runs, so an unreached branch and a correctly-handled one
produce byte-identical `lua.log` output. Every prior "0 mismatches,
confirmed by absence" claim was, strictly, unconfirmed for facilities
that hadn't been queued as a candidate that run — and since both
`lua.log`/`debug.txt` truncate on every launch, there was no way to
retroactively check whether earlier runs actually had. Fix: cross-check
`push_item`'s own debug line (already logs `prod_name(item_id)` on every
item that survives to be scored) for a nonzero count of the specific
name, as independent evidence of exercise, not just absence of
disagreement. Applied immediately: a 172-turn run (ended in an unrelated
engine crash, not a Lua error) brought 24 of 28 then-"done" facilities to
real confirmed-exercise evidence, all clean. Now a standing rule,
recorded in `IMPLEMENTATION_PLAN.md`'s Phase 5 handoff note.

### `has_project(...) ~= 0` — a `bool`-vs-`int32_t` FFI trap, caught in review (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

First draft of `FAC_CHILDREN_CRECHE` copied the raw-`int32_t`
`has_fac_built ~= 0` idiom for `has_project`, but `has_project` is
declared `bool` in `LuaHostApi` — LuaJIT auto-converts a C `_Bool` return
to a genuine Lua boolean, and `false ~= 0` is `true` in Lua (no C-style
truthy coercion), so the comparison was unconditionally `true`. Caught by
grepping every other `faction.has_project` call site before trusting the
new one — none use `~= 0`. Fixed before the first build. Rule: FFI
functions declared `bool` return real Lua booleans and must be used as
such; only raw `int32_t` host calls need the `~= 0` idiom.

---

## 2026-07-19

### `need_ferry`/`allow_supply` — a refinement gap invisible since step 1 (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

While wiring `CrawlerUnit`/`FerryUnit` (the first real consumers of
either value), found `select_build_prologue` had been exposing
`count_vehicles`'s raw, loop-accumulated `need_ferry`/`allow_supply` —
but real C++ applies a post-loop refinement (`build.cpp:948-950`) never
ported. Not a new mistake: a gap dating back to step 1 (4.5–4.11),
invisible until now because `vehicle_counts_check` (the temporary
diagnostic that verifies `count_vehicles`' output) runs *before* that
refinement in the C++ source too, so it structurally never had a chance
to catch it. Fixed inside `select_build_prologue` itself, deliberately
not inside `count_vehicles`, to avoid silently changing what the
existing diagnostic verifies.

### `C.SP_ID_First` vs `E.SP_ID_First` — a wrong-table lookup caught by cross-reference, not by the build (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

`find_project`'s first draft used `C.SP_ID_First`/`C.SP_ID_Last` (the
`counts` table); both are actually under `enums`, confirmed by checking
`gen_ffi.cpp`'s own emission order and by the one pre-existing correct
usage elsewhere in the file (`E.SP_ID_First` at `build.lua:709`).
`C.SP_ID_First` would silently be `nil` — Lua doesn't error on a nil loop
bound until the code actually runs, so this would have built clean and
only failed the first time `find_project` executed in-game. Caught
during review, before any build. Separately, double-checked (correctly)
that `f->diplo_status[i]` is the *current* faction's own array indexed
by the *other* faction, not the reverse — verified against the source
directly since `has_pact`'s own argument order reads the opposite way
and could easily have been copied wrong.

### `FormerUnit`/`select_item` — scoped concretely, then deliberately not ported (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

`FormerUnit`'s dependency, `select_item` plus its 12 `can_*` helpers,
was first estimated loosely as "medium, unsurveyed"; reading it to the
actual end put it at ~472 loc with zero engine surface exposed —
comparable to the entire 15-block facility-branch catalog, not "one more
branch." Presented concretely to the user rather than pushed through on
the earlier estimate. Re-reading the `FormerUnit` branch itself
(`build.cpp:1152-1179`) showed `select_item(...) >= 0` is used purely as
a tile-quality signal (a tally), never scored or branched on by which
specific terraform action it names — that judgment only matters later,
in Movement's `former_move` (not yet ported, a different Class 3
shadow-verification shape). Given a genuine choice — port `select_item`
properly now, or wrap just the tally the branch actually needs — the
user picked the minimal option: one opaque host wrapper
(`former_tile_tally`), same "wrap the scan, don't expose the primitives"
precedent `has_base_sites` already set for `select_colony`. Result ended
up comparable in size to `ColonyUnit`/`CrawlerUnit`, not to the facility
catalog. This closed `select_build`'s unit-branch catalog at 9 of 9.

---

## 2026-07-20

### Unit-branch catalog live-verified; `Satellites` and the remaining untested facilities explicitly deprioritized (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

Facility item-IDs map 1:1 to a branch, so the `push_item.*<name>` grep
worked directly for the facility catalog; unit branches share one
`push_item` call site, so confirming each needed a `prod_name` value
distinctive to that branch's specific `WMODE`/triad combination (e.g.
"Foil Probe Team", not the more general "Probe Team", to confirm the
sea-triad branch specifically) — checked against each branch's code
before trusting it. A 61-turn run confirmed 5 of 7 new branches clean;
a second, 100-turn run requested specifically to chase `CrawlerUnit`
("Supply Crawler", 257 occurrences, 0 mismatches) confirmed it too.
`Satellites` showed zero occurrences in both runs. Rather than leave it
as open-ended "try again later," the user made an explicit, durable call
to deprioritize `Satellites` and the remaining handful of untested
facilities long-term — not project-blocking, not scheduled, revisit
opportunistically — recorded in `IMPLEMENTATION_PLAN.md` so it doesn't
quietly turn into a forgotten action item. Standing count: 8 of 9 unit
branches and 33 of 38 facilities carry real confirmed-exercise evidence,
0 mismatches ever recorded.

### `select_build` wired as the project's first real hook, then verified with a different question than usual (supports `IMPLEMENTATION_DETAILS.md` 4.5–4.11)

Realized before starting: every hook in the project to date, including
every "closed" domain, only ever used `lua_ai_shadow_call`/`_check` —
C++ always computed and returned its own value, Lua's result only fed a
comparison log. `lua_ai_hook` (the mechanism that actually uses Lua's
return value) had only ever been called by throwaway diagnostics that
discard the result. Wiring `select_build` for real via `lua_ai_hook`
would be the first time `lua_ai=1` — a flag already set in every prior
test session — actually changes what a base builds, not just what gets
logged. Flagged this explicitly to the user before implementing, given
the stakes; user chose to proceed as documented (Phase 4.1's Class 2
contract), keeping the existing per-piece shadow instrumentation intact
in the C++ fallback body for when `lua_ai=0`.

**Verification needed a different question than every prior session's
"0 mismatches, confirmed by absence" check — mismatch-absence is
meaningless here by construction**, since when the real hook succeeds,
the C++ fallback body (which is what previously produced comparison
data) doesn't run at all. The actual question: is the hook *governing*,
not just callable without crashing? Answered by cross-checking
`mod_base_build`'s `BUILD NEW` debug line (fires right before every real
`select_build` call) against `push_item`'s debug line (only reachable
from the C++ fallback, after the hook check) — 698 `BUILD NEW` calls
across all 7 factions in a 60-turn run, 0 `push_item` lines, meaning
100% of calls were handled by Lua, none fell back. 0 errors, 0
mismatches anywhere else. Went one step further than every prior
verification too: since this is the first hook whose output isn't
purely diagnostic, also checked that the resulting `choice: <id> <name>`
values look like a sane production AI (varied, plausible names across
every branch category), not just error-free — a check that didn't matter
for any earlier shadow-only hook, where a wrong Lua answer was invisible
to the running game either way.

## 2026-07-21

### `crawler_move`'s `want_convoy` wrongly wrapped opaque, then reworked — the "engine mechanics" heuristic has a real failure mode (supports `IMPLEMENTATION_DETAILS.md` 4.12–4.15)

Stage 2's first pass wrapped `want_convoy` (the formula deciding which
resource a crawler should harvest, and how good a tile is) and the whole
`TileSearch` scan as opaque host calls, on the same "engine mechanics,
not AI policy" reasoning already used for `former_tile_tally`/
`has_base_sites`. The user caught this as wrong for this specific case:
crawlers are the single biggest economic lever in the game and this
project's explicit priority area, so the *scoring formula itself* is
real AI policy — the fact that it consumes engine yield-calculator
functions (`mod_crop_yield`/etc.) as inputs doesn't make the formula
built on top of them engine mechanics too. The actual test that should
have been applied and wasn't: does this code make a *choice* an AI could
reasonably do differently, or does it just compute a fact about the
world? `want_convoy`'s Ns/Ms/Es weights and thresholds are the former;
`mod_crop_yield` itself is the latter. Reworked: the formula moved fully
to Lua; the `TileSearch` scan (which genuinely can't cross into Lua,
Phase 4.3) became an incremental start/next iterator instead of one
opaque "whole scan" call, so Lua still drives the candidate-scoring loop
even though the raw search primitive stays in C++ — a reusable pattern
for future movers with the same shape.

### Live verification caught a real gap: no decision-trace logging means a clean run proves nothing

After the rework, the first live run came back with 0 errors and was
reported clean — but `crawler_move`/`want_convoy` had no `log.debug`
calls anywhere, unlike `artifact_move`'s own decision-point logging.
"0 errors" only proves the code doesn't crash; it says nothing about
whether the resource/tile choices are sane, which is exactly what
matters for the area under the most scrutiny. Fixed by adding
`crawl_score`/`crawl_move`/`crawl_convoy` lines at the three points
`crawler_move` actually commits to a decision, mirroring the granularity
the original C++ `crawl_score` debug line (removed during the rework)
had. Second run: 730 decision lines, all three resource choices firing
(including the narrowly-gated energy branch), scores in plausible
bounded ranges, short local move distances. Lesson for any future
Class 3 mover: decision-trace logging is not optional polish, it is the
only verification mechanism this hook class has (5.1's own rule) — a
mover isn't live-verified until its own log lines exist and were
actually checked, not just "the run had zero errors."

### The "search + score" function family and `route_score`'s deferred fix (supports `IMPLEMENTATION_DETAILS.md` 4.12–4.15)

Before starting `colony_move`, at the user's request, did a full sweep of
`move.cpp`/`path.cpp` for functions shaped like `want_convoy`: a real
scoring formula wrapped opaquely because it happens to be fed by a
`TileSearch` scan. Found `route_score`/`search_route` (used by
`artifact_move`, already "done, live-verified") had exactly this defect —
the same mistake class `want_convoy` was already caught and fixed for,
just missed the first time because `artifact_move`'s own review hadn't
yet named the "is this a choice or a fact about the world?" test. Rather
than patch inline, `route_score` (`path.cpp`, 210 loc, 5 scoring loops,
deep `TileSearch` parent-chain coupling) was split into its own stage —
closer in size to `nuclear_move` than to a quick formula swap.
`escape_score`/`base_tile_score` (needed directly by `colony_move`) were
smaller and came first, folded into stage 3 as planned.

## 2026-07-22

### `route_score` sub-stages A/B — a stale-`sq` reuse bug in the original, kept for fidelity (supports `IMPLEMENTATION_DETAILS.md` 4.12–4.15)

`route_score` itself + its two `Bases[]` scans (sub-stage A), then the
three `TileSearch`-driven scans (sub-stage B), closed the deferred item
above. Assembling the whole function surfaced a genuine bug in the
original C++: `path.cpp:760` passes the vehicle's own `x,y` into
`route_score` but reuses `sq` left over from an unrelated `Bases[]` loop
just above it, not the vehicle's actual tile. Per the project's
1:1-before-improvement rule, this was replicated, not fixed —
`route_score` gained an optional `sq_x,sq_y` override so this one call
site's bug could be reproduced without touching any other call site's
correctness. Live verification's first attempt found an instrumentation
gap, not a logic bug: the ordinary success path had no `log.debug` call
at all, so a clean run with zero decision lines would have looked
identical to "never reached" — the same "absence of a line is not
evidence" lesson `select_build`'s 4.5–4.11 already recorded, hit again in a
new area. Second run: 885 decision lines, 0 mismatches — closes
`route_score`/`search_route` and unblocks `former_move`.

### `former_move` bug hunt: two silent-nil enum gaps, then a NULL-pointer crash from a wrong FFI calling convention (supports `IMPLEMENTATION_DETAILS.md` 4.12–4.15)

Two enum tables (`FormerMode`, then `FORMER_NONE`/`FORMER_RAISE_LAND`)
were referenced in Lua but never actually added to the generated enum
table — `nil` is well-formed enough in Lua that neither gap errored until
the exact branch ran live, so both sat invisible through a build-clean,
syntax-checked session. Worse, a genuine native crash (access violation,
not caught by `pcall`) traced to `tile_near8`/`tile_neighbor`'s real FFI
signature: the wrapper takes output-pointer arguments (`tx, ty`) rather
than returning multiple values, and four call sites had been written the
wrong way (`local valid, nx, ny = funcs.tile_neighbor(x, y, i)`, only 3
args) — LuaJIT silently converts missing pointer arguments to NULL
instead of erroring, and the host function then unconditionally writes
through them. Lesson: when adding a new call site for an existing FFI
wrapper, check its real arity in `funcs.lua` directly rather than
pattern-matching a similar-looking call elsewhere. A third bug
(`escape_move`/`search_base` referenced before their own later
definition in the file — Lua has no hoisting) was caught the same session
by a small script cross-checking every call site's forward-reference
safety across the whole file, not just by rereading — the same technique
was then applied preventively to `trans_move`/`combat_move` afterward.

### `combat_move`: one shared `TileSearch` object breaks the "split into sub-stages by line range" plan (supports `IMPLEMENTATION_DETAILS.md` 4.12–4.15)

The original staged plan assumed `combat_move`'s 726-loc body could be
split into four independently-committed partial functions (C-F), the way
`select_build`'s facility catalog was tranched. Reading the whole
function before writing it found this doesn't work: it reuses **one**
`TileSearch` object across three separate loops without reinitializing
between them, plus ~15 other shared locals — no prior mover had this
shape, since each one only ever ran a single scan configuration.
Threading that state through call boundaries would mean restructuring the
control flow, against the project's own "keep the C++ control flow
recognizable" rule. Reworked to match every prior mover's real precedent
instead: land every remaining dependency first (sub-stage C), then
assemble the whole function once in a final sub-stage (D) — same shape
`former_move` and `trans_move` already used.

### A pre-existing `has_pact` truthiness bug found in two already-closed stages (supports `IMPLEMENTATION_DETAILS.md` 4.12–4.15)

While researching `combat_move`'s sub-stage A, found two call sites
(`colony_move`'s `skip_owner`, `make_landing`'s neighbor filter — both in
already-closed, live-verified stages) using `has_pact`'s raw int return
directly in a boolean position. `has_pact`'s wrapper returns a plain 0/1
int, not a real Lua boolean, and Lua's `0` is truthy — so both sites
always behaved as if a pact existed. Neither location crashes or
obviously diverges, so shadow mode's per-call comparison never caught it:
the bug only manifests when the branch is taken with an actual
allied-pact tile in range, which a given autoplay run may simply not have
exercised. Fixed at the user's direction; re-verified live and closed.
General lesson: a "live-verified clean" status only covers the branches
actually exercised that run — a bug in an unexercised sub-condition can
survive "closed" status indefinitely.

## 2026-07-23

### `combat_move`: `choose_defender`/`battle_priority` crash, root-caused to a missing hostility filter in the engine's own `find_defender` (supports `IMPLEMENTATION_DETAILS.md` 4.12–4.15)

First live-testing attempt (manual play, ~144 turns) hit a hard
`assert(veh1->faction_id != veh2->faction_id)` abort inside
`battle_priority` — an unchanged, already-opaque wrapper, called by the
new Lua `combat_move` exactly as the native version always called it.
Zero Lua-side errors preceded the crash. Root cause: `choose_defender`'s
own `at_war` check used to be skipped whenever the target was an
enemy-owned base, trusting `find_defender` (`veh_combat.cpp`) to have
picked a genuinely hostile unit — but `find_defender` scores every unit in
the tile's stack with no faction filter at all, so a same-faction or
allied unit garrisoned alongside the real target could be returned as
"the defender." Fixed by making the `at_war` check unconditional
(removing the `!is_base` escape) — closes the gap for every caller,
native and Lua alike, not just the Lua port. Re-verified live over 151
turns, 0 crashes, the vast majority of `combat_move`'s decision surface
exercised. This closes movement stage 6.

## 2026-07-24

### Probe-mission popup flood: `NetMsg_pop`/`NetMsg_pop_2` gated on `MapWin->cOwner`, not `is_human` (supports `IMPLEMENTATION_DETAILS.md` 5.3)

Live autoplay still showed dozens of popups per run once probe teams
became common, invisible in `autoplay.log` — proof they bypassed every
existing shim. Traced to `probe.cpp`'s *mission-report* messages
(`BUSTED`, `STOLENOTHING`, `PROBECAUGHT`, `ASSASSINATED`, …), which go
through `NetMsg_pop`/`NetMsg_pop_2` gated on `veh_fc_id == MapWin->cOwner
|| tgt_fc_id == MapWin->cOwner` — the viewpoint faction from New Game
setup, never touched by `autoplay_demote_human()`'s human-bit clear. The
*decision* dialogs (`EXCUSE`/`PACTEXCUSE`, `BasePop_exec_2`/`_3`) were
never the problem — those really are `is_human`-gated and demotion
already neutralizes them; the report-only banners use a completely
different, cOwner-based gate. Fixed by promoting `NetMsg_pop`/
`NetMsg_pop_2` to a 10th/11th shimmed primitive (`src/autoplay.h`/`.cpp`,
`src/engine.h`/`.cpp`) — safe as a uniform default since no caller
anywhere in the codebase consumes either function's return value.
`NetMsg_pop` is also the general "flash a message" primitive used ~150
places outside `probe.cpp`, so this quieted a lot more than just probe.
Live-confirmed clean.

### The tech-acquisition popup false trail: five rounds chasing `tech_achieved`, the real path was `tech_advance` (supports `IMPLEMENTATION_DETAILS.md` 5.3)

A single announcement ("your faction has acquired technology X") survived
fix after fix, and untangling why became the session's main lesson in not
trusting a plausible-looking root cause. `tech_achieved` (`0x5BB000`,
entirely un-decompiled) turned out to have its own embedded raw popup
calls, same "redirecting the variable isn't redirecting the function" gap
from 2026-07-14 — `objdump`-ing its address range found 15 internal popup
calls, three of them `NetMsg_pop` with resolvable labels
(`TECHOBTAINED`/`FREEFACTECH`/`FREEABILTECH`) that read exactly like the
reported bug. Patching those three, then a fourth (`BasePop_exec_3`, the
branch taken when the achieving faction isn't a single specific tracked
global — the common case with 7 AI factions), still didn't stop it: a
live run showed zero matching log lines despite confirmed tech
completions. The actual answer came from checking `SkipTechScreenA`
(`0x945F40`) — a real engine flag, "non-zero skips popups, used in
tech_achieved and tech_advance," already used by `game.cpp` for the
turn-1 starting-tech grant — and confirming by disassembly
(`0x5BB490`/`0x5BB49D`) that setting it skips `tech_achieved`'s *entire*
popup-bearing middle section in one jump, not one branch. `tech_advance`
(`0x5BE530`, a different raw function, called every turn per faction once
research completes — `tech.cpp:178`/`:191`) was the actual dominant path
all along; wrapping its two call sites (plus `base.cpp`'s
`FAC_UNIVERSAL_TRANSLATOR` facility) with `conf.autoplay`-gated
`SkipTechScreenA` needed no reverse engineering at all. Even that wasn't
complete: `tech_achieved` is *also* called directly (not via
`tech_advance`) from `veh.cpp` (pod tech grants), `probe.cpp`
(probe-stolen tech), `faction.cpp` (diplomatic tech sharing, initial-spawn
bonus techs), and `net.cpp` (`net_tech`) — none of those call sites were
guarded either, and each needed the same `SkipTechScreenA` wrap.
**Lesson: grep every direct caller of the suspected function before
reaching for a disassembler** — the fix that actually worked needed none,
and the existing `SkipTechScreenA` convention was sitting in the codebase
the whole time. The four `write_call` patches from the false trail were
kept (harmless, redundant once the flag is set correctly) rather than
reverted.

## 2026-07-25

### `mon_tech_discovered`/`monument`: the popup was never `tech_achieved` at all, and "found the function" wasn't the same as "found every caller" (supports `IMPLEMENTATION_DETAILS.md` 5.3)

Two more clean-looking fixes still didn't stop the popup. The break came
from asking the user for the literal on-screen text instead of guessing
another call site: "WE HAVE ACQUIRED TECHNOLOGY!" turned out to live in
`labels.txt` line 553, an older index-based text system entirely
different from the named labels `tech_achieved` uses — proof the whole
five-round investigation had been aimed at the wrong function. Traced it
to `mon_tech_discovered` (`0x476C90`, called from `tech.cpp` right after
`tech_advance`, outside the `SkipTechScreenA`-guarded block, with no such
check of its own), whose one real call targets `monument` (`0x476A50`) —
a function already declared in this codebase with zero callers until now
(upstream had named/typed it but never wired it up). Patching that one
call site *still* wasn't enough: `objdump -d terranx.exe | grep
'call.*0x476a50'` over the *whole* binary (not just one function's
address range) found 18 total call sites, a whole family of sibling
"first to achieve X" world-event announcers sharing the same sink, only
one of which had been patched. Redirected all 17 remaining sites at once
— safe uniformly since `monument` returns `void` everywhere, and for
autoplay specifically it doesn't matter which achievement triggered it.
**Lesson: "found the function" and "found every path that reaches it"
are different claims** — a `grep`/`objdump` sweep for every caller,
scoped to the whole binary rather than one function's disassembly
window, should be the default the first time, not the fallback after a
narrower patch turns out incomplete.

### Live gdb debugging under Wine's WoW64 doesn't work for this; pivoted to dismissing dialogs generically instead of chasing sources (supports `IMPLEMENTATION_DETAILS.md` 5.3)

With the popup still recurring after six rounds of disassembly, tried
attaching `gdb` to the running Wine process to catch it in the act
(`sudo gdb -p <pid>`, needed because `ptrace_scope=1` blocks attaching to
a non-child process otherwise). Breakpoints resolved at the correct
addresses, but Wine ≥ 11's WoW64 architecture broke gdb's
resume-after-breakpoint step (`warning: Selected architecture
i386:x86-64 is not compatible with reported target architecture
i386:x64-32`) — continuing past a real, correctly-caught hit
(`X_pop_engine`/`PLANETFALL`, unrelated to the bug being chased) crashed
the process with SIGSEGV at the breakpoint's own address. The game's own
crash handler caught it and recovered cleanly (confirmed after the fact:
the autoplay session continued normally to its full planned length) — an
earlier draft of this investigation wrongly assumed the crash had left
the process in a corrupted state, which the user corrected. A passive,
read-only attach (no breakpoints) worked fine and confirmed a live "WE
HAVE ACQUIRED TECHNOLOGY!" popup was genuine (not a stale artifact) by
reading `StrBuffer`/`ParseStrBuffer` directly, but background threads
were all parked in symbol-less Wine host binaries with no usable
backtrace, so it didn't identify a new root cause. **Conclusion: don't
set software breakpoints on this WoW64 build** — hardware watchpoints
(`watch`, not `break`) were never tried and might survive a resume since
they don't patch code bytes, worth trying first if this is ever revisited.

Given six rounds of chasing individual sources still left the door open
for the next not-yet-found announcement, changed strategy instead of
continuing to disassemble: `autoplay_dismiss_dialog()` (`src/
autoplay.h`/`.cpp`) detects "some window other than the map/base/design
screen has focus" via `Win_get_key_window()` (previously read-only,
`gui.cpp`'s own `current_window()`) and posts a synthetic Enter keypress
via `PostMessage`, reusing a pattern already proven elsewhere in
`gui.cpp` (`WM_MOUSEWHEEL`-to-arrow-key translation). Wired into
`mod_blink_timer` alongside `autoplay_try_end_turn`, same idle-callback
cadence, same "experimental, unverified" framing that function shipped
with. **Live-verified: 3 separate autoplay runs, zero blocking popups,
zero crashes.** This is now the standing mechanism — a genuinely new
announcement should be caught by construction, not require another
disassembly round.

### Planetary Council: found a scenario-rules flag instead of reverse-engineering `CouncilWindow`; unattended autoplay achieved (supports `IMPLEMENTATION_DETAILS.md` 5.3)

One of the three clean dismiss-mechanism runs still needed a manual
click for a Planetary Council interaction — confirmed live that the
generic Enter-dismiss does not resolve it, unlike every popup so far.
Rather than reverse-engineer `CouncilWindow` (`0x6FEC80`, zero prior
investigation in this codebase, unlike `BasePop`/`Popup`'s dozens of
already-mapped methods) to simulate a real vote, found that
`can_call_council` (`0x52C670`) already tests a real scenario-rules
flag — `MRULES_NO_PLANETARY_COUNCIL` (`GameMoreRules`/`0x9A681C`, bit
`0x4`) — and returns false unconditionally when it's set, confirmed by
disassembly. Forcing this flag whenever `conf.autoplay` is on
(`autoplay_demote_human()`, alongside the existing monolith-popup
preference force) disables Planetary Council outright for the session —
a different kind of tradeoff than every other autoplay fix here, since
it removes an actual game mechanic rather than just hiding its UI.
User-confirmed as acceptable: autoplay's job is unattended testing, not
full mechanic fidelity, and this is far lower-risk than simulating a vote
through a UI class with no prior investigation. Also fixed in passing:
`call_council` (`0x52C880`, called unconditionally for every non-human
faction every eligible turn) had its own embedded, unshimmed `NetMsg_pop`
call, same bypass pattern as everywhere else, patched the same way.

**Milestone: a 100-turn autoplay run completed with zero manual
intervention** — closing out the popup-blocking investigation that ran
across both of these dates.
