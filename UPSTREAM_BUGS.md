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
