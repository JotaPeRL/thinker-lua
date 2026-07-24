# Upstream bug catalog

Bugs found in `induktio/thinker`'s own C++ (not in this fork's Lua port, and
not introduced by this fork) while porting the AI to Lua. Kept separate from
`IMPLEMENTATION_DETAILS.md`/`DEVELOPMENT_DIARY.md` because these are meant to
eventually become upstream PRs, not fork-internal reference — write-up here
should stand on its own for someone who has never seen the Lua port.

Convention per entry: description, root cause, impact, exact fix (as a diff
against the pinned upstream commit), how it was found, and this fork's own
status (whether the fix has already been cherry-picked here). When opening a
PR from an entry, link back to it by anchor and update its status.

**Baseline:** all line numbers and diffs below are against
`15418b28dc13043b75783ca3f11ce006ab67eaf4` ("Rewrite faction and movement
code", 2026-06-28), the commit this fork is currently pinned to
(`CLAUDE.md`'s remote/branch layout). Re-check against upstream's current tip
before opening a PR — these files are exactly the kind upstream rewrites
often (`IMPLEMENTATION_PLAN.md`'s own drift-detection rationale).

---

## 1. `choose_defender()` skips the hostility check for base targets, letting an ally be picked as "defender" and crashing on its own assert

**Status:** ✅ fixed in this fork (`src/move.cpp`, commit `7bbaa8a`
"Movement stage 6: combat_move sub-stage D…"). Not yet reported/PR'd upstream.

**File:** `src/move.cpp`, `choose_defender(int x, int y, int veh_id_atk, MAP*
sq)`, originally around line 319 (function starts ~line 301 at the pinned
commit).

### The bug

```cpp
// src/move.cpp, at the pinned commit
int choose_defender(int x, int y, int veh_id_atk, MAP* sq) {
    int faction_id = Vehs[veh_id_atk].faction_id;
    int veh_id_def = -1;
    bool is_base = sq && sq->owner != faction_id && sq->is_base();
    if (!non_ally_in_tile(x, y, faction_id)) {
        return -1;
    }
    for (int i = 0, cnt = *VehCount; i < cnt; ++i) {
        VEH* veh = &Vehs[i];
        if (veh->x == x && veh->y == y) {
            veh_id_def = i;
            break;
        }
    }
    if (veh_id_def < 0 || (!is_base && !Vehs[veh_id_def].is_visible(faction_id))) {
        return -1;
    }
    veh_id_def = mod_best_defender(veh_id_def, veh_id_atk, 0);
    if (veh_id_def >= 0 && !is_base && !at_war(faction_id, Vehs[veh_id_def].faction_id)) {
        return -1;
    }
    return veh_id_def;
}
```

The last `if` is a sanity check: "if the picked defender isn't actually at war
with the attacker, this isn't a real target — bail." But it's guarded by
`!is_base`, so **the check is skipped entirely whenever the target tile is an
enemy-owned base.** That guard trusts `mod_best_defender()` (which delegates
to `find_defender()` in `veh_combat.cpp`) to have already picked a genuinely
hostile unit when the target is a base — but `find_defender()` provides no
such guarantee.

`find_defender()` walks the *entire physical stack* of vehicles sitting on
tile `(x, y)` via the engine's own stacking list (`veh_top`/
`next_veh_id_stack`) and scores every single one of them, with **no
faction/hostility filter of any kind**. If a strong allied unit (same faction
as the attacker, or a pact partner) happens to be garrisoned in the same base
tile alongside a weaker actual enemy defender, and it scores higher as "best
defender" by whatever heuristic `find_defender` uses, it gets returned —
unfiltered, because `is_base` skipped the one check that would have caught
it.

### Impact

The caller of `choose_defender()` (`combat_move`, `veh_turn.cpp` movement
dispatch) then hands this "defender" — which may be the **attacker's own
unit**, or an **ally's unit** — to `battle_priority()`
(`src/move.cpp:211-299`), which contains:

```cpp
assert(veh1->faction_id != veh2->faction_id);
```

When the returned "defender" shares a faction with the attacker (the
same-faction case, or effectively the pact-partner case once `at_war` would
have said "no"), this assert fires and **aborts the process** — a hard
crash, not a Lua/scripting issue. All three of this project's build presets
(`debug`/`develop`/`release`) compile with asserts live (none defines
`NDEBUG`), so this was never a debug-only latent risk; it can fire in a
release build too.

Confirmed live: a real ~144-turn play session hit
`Assertion Failed: veh1->faction_id != veh2->faction_id / src/move.cpp 219`
during ordinary AI-vs-AI play (no scripting involved in triggering it —
`combat_move`'s native C++ implementation calls `choose_defender` the exact
same way the ported Lua version does).

### Fix

Remove the `!is_base` escape — make the `at_war` check unconditional for
every caller:

```diff
-    if (veh_id_def >= 0 && !is_base && !at_war(faction_id, Vehs[veh_id_def].faction_id)) {
+    if (veh_id_def >= 0 && !at_war(faction_id, Vehs[veh_id_def].faction_id)) {
         return -1;
     }
```

This is safe for the non-base case too: `at_war(faction_id, faction_id)` is
`false` by construction (`src/faction.cpp:153-156`), so a same-faction pick
is now correctly rejected the same way a pact-partner pick already was for
non-base targets. No other caller of `choose_defender` relies on the
`is_base` escape (checked: `move.cpp:3115, 3128, 3176, 3185, 3234, 3237,
3580-3581` — 6 call sites total, all inside `combat_move`'s own family).

### How it was found

Live-testing the Lua port of `combat_move` (this fork's own porting work,
unrelated to the bug itself) exercised this path for the first time under
sustained play and hit the crash. `lua.log`/`debug.txt` showed zero hook
errors/mismatches up to the crash line, which ruled out the Lua port as the
cause and pointed at `battle_priority`/`choose_defender` — both already
existed as opaque (unported, native-called) host wrappers at that point, so
the native code path was identical whether the C++ or the Lua `combat_move`
was driving. Reading `find_defender()` in full confirmed it has no
hostility filter, which is what made the `is_base` escape unsound.

---

## 2. `search_route()` scores an artifact's home-base baseline against a stale, unrelated tile

**Status:** 🔍 found, **not fixed** (deliberately) in this fork — the Lua
port replicates the bug for 1:1 fidelity (`lua/ai/move.lua`'s `route_score`
gained an optional `sq_x, sq_y` override specifically to reproduce this call
site's behavior; every other call site is unaffected and passes no
override). Not yet reported/PR'd upstream.

**File:** `src/path.cpp`, inside `search_route(TileSearch& ts, int veh_id,
int* tx, int* ty)`, around lines 743–760 at the pinned commit.

### The bug

```cpp
// src/path.cpp, at the pinned commit — abbreviated to the relevant lines
for (int i = 0, cnt = *BaseCount; i < cnt; ++i) {
    BASE* base = &Bases[i];
    if (base->faction_id == veh->faction_id && (sq = mapsq(base->x, base->y))) {
        int score = route_score(veh, base->x, base->y, 4, sq);
        if (score > best_score) {
            px = base->x;
            py = base->y;
            best_score = score;
        }
        if (veh->x == base->x && veh->y == base->y && can_use_teleport(i)) {
            has_gate = true;
        }
    }
}
ts.init(veh->x, veh->y, TS_TERRITORY_PACT);
best_score = INT_MIN;
if (at_base && veh->is_artifact()) {
    best_score = route_score(veh, veh->x, veh->y, 1, sq);
}
```

The first loop scans every base owned by the vehicle's own faction,
reassigning the shared local `sq` to `mapsq(base->x, base->y)` on every
matching iteration — so after the loop, `sq` holds whichever
own-faction base's tile was matched **last**, in `Bases[]` array-index order
(not necessarily the closest, the home base, or anything meaningful to what
follows).

The very next block calls `route_score(veh, veh->x, veh->y, 1, sq)` — note
the coordinates are the **vehicle's own position**, but `sq` is that same
stale, unrelated tile pointer left over from the loop above. It is not
`mapsq(veh->x, veh->y)`, which is what a call scoring the vehicle's own tile
should use, and `sq` is never reassigned to the vehicle's own tile anywhere
between the loop and this call.

### Impact

`route_score(veh, x, y, modifier, sq)` (`src/path.cpp:659-673`) uses `sq` for
several of its terms independently of `x, y`:

```cpp
static int route_score(VEH* veh, int x, int y, int modifier, MAP* sq) {
    AIPlans& plan = plans[veh->faction_id];
    bool sea = is_ocean(sq);
    int score = (sea ? 0 : min(16, Continents[sq->region].tile_count/32))
        + 32*(sq->region == plan.main_region)
        - modifier * (sea ? 2 : 1) * map_range(veh->x, veh->y, x, y)
        - 4*mapdata[{x, y}].target;
    ...
    if (veh->is_combat_unit() && !is_ocean(sq)) {
        score += 2*max(0, Continents[sq->region].pods - Continents[sq->region].tile_count/32);
    }
    return score;
}
```

`is_ocean(sq)`, `Continents[sq->region].tile_count`, `sq->region ==
plan.main_region`, and `Continents[sq->region].pods` are all computed from
**`sq`'s region**, not from the region of `(x, y)`. When `search_route`
calls this with `x, y = veh->x, veh->y` but a `sq` belonging to a different
base's tile (a different continent/region is entirely possible), the
resulting "is my current position a good artifact home base" baseline score
is computed using the wrong region's continent size, ocean/land
classification, and pod density — not the vehicle's actual location's.

This baseline is only used in one specific branch (`at_base &&
veh->is_artifact()` — the vehicle is an Artifact-carrying unit currently
sitting at a base) as the value later candidate tiles from the
`TS_TERRITORY_PACT` search must beat to be considered an improvement. A
wrong baseline can make the AI keep an artifact somewhere it shouldn't (if
the stale `sq` inflates the baseline) or relocate it when it shouldn't (if
the stale `sq` deflates it) — a subtle, not obviously crash-causing, AI
misbehavior, not a stability bug like #1.

### Suggested fix

Use the vehicle's own tile, not the leftover loop variable:

```diff
     if (at_base && veh->is_artifact()) {
-        best_score = route_score(veh, veh->x, veh->y, 1, sq);
+        best_score = route_score(veh, veh->x, veh->y, 1, mapsq(veh->x, veh->y));
     }
```

(`mapsq(veh->x, veh->y)` is guaranteed non-NULL here since the vehicle is
`at_base`, i.e. standing on a valid tile.) This mirrors how every other
`route_score` call site in the same function pairs its `(x, y)` argument with
the matching `sq`.

### How it was found

Found during a user-directed full sweep of `move.cpp`/`path.cpp` for the
"scoring formula wrapped opaquely as if it were engine mechanics" mistake
class (the same defect this fork's own `want_convoy` port had briefly
introduced and then fixed) — reading `route_score`/`search_route` in full
while scoping their Lua port surfaced this specific call site's stale-`sq`
inconsistency. Confirmed via `git blame` that both lines are original
upstream code (`Induktio`, commits `a767cdc0` 2024-08-25 and `3ced7bb0`
2025-01-05), not something introduced by this fork's own history.

**Note for the eventual PR:** this fork's Lua port deliberately *replicates*
this bug rather than fixing it (project rule: port 1:1 before improving
behavior). If/when this is fixed upstream, the corresponding
`sq_x, sq_y`-override plumbing in `lua/ai/move.lua`'s `route_score` and its
one call site in `search_route`'s Lua port should be removed/simplified to
match — see `IMPLEMENTATION_DETAILS.md` 4.12–4.15 and
`DEVELOPMENT_DIARY.md`, 2026-07-22, for where that lives in this fork.

---

## 3. `combat_move`'s artillery repositioning branch has no way to know a chosen move will fail, and no backstop when it keeps failing — units get stuck retrying the same rejected move forever

**Status:** ✅ fixed in this fork (`src/move.cpp` and `lua/ai/move.lua`,
uncommitted at time of writing), in two layers — see "Fix applied". Not yet
reported/PR'd upstream.

**Files:**
- `src/move.cpp:3217-3231`, inside `combat_move`, the
  `arty && !veh->moves_spent && ...` branch (candidate repositioning score
  for artillery-mode units). Lua port: `lua/ai/move.lua:2853-2871`
  (identical shape).
- `src/move.cpp:376-390`, `allow_move()` — the only filter that branch used
  before this fix; doesn't know about Zone of Control.
- `src/veh_action.cpp:2120-2129`, inside `order_veh` — one confirmed
  runtime gate that silently blocks the move for AI-controlled factions
  when source and target are both under enemy ZOC. Not the only one that
  can reject this branch's chosen move — see "Confirmed via live
  instrumentation", round 3.
- `src/path.cpp:226-232`, `mod_zoc_move(x, y, faction_id)` — returns
  faction_id+1 (truthy) when tile `(x, y)` is not a base and is under enemy
  Zone of Control, 0 otherwise.
- `src/veh_action.cpp` `MOV_END` (the label every `order_veh` exit path
  reaches): on a failed move, for a non-human faction, increments
  `veh->iter_count`. This is the signal the second fix layer relies on.
- `src/move.cpp:3484` (Lua: `move.lua:3141`) — `combat_move`'s *existing*
  `iter_count >= 4` give-up check, gated on `at_base`. Never fires for the
  stuck units found live (all had `at_base == false`), which is why the
  loop wasn't already bounded before this fix.

**Note on how this was found:** the user first reported a repeating
`AMPHIBBASE2` popup ("the channel between a sea base and land can only be
crossed by units with the Amphibious Pods ability..."), which pointed
initial investigation at `has_transport()`/`MOV_NAVAL`'s naval-transport
check. That angle turned out to be a dead end — live instrumentation
(below) showed the actually-reproducing stuck units were never at a base or
on an ocean tile at all, so the amphibious-specific gate could never have
applied to them. The real mechanism, confirmed by the same instrumentation,
is Zone of Control, unrelated to sea crossings — the popup symptom may have
had a separate, not-yet-reproduced cause, or may not have been this bug at
all. Recorded here since the ZOC bug is real, confirmed, and fixed;
revisit if the original popup resurfaces with a save where a unit is
genuinely stuck at a sea base.

### The bug

`combat_move`'s artillery-mode candidate scan picks a repositioning tile
using only `allow_move()` as a filter:

```cpp
// src/move.cpp:3217
} else if (arty && !veh->moves_spent
&& (score = cover_score(ts.rx, ts.ry) - 4*ts.dist) > best_cover
&& allow_move(ts.rx, ts.ry, faction_id, triad)) {
    tx = ts.rx;
    ty = ts.ry;
    best_cover = score;
```

`allow_move()` (`move.cpp:376`) checks terrain/triad compatibility,
ownership/diplomacy, and tile occupancy — **it has no notion of Zone of
Control**:

```cpp
bool allow_move(int x, int y, int faction_id, int triad) {
    MAP* sq;
    if (!(sq = mapsq(x, y)) || non_ally_in_tile(x, y, faction_id)) {
        return false;
    }
    if (triad != TRIAD_AIR && is_ocean(sq) != (triad == TRIAD_SEA)) {
        return false;
    }
    return !sq->is_owned() || sq->owner == faction_id
        || has_pact(faction_id, sq->owner)
        || (at_war(faction_id, sq->owner) && !sq->is_base());
}
```

But the actual per-step move execution does enforce ZOC, unconditionally,
for AI-controlled factions:

```cpp
// src/veh_action.cpp:2120 — inside order_veh
if (!veh_at_sea && !tgt_at_sea) {
    if (Vehs[veh_id].triad() == TRIAD_LAND
    && Vehs[veh_id].plan() != PLAN_PROBE
    && !(Units[Vehs[veh_id].unit_id].ability_flags & ABL_CLOAKED)
    && stack_veh_id < 0
    && mod_zoc_move(veh_x, veh_y, veh_fc_id)
    && mod_zoc_move(tgt_x, tgt_y, veh_fc_id)) {
        if (veh_fc_id != MapWin->cOwner || move_delay || !(*VehAttackFlags & 1)) {
            goto MOV_END; // blocked — this is the branch AI factions take
        }
        ...
    }
}
```

When **both** the unit's current tile and the chosen target tile are under
enemy Zone of Control (`mod_zoc_move` nonzero for both), the move is
rejected outright. The neighboring `attack`-mode branch in `combat_move`
already accounts for ZOC (`if (!ignore_zocs) { max_dist = ts.dist; }`, right
above the arty branch) — but the arty repositioning branch has no equivalent
check, so it can select exactly such a doubly-ZOC-restricted tile.

### Impact

`set_move_to` only queues `ORDER_MOVE_TO`; it does not itself validate the
move. When `order_veh` later tries to execute that order and hits the ZOC
block above, the move fails silently (no state change), and nothing marks
the decision as invalid. Since the unit's position, the enemy's position,
and therefore the ZOC condition are all unchanged, `combat_move` picks the
same (or an equally-blocked) candidate again the next time it's evaluated —
repeatedly within the same turn (the engine keeps revisiting a unit with
unspent moves) and again every subsequent turn, until the ZOC condition
changes (the enemy unit causing it moves or dies) or the stuck unit itself
dies by unrelated means.

### Confirmed via live instrumentation

Three rounds of temporary diagnostic logging (added to `lua/ai/move.lua`,
removed after confirmation each round) were used to test hypotheses against
real gameplay data rather than static reading alone — two of the three
hypotheses tested this way turned out wrong, which is itself the reason a
third round happened:

- **Round 1** logged `tile_is_ocean`/`tile_is_base`/`has_transport`/the
  low-level naval-transport stack check at `combat_move`'s pre-move guard.
  Result: for every reproduced stuck unit, both `ocean` and `base` were
  `false` — ruling out any sea-base/amphibious mechanism for these cases
  (the angle the user's original `AMPHIBBASE2` report pointed at).
- **Round 2** logged `path_cost` (route existence), `mod_zoc_move` for both
  source and target tile, `attack`/`arty` mode, and target occupancy, at
  the point `combat_attack` issues `set_move_to`. Across 378 samples from a
  stuck-unit reproduction: `arty:true` in 96%, `attack:false` in 100%
  (consistent with land artillery skipping normal-attack evaluation),
  `zoc_src:true` (unit's own tile under enemy ZOC) in 88%, `zoc_tgt:true`
  in 82%, target `occupied:false` in 71% (confirming this is repositioning,
  not a real attack on a defended tile). This produced the first fix layer
  below (source-and-target ZOC check) — deployed, but the loop **did not
  stop**: the same units kept retrying the same targets.
- **Round 3**, after the first fix didn't work, logged the raw
  `mod_zoc_move` return values (not just truthiness) at the same point.
  Across 505 fresh samples, the dominant pattern (350/505, ~69%) had the
  unit's own tile under ZOC but the *target* tile not
  (`src=<nonzero> tgt=0`) — exactly the case the first fix's "both sides"
  rule correctly does **not** block, yet the move still failed. Root cause:
  `set_move_to` only queues `ORDER_MOVE_TO` (`veh.cpp:3185-3201`) — no
  pathfinding happens at that point. The actual attempt goes through
  `action()`/`order_veh`, which uses the full pathfinder (`Path::find`,
  `path.cpp`, with its own ZOC-aware routing via `TileSearch::has_zoc`,
  `path.cpp:83-90`) across every intermediate tile of a multi-tile route —
  not just a same-turn direct check between the unit's tile and a distant
  final target several tiles away. Replicating that from inside
  `combat_move`'s target-scoring loop would mean re-implementing the
  pathfinder's own ZOC logic; the original C++ `combat_move` doesn't do
  this either (same `allow_move()`-only filter). This is what motivated the
  second, unconditional fix layer below.

### Fix applied

Two layers, both mirrored identically in `src/move.cpp` and
`lua/ai/move.lua`:

1. **Source-and-target ZOC check** (kept — correct per the one confirmed
   execution-time rule, just not sufficient alone): skip a candidate when
   both the unit's own tile and the candidate tile are under enemy ZOC,
   mirroring `order_veh`'s own check, respecting `ignore_zocs` (already
   computed earlier in the function for probes/non-land triads).
2. **`iter_count` backstop** (the layer that actually breaks the loop):
   `veh->iter_count` increments specifically when a move fails in
   `order_veh`'s `MOV_END` for a non-human faction — a genuine "this unit's
   current decision has failed N times in a row" signal already relied on
   elsewhere in this same function (`move.cpp:3484`, `move.lua:3141`), just
   gated there on `at_base`, which the stuck units never satisfy. Requiring
   `iter_count < 4` (the same threshold used throughout this file) to even
   consider an arty-repositioning candidate means that once a target keeps
   getting rejected — for *any* reason, ZOC or otherwise — the branch stops
   proposing it and the function falls through to its normal
   no-candidate-found path instead of repeating the same failed order.

```cpp
// src/move.cpp
} else if (arty && !veh->moves_spent
&& (score = cover_score(ts.rx, ts.ry) - 4*ts.dist) > best_cover
&& allow_move(ts.rx, ts.ry, faction_id, triad)
&& (ignore_zocs || !mod_zoc_move(veh->x, veh->y, faction_id)
    || !mod_zoc_move(ts.rx, ts.ry, faction_id))
&& veh->iter_count < 4) {
    tx = ts.rx;
    ty = ts.ry;
    best_cover = score;
```

```lua
-- lua/ai/move.lua (funcs.mod_zoc_move is an unwrapped int32 host call —
-- faction_id+1 or 0 — so `== 0`/`~= 0`, never bare truthy)
elseif arty and v.moves_spent == 0 and arty_score > best_cover
    and funcs.allow_move(rx, ry, faction_id, triad)
    and (ignore_zocs or funcs.mod_zoc_move(v.x, v.y, faction_id) == 0
        or funcs.mod_zoc_move(rx, ry, faction_id) == 0)
    and v.iter_count < 4 then
    tx, ty = rx, ry
    best_cover = arty_score
```

Verified: both presets build clean with the C++ change; the Lua change
passes a native-`luajit` syntax check. Live-tested through three
instrumented rounds during investigation, then a fourth live run of the
final (both-layer) version — see "Known remaining limitation" below for
what that run showed.

### Known remaining limitation — not fixed further, by design

The fourth live-tested round confirmed the `iter_count` backstop works
exactly as designed (retries per turn dropped from 16-18 to a hard cap of
4, confirmed in `debug.txt`: four `combat_attack`/`set_move_to` lines per
stuck vehicle per turn, then silence for the rest of that turn). It does
**not** stop the underlying unit from being stuck — `veh->iter_count` is
reset to 0 every turn in `mod_repair_phase` (`game.cpp:1696`), so the exact
same 4-attempt cycle repeats every subsequent turn until the unit dies by
unrelated means. The reduction is real (roughly 16-18x/turn down to 4x/turn
— a ~75% cut in wasted Lua hook calls and log volume) but the AI still
never successfully repositions these units.

Going further requires understanding *why* `Path_move` (the function that
actually decides the next step, called from `action_go_to`,
`veh_action.cpp:458`) rejects the move even when this project's own
`allow_move()`/`mod_zoc_move()`/`path_cost()` all report it as viable.
`Path_move` is a raw, un-decompiled engine entry point (only its patched
address exists in `patch.cpp:469`, redirecting the original `0x4CB310` to
Thinker's own `action_go_to` — but `Path_move` itself is never
recompiled/exposed as C++ source anywhere in this tree) — its exact
algorithm (route caching, per-step ZOC/stacking checks, tie-breaking) isn't
available to read or replicate. No function in `combat_move`'s own target
scoring, in either language, can predict its answer with certainty; this
was already true of the original C++ `combat_move` before any of this
investigation started, since it uses the same `allow_move()`-only filter
this fix started from.

**Deliberately not pursued further:** a mechanism that lets a unit
remember "this specific target failed repeatedly, avoid it for several
turns" would close this gap, but it's a genuine AI behavior change (new
cross-turn memory that neither the original C++ nor this fork's Lua port
have ever had), not a 1:1-fidelity bug fix — out of scope per this
project's own rule (`IMPLEMENTATION_PLAN.md`: "the port must be 1:1 at
first; AI improvements come later, on top of the Lua base"). The
`iter_count < 4` backstop is the practical floor reachable within that
constraint; the maintainer explicitly chose to accept it rather than
extend scope (2026-07-24).
