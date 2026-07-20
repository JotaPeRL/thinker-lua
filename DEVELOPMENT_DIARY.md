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

### Dialog-bypass spike, round 2 (supports `IMPLEMENTATION_DETAILS.md` 5.3.1)

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

### Social-engineering port session (supports `IMPLEMENTATION_DETAILS.md` 4.5)

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

### War-decision port (`mod_wants_to_attack`, item 2b) — verification (supports `IMPLEMENTATION_DETAILS.md` 4.6)

In-game run (continued from the social-AI session, turn 90): `lua.log`
showed `register_hooks: 4 hook(s) registered`. `debug.txt`: 123
`wants_to_attack` calls across turns 90-92, **zero mismatches**. Both
outcomes exercised (46 `value=0`, 77 `value=1`). One path left unexercised:
`faction_id_unk` was `0` in all 123 calls, so the third-party-ally
adjustment branches never ran — not a problem, just untested (would need a
diplomacy-triggered call with a real third faction).

### Production/plans, first slice (`unit_score`+`find_proto`) — verification (supports `IMPLEMENTATION_DETAILS.md` 4.7)

In-game run (turns 93-100): `lua.log` showed `register_hooks: 5 hook(s)
registered`. `debug.txt`: **769** `find_proto` calls across all 7 AI
factions, **zero mismatches**, zero Lua errors. Coverage was broad: `defend`
both true/false (253/516), 6 distinct triad-flag combinations, 5 distinct
weapon modes. This was the deepest dependency chain ported at the time (two
new structs' worth of fields, a dozen-plus enums, 12 host wrappers) and it
came back clean on the first real session.

### Production/plans, second slice (`select_colony`/`select_combat`) — two rounds (supports `IMPLEMENTATION_DETAILS.md` 4.8)

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

### `select_build` step 1 (VEH exposure + vehicle-count loop) — implementation session (supports `IMPLEMENTATION_DETAILS.md` 4.10.10)

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

### Autoplay harness script — addendum bugs (supports `IMPLEMENTATION_DETAILS.md` 5.3.2)

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
2. **Still open — Xvfb itself appears unable to run the game at all on this
   dev machine.** Even with the cwd fix, under Xvfb the process reliably
   exits ~1-2s after `patch_setup`/`random_reseed` lines land in
   `debug.txt` — before `mod_turn_upkeep`/Lua init ever runs (no `lua.log`
   created at all). `WINEDEBUG=+ddraw,+d3d,+seh` showed a burst of
   `RtlUnwindEx` activity around `wined3d_dll_init` right before the process
   disappears — consistent with a DirectDraw/PRACX surface-creation failure,
   not root-caused past that. `LIBGL_ALWAYS_SOFTWARE=1` made no difference.
   Practical consequence at the time: `--no-xvfb` was the only launch mode
   confirmed to reach the game's window at all. (Later ruled out as a
   graphics-configuration problem entirely — see 5.3.5 below.)

### Real validation runs — 4 rounds, 3 bugs found (supports `IMPLEMENTATION_DETAILS.md` 5.3.3)

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

### Determinism testing across process launches — `fixed_rng_seed` (supports `IMPLEMENTATION_DETAILS.md` 5.3.4)

Attempting the actual determinism check (round 4's seed, re-run against the
same save loaded twice) surfaced a real architectural fact: **the mod's own
RNG stream is not tied to the save file at all.** `DLL_PROCESS_ATTACH` seeds
both `random_reseed()` and `map_rand` from `GetTickCount()` — system uptime
in milliseconds — every time the DLL loads, independent of any save.
Confirmed by two loads of the identical save: the very first `state_hash`
line (turn 1) was byte-identical both times, but turn 2 already diverged.
Root cause is broader than "the human's manually-replayed turn 1 wasn't
pixel-perfect" (the working theory at the time): every other AI-controlled
faction is already making RNG-dependent decisions during that same turn,
before the demoted faction is even in the picture.

**Fixed:** new `fixed_rng_seed` config option, default `0` (unchanged
behavior). When nonzero, used as the seed instead of `GetTickCount()`.

**Abandoned approach, kept here so it isn't retried blind:** pausing the
process with `SIGSTOP` to give the user time to save mid-session doesn't
work — `SIGSTOP` freezes the entire process including its message loop, the
user couldn't even dismiss an open popup. Had to `SIGKILL` and restart.
`fixed_rng_seed` sidesteps the whole problem.

**Exercised live, `fixed_rng_seed` confirmed working, but full determinism
still not achieved.** Test: one save, loaded twice with `--rng-seed
15373264` both times. Two findings:

1. The save itself loads deterministically and the seed pin works exactly
   as designed — all four runs showed identical turn-1 state hashes, and
   `random_reseed` read `15373264` identically in both post-fix runs.
2. **Turn 2 still diverges** even with the seed pinned and the user
   deliberately reproducing identical turn-1 actions. Traced one real
   mechanism: `veh.cpp`'s pod-opening code only reseeds a
   position-independent local stream when `*MultiplayerActive` — in
   single-player, pod contents instead draw from the **main sequential**
   `random()`/`game_rand()` stream, so their outcome depends on everything
   drawn before them that turn, including the other six AI-controlled
   factions' own automatic turn-1 decisions. Not root-caused further at
   this point — hypothesis (not confirmed) was non-deterministic iteration
   somewhere in that turn-1 AI processing.

