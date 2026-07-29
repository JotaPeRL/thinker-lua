#!/bin/bash
# Performance baseline comparison harness (IMPLEMENTATION_PLAN.md Phase
# 5.4, IMPLEMENTATION_DETAILS.md 5.4). Deploys a build, launches it
# unattended under autoplay with conf.perf_trace=1 and conf.lua_ai set
# per --mode, watches lua.log for turn progress the same way
# tools/autoplay_run.sh does, and copies perf_trace.log out as soon as
# the run ends -- it's append-mode (like golden_traces.jsonl), so it
# would otherwise mix with the next run's numbers.
#
# Deliberately a separate script from autoplay_run.sh rather than a
# shared library the two source: that script has a lot of hard-won,
# machine-specific quirk-handling (Xvfb display discovery, the
# cwd-must-be-$GAME_DIR launcher requirement, the "thinker.exe's own
# launcher exits by design, don't mistake that for a crash" liveness
# check, the process-group kill sequence) and this avoids coupling two
# independently-evolving scripts to a common abstraction neither asked
# for. See autoplay_run.sh's own comments for the full story behind each
# quirk reused here.
#
# Usage:
#   tools/perf_run.sh --mode lua|cpp [options]
#
# Options:
#   --mode lua|cpp            Required. lua = conf.lua_ai=1, the Lua-driven
#                             port (what a normal game runs). cpp =
#                             conf.lua_ai=0, the original C++ AI -- this IS
#                             the performance baseline.
#   --preset develop|debug   Build to deploy (default: debug -- needed for
#                             debug.txt if the run crashes).
#   --turns N                Stop after this many completed turns (default: 100).
#   --timeout SECONDS        Stall timeout: no new turn within this many
#                             seconds classifies the run as STALL and kills
#                             it (default: 300; 0 disables).
#   --poll SECONDS            Watchdog poll interval (default: 5).
#   --game-dir DIR            Game install (default: $SMAC_DIR or
#                             ~/.wine-smac/drive_c/Games/SMAC).
#   --wineprefix DIR           WINEPREFIX (default: ~/.wine-smac).
#   --save FILE                 Forwarded to `wine` as an extra argument, on
#                             the chance the engine honors a bare save path
#                             on its command line -- UNVERIFIED, same
#                             caveat as autoplay_run.sh's own --save.
#   --no-xvfb                 Launch on the real/current display instead of
#                             an allocated Xvfb one. On this dev machine
#                             Xvfb mode crashes before the game window ever
#                             comes up (see autoplay_run.sh's KNOWN GAP #2)
#                             -- pass this until that's fixed.
#   --rng-seed N               Pin the mod's own RNG (src/main.cpp), same as
#                             autoplay_run.sh's own --rng-seed. Recommended
#                             for a real comparison: run --mode cpp and
#                             --mode lua with the SAME --rng-seed and the
#                             same starting save, so at least turn 1 draws
#                             identically before the two AIs' own decisions
#                             (necessarily) start to diverge.
#
# Artifacts land under runs/<UTC timestamp>-perf-<mode>-<preset>/ (repo
# root): perf_trace.log (the whole point), lua.log, autoplay.log,
# debug.txt (debug preset only), outcome.txt.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

MODE=""
PRESET="debug"
TARGET_TURNS=100
TIMEOUT_SECONDS=300
POLL_INTERVAL=5
GAME_DIR="${SMAC_DIR:-$HOME/.wine-smac/drive_c/Games/SMAC}"
WINEPREFIX_DIR="$HOME/.wine-smac"
SAVE_FILE=""
USE_XVFB=1
RNG_SEED=""

while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --preset) PRESET="$2"; shift 2 ;;
        --turns) TARGET_TURNS="$2"; shift 2 ;;
        --timeout) TIMEOUT_SECONDS="$2"; shift 2 ;;
        --poll) POLL_INTERVAL="$2"; shift 2 ;;
        --game-dir) GAME_DIR="$2"; shift 2 ;;
        --wineprefix) WINEPREFIX_DIR="$2"; shift 2 ;;
        --save) SAVE_FILE="$2"; shift 2 ;;
        --rng-seed) RNG_SEED="$2"; shift 2 ;;
        --no-xvfb) USE_XVFB=0; shift ;;
        -h|--help) awk 'NR==1{next} /^#/{sub(/^#/,""); print; next} {exit}' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

case "$MODE" in
    lua) LUA_AI=1 ;;
    cpp) LUA_AI=0 ;;
    "") echo "error: --mode lua|cpp is required" >&2; exit 1 ;;
    *) echo "error: --mode must be lua or cpp, got: $MODE" >&2; exit 1 ;;
esac

case "$PRESET" in
    develop|debug) ;;
    *) echo "error: --preset must be develop or debug, got: $PRESET" >&2; exit 1 ;;
esac

BUILD_DIR="$ROOT/build/$PRESET"
if [ ! -f "$BUILD_DIR/thinker.dll" ]; then
    echo "error: no build found in $BUILD_DIR (run: cmake --build --preset ninja-$PRESET)" >&2
    exit 1
