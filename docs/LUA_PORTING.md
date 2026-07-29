# Lua port provenance

Every C++ function ported to Lua under `lua/ai/` carries a machine-readable
pointer back to exactly what it was ported *from* — the upstream C++ file,
function name, and the commit that pinned it. That's `port.source`, defined
per-module (`IMPLEMENTATION_PLAN.md` Phase 4.4):

```lua
port.source = {
    mod_tech_val = { file = "src/tech.cpp", func = "mod_tech_val",
        upstream_commit = "15418b28dc13043b75783ca3f11ce006ab67eaf4" },
}
```

This exists because a clean `git merge --ff-only upstream/master` (see
`CLAUDE.md`'s remote layout — `master` mirrors `upstream/master` exactly)
hides *semantic* drift: the merge succeeds with no conflict, but a ported
C++ function's body may have changed upstream since the Lua port was
written, and nothing about a clean merge tells you that. `port.source` is
what makes that a computable fact instead of tribal knowledge.

## Checking for drift

```sh
tools/port_drift.py
```

For every `port.source` entry across `lua/ai/*.lua`, this extracts the
named C++ function's body both at the pinned `upstream_commit` and at the
current tip of `upstream/master` (`git fetch upstream` first if that's
stale), normalizes whitespace/comments, and hashes both. Reports:

- **clean** — upstream hasn't touched this function since the port was
  written; nothing to do.
- **drifted** — upstream's C++ body changed; the Lua port needs a review
  pass to see whether the change matters (behavior fix, new field, dead
  code) and needs porting over.
- **error** — the function couldn't be located/extracted at one of the
  two refs (renamed, removed, or the extraction's regex/brace-matching
  choked on something unusual — see the script's own docstring for its
  known limitations).

Exit code is 0 only when everything is clean; run it before attempting
any `upstream/master` merge, and treat a nonzero exit as "read the
DRIFTED list before merging," not as a hard blocker — some upstream
changes (e.g. a comment or unrelated refactor inside the same function)
are irrelevant to the port.

## Currently ported functions

| Domain | Lua module | Function(s) | C++ origin | Pinned upstream commit |
|---|---|---|---|---|
| Research (tech AI) | `lua/ai/tech.lua` | `mod_tech_val`, `mod_tech_ai` | `src/tech.cpp` | `15418b28` |
| Social engineering | `lua/ai/social.lua` | `social_score`, `mod_social_ai` | `src/faction.cpp` | `15418b28` |
| War decisions | `lua/ai/war.lua` | `evaluate_attack` | `src/faction.cpp` | `15418b28` |
| Production/plans, 1st slice | `lua/ai/build.lua` | `unit_score`, `find_proto` | `src/build.cpp` | `15418b28` |
| Production/plans, 2nd slice | `lua/ai/build.lua` | `select_colony`, `select_combat` | `src/build.cpp` | `15418b28` |
| Production/plans, 3rd slice | `lua/ai/build.lua` | `facility_score`, `governor_priorities` | `src/plan.cpp` | `15418b28` |
| Production/plans, item 3 remainder | `lua/ai/plan.lua` | `former_plans` | `src/plan.cpp` | `15418b28` |
| Production/plans, item 3 remainder | `lua/ai/build.lua` | `mod_base_hurry` | `src/build.cpp` | `15418b28` |
| Production/plans, item 3 remainder | `lua/ai/plan.lua` | `design_units` | `src/plan.cpp` | `15418b28` |
| AI probe decisions, stage 1 of 3 | `lua/ai/probe.lua` | `probe_choose_action` | `src/probe.cpp` | `15418b28` |
| AI probe decisions, stage 2 of 3 | `lua/ai/probe.lua` | `probe_choose_sabotage` | `src/probe.cpp` | `15418b28` |
| AI probe decisions, stage 3 of 3 | `lua/ai/probe.lua` | `probe_choose_frame_target` | `src/probe.cpp` | `15418b28` |

This table is a curated human-readable index, not the source of truth —
that's the `port.source` tables in the Lua files themselves, which is
what `tools/port_drift.py` actually reads. Keep this table in sync
whenever a `port.source` entry is added; it isn't auto-generated.

`select_build` itself (`src/build.cpp`) is not yet ported (Consolidation
gate, `select_build` stages 2-4 still frozen pending gate items c/e —
`IMPLEMENTATION_DETAILS.md` 4.10) and so carries no `port.source` entry
yet.

## Adding a new entry

When porting a new C++ function, add a `port.source` entry in the same
module (or a new one) at the point you write the port, using the
upstream commit you're reading the C++ from as `upstream_commit` — not
necessarily `15418b28` above, which just happens to be the commit every
function ported so far was surveyed against. Add a row to the table
above in the same commit.
