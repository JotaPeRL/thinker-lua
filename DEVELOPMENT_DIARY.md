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

### `game_rand` pinning + root-cause run (supports `IMPLEMENTATION_DETAILS.md` 5.3.6)

The 5.3.5 diagnostics, run for real (same save, same seed, twice):
`mod_rng`/`map_rng` matched across launches as already known, but
**`game_rand` (the engine's own RNG) did not** — different values at the
exact same point right after `load_daemon()` returns. `fixed_rng_seed` had
only ever pinned the mod's own streams; the engine's `game_rand` was never
touched by it and drifted freely from process start.

**Fixed:** `mod_load_daemon` now calls the existing (until-now-unused)
`game_rand_restore(conf.fixed_rng_seed)` immediately after `load_daemon()`
returns.

**Acceptance run:** same save, same seed, twice. `game_rand` now matches
identically in both. Result: **turns 1 and 2 now match completely**
(state hash and all three RNG-state fields byte-identical). `cmp` on the
full `state_hashes.log` pair: still differs, **first at turn 3**.

**Localization (not root-caused — this is as far as this session went):**
diffing the two `debug.txt`s found the first difference during turn 3,
faction 1's processing — one run shows an extra sequence (`veh_init`,
`enemy_move ... Unity Rover`, `set_move_to`) the other doesn't. The
per-faction draw counters immediately before this point were **still
identical** in both runs — so whatever causes the extra event isn't (yet
visibly) a prior draw-count difference; either the same draw produces a
different outcome at this exact call, or something non-RNG-related decides
differently whether the event fires at all.

**Net effect: real, measurable progress (divergence pushed one full turn
later, one genuine bug fixed) but the full-trajectory acceptance criterion
was not met.**

**Closed by decision, not resolved.** Rationale: per-call shadow-mode
comparison (implemented the same day, see below) is strictly stronger
evidence of port fidelity than trajectory comparison, and needs no
cross-launch determinism at all — both sides run inside the same process
invocation. The only future consumer of trajectory-style comparison is
movement (M6), which will use a **windowed** method instead: reload the
same autosave twice, compare exactly one turn, not a full trajectory. That
method's prerequisite is single-turn reproducibility, which this session's
work already delivers. Chasing engine-internal nondeterminism further is
also, on reflection, engine debugging rather than AI porting — outside this
project's charter. Net: the RNG-pinning work is not wasted, it's
re-purposed from "prove two processes reach the same state" (dropped) to
"prove one save reloads deterministically for one turn" (M6's actual need,
already met).

**Resume point, only if M6's windowed method fails for a reason that traces
back to this:** two discriminating tests were proposed (external review)
and deliberately **not run**: (1) binary-diff the turn-2 autosaves between
the two runs — confirms whether state itself is identical at the point
divergence starts; (2) repeat the same-seed pair again and see whether the
divergence point wanders to a different turn or stays put — wandering would
point at genuine nondeterminism (timing, ASLR-dependent container
iteration), a stable turn 3 every time would point at something more
mundane. Do not restart general-purpose determinism-chasing without a
concrete M6 trigger.

### Shadow mode implementation + typed-descriptor refactor (supports `IMPLEMENTATION_DETAILS.md` 5.1.1)

Replaced every hand-rolled per-hook dual-run block with the real
`lua_ai_shadow_call`/`lua_ai_shadow_check` mechanism, gated on
`conf.lua_shadow`. Same pass did the typed hook-descriptor refactor
(`out_count` parameter) — this is what makes `facility_score`/
`governor_priorities` hookable, closing the gap the earlier "implemented,
not dual-run verifiable" status left open. All seven pre-existing hooks
migrated; the manual RNG snapshot/restore some of them carried individually
was removed in favor of `lua_ai_shadow_call` doing it unconditionally for
every hook. Both presets rebuild clean; sanity-checked at build time, then
exercised live the same day (see below).

### Shadow mode exercised live — harness ini-overwrite bug (supports `IMPLEMENTATION_DETAILS.md` 5.1.2)

First actual `lua_shadow=1` session. Two real gaps found and fixed before
any comparison data could be trusted:

- **The harness silently discarded `lua_shadow=1`.** The "force the
  settings this harness needs" block in `tools/autoplay_run.sh` overwrote
  the deployed `thinker.ini` with the shipped template's default
  (`lua_shadow=0`), then only force-set `autoplay`/`lua_ai`/`lua_strict`/
  `minimal_popups`, never `lua_shadow` — found live when asked to confirm a
  completed run's results. A run launched this way never invoked the Lua
  side for comparison at all. Fixed with a new `--lua-shadow` flag.
- **No way to confirm which flags were actually in effect after the fact.**
  Zero mismatch lines in `lua.log` is the expected output both when shadow
  ran and matched perfectly, and when shadow was never active at all —
  indistinguishable from the log alone. Fixed with a `config: lua_ai=...
  lua_shadow=... lua_strict=... autoplay=...` line at Lua runtime init.