fi

REQUIRED_CMDS=(wine)
[ "$USE_XVFB" = "1" ] && REQUIRED_CMDS+=(xvfb-run)
for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "error: $cmd not found in PATH" >&2; exit 1; }
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-perf-$MODE-$PRESET"
RUN_DIR="$ROOT/runs/$RUN_ID"
mkdir -p "$RUN_DIR"
echo "run directory: $RUN_DIR"

# --- Deploy -------------------------------------------------------------
"$ROOT/tools/deploy.sh" "$PRESET" "$GAME_DIR"

# --- thinker.ini: force the settings this harness needs, restore after --
INI_PATH="$GAME_DIR/thinker.ini"
INI_BACKUP=""
INI_WRITTEN_BY_US=0

RESTORED_INI=0
restore_ini() {
    [ "$RESTORED_INI" = "1" ] && return
    RESTORED_INI=1
    if [ -n "$INI_BACKUP" ] && [ -f "$INI_BACKUP" ]; then
        mv -f "$INI_BACKUP" "$INI_PATH"
    elif [ "$INI_WRITTEN_BY_US" = "1" ]; then
        rm -f "$INI_PATH"
    fi
}
# Runs on any exit -- normal completion, an early `exit` on error, or the
# user Ctrl+C-ing the watchdog loop -- so a harness run never leaves
# perf_trace=1/autoplay=1 permanently applied to the user's game folder.
trap restore_ini EXIT

if [ -f "$INI_PATH" ]; then
    INI_BACKUP="$(mktemp "${INI_PATH}.harness-backup.XXXXXX")"
    cp "$INI_PATH" "$INI_BACKUP"
fi
cp "$ROOT/docs/thinker.ini" "$INI_PATH"
INI_WRITTEN_BY_US=1
# docs/thinker.ini's shipped defaults (autoplay=0, lua_shadow=0) are for
# normal play; force what this run actually needs regardless of what the
# shipped file says. lua_shadow is forced to 0 (not just left at the
# template default) because shadow mode calls into Lua on every hooked
# call purely for comparison, even when lua_ai=0 -- exactly the overhead
# a --mode cpp baseline must not have. Keep CRLF (\r) -- project
# convention, same as autoplay_run.sh's own sed here.
sed -i \
    -e 's/^autoplay=.*/autoplay=1\r/' \
    -e "s/^lua_ai=.*/lua_ai=$LUA_AI\r/" \
    -e 's/^lua_shadow=.*/lua_shadow=0\r/' \
    -e 's/^lua_strict=.*/lua_strict=0\r/' \
    "$INI_PATH"
# perf_trace/minimal_popups are unlisted debug-only options (src/main.h:
# "unlisted option") not in docs/thinker.ini's template, so they can't be
# sed-replaced -- append them, same pattern as autoplay_run.sh's own
# minimal_popups append.
printf 'perf_trace=1\r\n' >> "$INI_PATH"
printf 'minimal_popups=1\r\n' >> "$INI_PATH"
if [ -n "$RNG_SEED" ]; then
    printf 'fixed_rng_seed=%s\r\n' "$RNG_SEED" >> "$INI_PATH"
fi

# --- Clean stale logs from any prior session -----------------------------
# lua.log/autoplay.log are append-mode; without this a stale log from a
# previous session would make the first poll below see an already-advanced
# turn number and mis-time the stall window. perf_trace.log is ALSO
# append-mode (deliberately, like golden_traces.jsonl) but unlike those
# two it must NOT survive into this run -- a stale one would silently mix
# a previous run's per-turn numbers into this run's comparison.
rm -f "$GAME_DIR/lua.log" "$GAME_DIR/autoplay.log" "$GAME_DIR/debug.txt" "$GAME_DIR/perf_trace.log"

# --- Launch -------------------------------------------------------------
# cwd MUST be $GAME_DIR before exec'ing wine -- thinker.exe's own launcher
# (src/launch.cpp) checks for "terranx.exe" relative to its process's cwd,
# not its own .exe location. See autoplay_run.sh's own comment on this
# exact point for how that was found.
WINE_ARGS=(wine "$GAME_DIR/thinker.exe" -windowed)
if [ -n "$SAVE_FILE" ]; then
    WINE_ARGS+=("$SAVE_FILE") # unverified, see --save above
fi

if [ "$USE_XVFB" = "1" ]; then
    ( cd "$GAME_DIR" && exec setsid xvfb-run -a env -u WAYLAND_DISPLAY WINEPREFIX="$WINEPREFIX_DIR" "${WINE_ARGS[@]}" ) \
        >"$RUN_DIR/launch.out" 2>&1 &
    RUN_PID=$!
    echo "launched under Xvfb (process group $RUN_PID)"
else
    ( cd "$GAME_DIR" && exec setsid env WINEPREFIX="$WINEPREFIX_DIR" "${WINE_ARGS[@]}" ) \
        >"$RUN_DIR/launch.out" 2>&1 &
    RUN_PID=$!
    echo "launched on the current display (process group $RUN_PID)"
