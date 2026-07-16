# CLAUDE.md

Fork of [induktio/thinker](https://github.com/induktio/thinker) (SMACX Thinker
Mod). Goal: port the mod's deterministic AI from C++ to Lua scripts run by an
embedded LuaJIT 2.1 (pinned commit, no fallback interpreter), to make
single-player AI development easier. Lua is a client of a versioned Thinker
API — FFI may implement parts of it, but is not itself the API. Engine bug
fixes, rendering, mapgen, UI and launcher stay in C++ and follow upstream.

Read `IMPLEMENTATION_PLAN.md` (roadmap, phases, normative requirements, one-line
status per item) and `IMPLEMENTATION_DETAILS.md` (tactical, code-grounded
reference: scope, field/enum catalogs, resume points) before starting any work.
`DEVELOPMENT_DIARY.md` is chronological session history (bugs found, dead
ends, decision rationale) — read only when the "why" behind a specific past
decision matters; it is not needed to resume day-to-day work. Update phase
status in the plan as work completes; put narrative/session detail in the
diary, not the plan.

## Build, deploy, run (Arch Linux + Wine)

```sh
cmake --preset ninja-develop && cmake --build --preset ninja-develop
cmake --preset ninja-debug   && cmake --build --preset ninja-debug
tools/deploy.sh develop        # or: debug — copies artifacts to the game folder
WINEPREFIX=~/.wine-smac wine ~/.wine-smac/drive_c/Games/SMAC/thinker.exe -windowed
```

- Cross-compile only: `i686-w64-mingw32-g++` (32-bit Windows DLL). There is no
  native Linux build and no test suite; validation is running the game in Wine.
- Game install: `~/.wine-smac/drive_c/Games/SMAC` (GOG, terranx.exe v2.0).
- `debug` builds enable `BUILD_DEBUG`: `debug.txt` logging, Alt+D/M/V dev
  shortcuts. `develop`/`release` builds compile `debug()` out entirely.

## Conventions

- **Upstream-friendly diffs:** new code goes in new files (`src/luaai.*`,
  `lua/`); existing files get at most a 1–3 line hook per function. Upstream
  rewrites large files often; keep seams minimal and centralized.
- **1:1 port first:** Lua ports must reproduce C++ behavior exactly before any
  AI improvement. C++ originals remain as fallback — never delete them.
- **Determinism:** AI code must use the engine RNG bindings (`rand.*`), never
  `math.random`; no decision may depend on Lua hash-table iteration order.
- **No Lua in `DllMain`:** loader lock — the Lua VM initializes lazily from a
  patched engine callback (`mod_turn_upkeep`), never during DLL attach.
- **FFI boundary:** engine-state *reads* use FFI inside `lua/api/` only; all
  *writes* and engine-function *calls* go through `LuaHostApi` wrappers in C++.
  `lua/ai/` never requires `ffi`.
- **Integer semantics:** in `lua/ai/`, use `cmath.idiv`/`cmath.imod` (C
  semantics); bare `/` and `%` are banned on integers; bitwise via `bit`.
- **Language:** all docs, comments and commit messages in English.
- **Commits:** Do not commit or push unless asked.
- Repo uses CRLF line endings (upstream convention); don't fight the warnings.

## Git

- `origin` = `JotaPeRL/thinker-lua` (SSH), `upstream` = `induktio/thinker`.
- Work happens on `lua-ai`; `master` is a clean mirror of upstream
  (`git fetch upstream && git merge --ff-only upstream/master`).