With both fixes in place: first full run, `register_hooks: 11 hook(s)
registered`, `outcome: COMPLETED` at turn 71, **zero mismatch lines** across
all 9 hooked decision functions. Second run, new game deliberately including
a `rule_psi` faction: `outcome: COMPLETED` at turn 70, zero mismatches
again. Third run, another distinct new game: `outcome: COMPLETED` at turn
70, zero mismatches. **Consolidation gate item (d)'s acceptance criterion
met: zero divergences across 3 distinct saves/maps, including one with
`rule_psi`.**

### Golden traces, first slice — implementation and real-corpus replay (supports `IMPLEMENTATION_DETAILS.md` 5.2.1)

Built the capture side (`src/golden_trace.h`/`.cpp`, gated on
`conf.golden_trace`) and the replay runner (`tools/golden_trace_replay.lua`,
native-`luajit`-only). The replay runner can't load the real
`lua/api/*.lua` modules unmodified (they read live engine memory via
`ffi.cast`, none of which exists outside the actual running game process),
so it overrides the global `dofile` before loading `lua/ai/build.lua`,
substituting fixture-backed stand-ins for the three modules the two
functions under test actually call into.

**One stub couldn't be trivially empty, found before running anything:**
`lua/ffi/validate.lua`'s `types.enums` is read unconditionally at module
load by `governor_priorities`'s `is_human` branch — an empty-table stub made
`E` nil, and any `E.FOO` lookup would have errored immediately. Fixed by
hand-copying the four real `GOV_PRIORITY_*` bit values into the stub.

**Verified genuinely end-to-end:** hand-built fixture lines covering a
correct case, a deliberately-wrong case (to prove the checker isn't
vacuous — confirmed `FAIL` with expected/actual values and nonzero exit
code), and both `governor_priorities` branches. All four behaved exactly as
hand-computed. **Then confirmed against a real capture, same session:** a
`--no-xvfb --golden-trace` autoplay run, replayed — **1265/1265 passed**,
zero failures, across many distinct `facility_score` item IDs (including
negative results) and both `governor_priorities` branches over 100+ distinct
base IDs.

### `select_build` step 2 (`push_item`/`has_retool`/`skip_facility`) — one bug found and fixed (supports `IMPLEMENTATION_DETAILS.md` 4.10.11)

Reused the precedent from step 1: `push_item()` already logs its own final
adjusted score via an existing `debug()` line on every call, so a temporary
diagnostic hook (`push_item_check`) could compute the same score
independently and log it for comparison, no new C++ infrastructure needed
beyond one call site.

**First autoplay run paired 987/987 lines but 985/987 mismatched** — traced
to the hook call site itself, not the port: it sat *after* `push_item`'s own
score adjustments and handed Lua the already-adjusted value, so
`push_item_score` (which independently reapplies the same adjustments)
double-applied them. Fixed by moving the hook call to the top of
`push_item()`, before any mutation. Rebuilt clean, second autoplay run:
**859/859 paired, zero mismatches.**

### `select_build` step 3.1 (shared prologue) — an ordering bug, not a math bug (supports `IMPLEMENTATION_DETAILS.md` 4.10.12)

Read the full current `select_build` body before planning anything, rather
than trusting the original 2026-07-14 scoping pass at face value — accurate
about the overall shape, but it hadn't actually enumerated the branches
(the "~35 facility branches" estimate later turned out to be 15 code blocks
covering 24 facility IDs, not recounted precisely until step 3.4). Ported
only the shared prologue through `Wbase`/`Wthreat`.

**Real bug found and fixed: an ordering bug, not a math bug.** First
autoplay run logged zero comparable lines at all — `lua.log` showed
`attempt to call global 'governor_priorities' (a nil value)`, every single
call. Root cause: `select_build_prologue` was placed *before*
`governor_priorities`'s own `local function` declaration in the file — Lua
locals aren't hoisted, so referencing a not-yet-declared local falls
through to the global namespace, which is nil. Fixed by reordering. This is
a different failure class than step 2's bug (a real double-application
logic error) — worth distinguishing, since this one says nothing about
whether the ported math was correct, only that it never ran. Before
requesting the second run, manually re-checked `Wbase`/`Wthreat` term-by-term
against the C++ — useful discipline, though it wouldn't have caught this
particular bug class since the math itself was fine all along. Second run,
after the fix: **556/556 clean.**

### `select_build` step 3.2 (`DefendUnit`/`CombatUnit` early return) — a shadow-placement bug (supports `IMPLEMENTATION_DETAILS.md` 4.10.13)

Design departure from steps 1-3.1: used real `lua_ai_shadow_call`/`_check`
hooks instead of another throwaway diagnostic one, since `DefendUnit`'s
second branch and `CombatUnit`'s check both consume RNG and neither has an
existing debug line to diff against — a plain hook has no RNG
snapshot/restore and would have permanently desynced the real RNG stream.