fi

# --- Watchdog ---------------------------------------------------------
# game_alive: NOT just `kill -0 $RUN_PID` -- thinker.exe's launcher exits
# by design once it has injected the DLL into terranx.exe and resumed it,
# so $RUN_PID disappears on every successful run, not just crashed ones.
# See autoplay_run.sh's own comment on this exact point.
game_alive() {
    kill -0 "$RUN_PID" 2>/dev/null && return 0
    pgrep -x terranx.exe >/dev/null 2>&1 && return 0
    return 1
}

LUA_LOG="$GAME_DIR/lua.log"
LAST_TURN=""
LAST_PROGRESS="$(date +%s)"
OUTCOME=""
DETAIL=""

while true; do
    sleep "$POLL_INTERVAL"
    NOW="$(date +%s)"

    if ! game_alive; then
        OUTCOME="CRASH"
        DETAIL="neither pid $RUN_PID nor a terranx.exe process found (last turn seen: ${LAST_TURN:-none})"
        break
    fi

    CUR_TURN=""
    if [ -f "$LUA_LOG" ]; then
        CUR_TURN="$(grep -oP 'state_hash turn=\K[0-9]+' "$LUA_LOG" 2>/dev/null | tail -1)"
    fi
    if [ -n "$CUR_TURN" ] && [ "$CUR_TURN" != "$LAST_TURN" ]; then
        LAST_TURN="$CUR_TURN"
        LAST_PROGRESS="$NOW"
        echo "$(date -u +%FT%TZ) turn $LAST_TURN"
    fi

    if [ -n "$LAST_TURN" ] && [ "$LAST_TURN" -ge "$TARGET_TURNS" ] 2>/dev/null; then
        OUTCOME="COMPLETED"
        DETAIL="reached turn $LAST_TURN (target $TARGET_TURNS)"
        break
    fi

    if [ "$TIMEOUT_SECONDS" -gt 0 ] 2>/dev/null \
       && [ $((NOW - LAST_PROGRESS)) -ge "$TIMEOUT_SECONDS" ]; then
        OUTCOME="STALL"
        DETAIL="no new turn for ${TIMEOUT_SECONDS}s (last turn seen: ${LAST_TURN:-none})"
        break
    fi
done

echo "outcome: $OUTCOME -- $DETAIL"

# --- Collect artifacts, then kill everything -----------------------------
# Same kill sequence as autoplay_run.sh -- process-group TERM, then
# pkill-by-name (terranx.exe is very often not a descendant of $RUN_PID by
# the time we get here), then a KILL escalation, then a wineserver sweep.
# Single-user dev tool caveat also carries over: don't run two of these
# against the same WINEPREFIX at once.
if kill -0 "$RUN_PID" 2>/dev/null; then
    kill -TERM "-$RUN_PID" 2>/dev/null || kill -TERM "$RUN_PID" 2>/dev/null
fi
pkill -TERM -x terranx.exe 2>/dev/null
for _ in $(seq 1 10); do
    game_alive || break
    sleep 1
done
if game_alive; then
    kill -KILL "-$RUN_PID" 2>/dev/null || kill -KILL "$RUN_PID" 2>/dev/null
    pkill -KILL -x terranx.exe 2>/dev/null
fi
wait "$RUN_PID" 2>/dev/null
WINEPREFIX="$WINEPREFIX_DIR" wineserver -k 2>/dev/null

[ -f "$GAME_DIR/perf_trace.log" ] && cp "$GAME_DIR/perf_trace.log" "$RUN_DIR/perf_trace.log"
[ -f "$LUA_LOG" ] && cp "$LUA_LOG" "$RUN_DIR/lua.log"
[ -f "$GAME_DIR/autoplay.log" ] && cp "$GAME_DIR/autoplay.log" "$RUN_DIR/autoplay.log"
[ -f "$GAME_DIR/debug.txt" ] && cp "$GAME_DIR/debug.txt" "$RUN_DIR/debug.txt"

{
    echo "mode: $MODE (lua_ai=$LUA_AI)"
    echo "preset: $PRESET"
    echo "target_turns: $TARGET_TURNS"
    echo "timeout_seconds: $TIMEOUT_SECONDS"
    echo "rng_seed: ${RNG_SEED:-none}"
    echo "outcome: $OUTCOME"
    echo "detail: $DETAIL"
    echo "last_turn_seen: ${LAST_TURN:-none}"
} > "$RUN_DIR/outcome.txt"

echo "artifacts: $RUN_DIR"
if [ ! -f "$RUN_DIR/perf_trace.log" ]; then
    echo "warn: no perf_trace.log was produced -- check that the build includes src/perf_trace.cpp" >&2
fi
case "$OUTCOME" in
    COMPLETED) exit 0 ;;
    STALL) exit 2 ;;
    CRASH) exit 3 ;;
    *) exit 1 ;;
esac