**Correction (external review, same day):** this is not the "bit-exact only
where achievable" case the project's tolerance framing covers — that
framing is about Lua-vs-C++ tolerance between two different
implementations, not a single binary diverging from itself across two
launches of the identical save with the identical pinned seed. That's
ambient nondeterminism, and it directly blocked the Consolidation gate's
item (d) as originally scoped (a systemic state-hash comparison method).

### RNG divergence diagnostics + Xvfb re-attempt (supports `IMPLEMENTATION_DETAILS.md` 5.3.5)

External review re-ranked the open gaps: the turn-2+ RNG divergence is
**blocking** (invalidates gate item (d)'s whole comparison method), Xvfb is
**not** blocking (item (a)'s validation matrix is already satisfied by
`--no-xvfb`). Diagnostics added this session (save-load RNG snapshot logging,
per-faction RNG draw counters, per-turn RNG state in `state_hashes.log`) —
built but not yet exercised; the actual root-cause run is the 2026-07-16
entry below.

**Xvfb re-attempt**, all three suspects from the earlier "whoever picks this
up next" note, tried individually then combined: higher screen depth/
resolution, the GDI renderer, `WINEDLLOVERRIDES="ddraw=b"` to rule out
PRACX. **No change in any case** — every variant dies at the exact same
point regardless of graphics configuration. Sanity check: `wine notepad`
under the identical Xvfb instance survives fine, ruling out Xvfb-vs-wine
breakage in general. **Conclusion: the DirectDraw/PRACX hypothesis is ruled
out, not just unconfirmed.** No replacement hypothesis tested. Given
`--no-xvfb` already covers every run the harness needs, demoted to
nice-to-have.

---

## 2026-07-16

### RNG pinning root-cause hunt, then abandoned in favor of shadow mode (supports `IMPLEMENTATION_DETAILS.md` 5.3.6)

Cross-launch determinism work found a real bug (`game_rand`, the engine's
own RNG, was never re-seeded by `fixed_rng_seed` — fixed by calling the
existing `game_rand_restore` from `mod_load_daemon`), which pushed
divergence from turn 1 to turn 3 but didn't close it fully. Closed by
decision, not by resolving the remaining turn-3 gap: per-call shadow-mode
comparison (implemented the same day) is strictly stronger evidence of
port fidelity than trajectory comparison, and needs no cross-launch
determinism at all — both sides run inside the same process invocation.
Chasing engine-internal nondeterminism further would be engine debugging,
not AI porting. The only future consumer of trajectory-style comparison
is Movement (M6), which will use a windowed method (reload once, compare
one turn) whose prerequisite — single-turn reproducibility — this work
already delivers.

### Shadow mode, golden traces, port drift — Consolidation gate closed (supports `IMPLEMENTATION_DETAILS.md` 5.1, 5.2.1, 4.11)

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

### `select_build` steps 2–3.4 — four distinct bug classes, same discipline catches all of them (supports `IMPLEMENTATION_DETAILS.md` 4.10.11–4.10.15)

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

### `allow_units` RNG hazard — the hook-argument-threading pattern (supports `IMPLEMENTATION_DETAILS.md` 4.10.16)

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

### Split-block facilities: a second `if (t == FAC_X)` block can hide (supports `IMPLEMENTATION_DETAILS.md` 4.10.17)

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

### Verification methodology correction: absence of a mismatch is not evidence of correctness (supports `IMPLEMENTATION_DETAILS.md` 4.10.20)

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

### `has_project(...) ~= 0` — a `bool`-vs-`int32_t` FFI trap, caught in review (supports `IMPLEMENTATION_DETAILS.md` 4.10.22)

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

### `need_ferry`/`allow_supply` — a refinement gap invisible since step 1 (supports `IMPLEMENTATION_DETAILS.md` 4.10.27)

While wiring `CrawlerUnit`/`FerryUnit` (the first real consumers of
either value), found `select_build_prologue` had been exposing
`count_vehicles`'s raw, loop-accumulated `need_ferry`/`allow_supply` —
but real C++ applies a post-loop refinement (`build.cpp:948-950`) never
ported. Not a new mistake: a gap dating back to step 1 (4.10.10),
invisible until now because `vehicle_counts_check` (the temporary
diagnostic that verifies `count_vehicles`' output) runs *before* that
refinement in the C++ source too, so it structurally never had a chance
to catch it. Fixed inside `select_build_prologue` itself, deliberately
not inside `count_vehicles`, to avoid silently changing what the
existing diagnostic verifies.

### `C.SP_ID_First` vs `E.SP_ID_First` — a wrong-table lookup caught by cross-reference, not by the build (supports `IMPLEMENTATION_DETAILS.md` 4.10.28)

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

### `FormerUnit`/`select_item` — scoped concretely, then deliberately not ported (supports `IMPLEMENTATION_DETAILS.md` 4.10.29)

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

### Unit-branch catalog live-verified; `Satellites` and the remaining untested facilities explicitly deprioritized (supports `IMPLEMENTATION_DETAILS.md` 4.10.30)

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