**Real bug found and fixed: a shadow-hook placement error, a third distinct
failure class this session.** First run: `defend_unit_*` both clean, but
`combat_unit_early_return` showed **147 mismatches**, always
`lua=[-1] cpp=[<real choice>]`. `select_combat`'s own pre-existing hook
stayed at 0 mismatches in the same run, isolating the bug to the new code.
Root cause: `lua_ai_shadow_call` was placed *after* C++'s own
`select_combat(...)` call already ran and consumed its RNG draws, instead
of before it — since Lua's `combat_unit_early_return` independently calls
`select_combat` itself, it started from an already-advanced RNG position,
so the two calls were never operating on aligned RNG state even though
`select_combat`'s logic itself was fine. Fixed by moving the shadow-call
line to the top of the block, before C++'s own call. Second run: all three
hooks clean.

**Three distinct bug classes this session, worth keeping straight:** step
2's bug was a double-application (an already-adjusted value fed back into a
function that re-adjusts it); step 3.1's was a pure ordering error (a
forward reference to a not-yet-declared Lua local); this one is a
shadow-call placement error relative to an RNG-consuming call the Lua side
re-invokes independently. All three were caught by the same discipline:
ship the diagnostic/shadow hook, run it against real data, don't assume
"builds clean" means "is correct."

### `select_build` step 3.3 (`build_order` loop skeleton, 14 no-branch facilities) (supports `IMPLEMENTATION_DETAILS.md` 4.10.14)

Cataloged the loop skeleton before planning: of `build_order[]`'s 36-ish
facility entries (later recounted precisely as 38), ~14 have no dedicated
scoring branch at all — for exactly those, the shared per-item base-score
formula is a complete computation. Live run: **587 mismatches, and every
one falls on a facility with a real, not-yet-ported branch** — zero
mismatches on any of the 14 no-branch facilities, confirmed by checking
there's no overlap between mismatched item_ids and the 14 expected-clean
ones, not just eyeballing a low count.

### `select_build` step 3.4 (facility-branch catalog + first branch) — a missing-field bug (supports `IMPLEMENTATION_DETAILS.md` 4.10.15)

Cataloging session: `build_order[]` has 47 entries (9 unit sentinels + 38
facilities, not the "~45 entries, 36 facilities" quoted around this
session — corrected count, verified programmatically, not by eye). Of the
38 facilities, 14 have no branch (3.3) and 24 do (this section). Implemented
only `FAC_COMMAND_CENTER`/`FAC_NAVAL_YARD`/`FAC_BIOENHANCEMENT_CENTER`,
chosen specifically because it needed no new engine surface.

**Real bug found and fixed — a fourth distinct failure class, not a repeat
of steps 2/3.1/3.2's.** First run: 56 `error in 'build_order_item_score'`
lines, `attempt to compare number with nil`. Root cause:
`select_build_prologue` computes `defend_range` as a local (used internally
since step 3.1) but **never included it in the function's own returned
table** — every prior sub-step happened not to need it externally, so the
gap went unnoticed until this one, the first to reference `r.defend_range`.
Fixed by adding it to the return table. Since this is a shadow hook, the Lua
error was safely contained the whole time — logged and skipped, C++ always
governed regardless — worth noting since a bug here could easily be
mistaken for something that risked real gameplay; it didn't. Second run
confirmed **0 mismatches on all three facilities** across 2234 total
mismatches (all on the other, still-unported facilities).

**Four distinct bug classes found this session, worth the full list:** step
2 — double-application; step 3.1 — pure ordering (forward reference to a
not-yet-declared Lua local); step 3.2 — shadow-call placement relative to an
RNG-consuming call the Lua side re-invokes independently; step 3.4 — a
missing field in a shared return table, invisible until a new caller needed
exactly that field. All four caught the same way: ship the verification,
run it against real data, don't assume "builds clean" or "syntax-checks"
means "is correct."

### Port drift detection — verified against three real outcomes (supports `IMPLEMENTATION_DETAILS.md` 4.11)

Built `tools/port_drift.py` and verified it against three real scenarios,
not just a smoke test:

- **Clean (real run):** `upstream/master`'s current tip *is* the pinned
  commit for every existing entry — reports **11 clean, 0 drifted, 0
  errors**.
- **Drifted (synthetic — pointed at a commit 5 commits before the pin):**
  correctly reports **6 clean, 3 drifted** — the 3 flagged
  (`select_colony`, `social_score`, `mod_social_ai`) are exactly the
  functions actually touched by the intervening "Rewrite faction and
  movement code" commit, and the other 8 correctly report clean. Real
  evidence the diff detection works, not just that the script runs.
- **Error (bogus base ref):** all entries correctly report as errors, exit
  1, rather than crashing or silently reporting false negatives.
