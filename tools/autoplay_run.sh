#!/bin/bash
# Autoplay determinism harness (IMPLEMENTATION_PLAN.md "Consolidation gate
# (2026-07-14)", item a). Deploys a build, launches it headless under Xvfb
# with conf.autoplay=1 (bypasses modal popups, demotes the mandatory human
# faction to Thinker AI control -- IMPLEMENTATION_DETAILS.md 5.3.1), watches
# lua.log for the per-turn state-hash line written by
# lua/harness/state_hash.lua, and classifies the outcome (STALL / CRASH /
# COMPLETED) once the run stops making progress, crashes, or reaches the
# requested turn count. Termination is always an EXTERNAL kill of the whole
# process group -- there is no in-game "exit cleanly at turn N" path (the
# deferred autoplay_turns idea, dropped per the plan); this is safe because
# every turn's state is already durable (existing autosave_interval=1) and
# the per-turn state hash gives an independent, externally-observable
# progress signal, so an abrupt kill loses nothing needed for diagnosis.
#
# KNOWN GAP, not solved by this script: Xvfb is headless, and the game has
# no command-line flag to auto-load a save or skip its main/New-Game menu
# (checked: only -smac/-native/-screen/-windowed are handled, src/main.cpp).
# Reaching an actual in-progress all-AI game therefore still needs one
# interactive session first (e.g. attach a VNC viewer to the Xvfb display
# this script allocates, or run the same launch command without Xvfb on a
# real display) to get through the New Game screen once and save -- this
# script only automates the part after that: unattended turn advancement,
# monitoring, and artifact collection. Loading that save automatically on
# each harness run is unimplemented; --save is accepted and forwarded to
# `wine` as an extra argument on the chance the engine honors a bare save
# path on its command line, but this is UNVERIFIED.
#
# Usage:
#   tools/autoplay_run.sh [options]
#
# Options:
#   --preset develop|debug   Build to deploy (default: debug -- needed for
#                             debug.txt, the CRASH artifact).
#   --turns N                Stop after this many completed turns (default: 100).
#   --timeout SECONDS        Stall timeout: no new turn within this many
#                             seconds classifies the run as STALL (default: 300).
#   --poll SECONDS            Watchdog poll interval (default: 5).
#   --game-dir DIR            Game install (default: $SMAC_DIR or
#                             ~/.wine-smac/drive_c/Games/SMAC).
#   --wineprefix DIR           WINEPREFIX (default: ~/.wine-smac).
#   --save FILE                 See KNOWN GAP above -- unverified.
#
# Artifacts land under runs/<UTC timestamp>-<preset>/ (repo root): lua.log,
# autoplay.log, debug.txt (debug preset only), state_hashes.log (just the
# per-turn hash lines, for `cmp` between runs per plan 5.3), saves/, and
# outcome.txt (classification + details). stall.png is added on STALL when
# a screenshot could be captured.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PRESET="debug"
TARGET_TURNS=100
TIMEOUT_SECONDS=300
POLL_INTERVAL=5
GAME_DIR="${SMAC_DIR:-$HOME/.wine-smac/drive_c/Games/SMAC}"
WINEPREFIX_DIR="$HOME/.wine-smac"
SAVE_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --preset) PRESET="$2"; shift 2 ;;
        --turns) TARGET_TURNS="$2"; shift 2 ;;
        --timeout) TIMEOUT_SECONDS="$2"; shift 2 ;;
        --poll) POLL_INTERVAL="$2"; shift 2 ;;
        --game-dir) GAME_DIR="$2"; shift 2 ;;
        --wineprefix) WINEPREFIX_DIR="$2"; shift 2 ;;
        --save) SAVE_FILE="$2"; shift 2 ;;
        -h|--help) awk 'NR==1{next} /^#/{sub(/^#/,""); print; next} {exit}' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done

case "$PRESET" in
    develop|debug) ;;
    *) echo "error: --preset must be develop or debug, got: $PRESET" >&2; exit 1 ;;
esac

BUILD_DIR="$ROOT/build/$PRESET"
if [ ! -f "$BUILD_DIR/thinker.dll" ]; then
    echo "error: no build found in $BUILD_DIR (run: cmake --build --preset ninja-$PRESET)" >&2
    exit 1
fi

for cmd in xvfb-run wine; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "error: $cmd not found in PATH" >&2; exit 1; }
done

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$PRESET"
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
# autoplay=1/lua_strict=0 permanently applied to the user's game folder.
trap restore_ini EXIT

if [ -f "$INI_PATH" ]; then
    INI_BACKUP="$(mktemp "${INI_PATH}.harness-backup.XXXXXX")"
    cp "$INI_PATH" "$INI_BACKUP"
fi
cp "$ROOT/docs/thinker.ini" "$INI_PATH"
INI_WRITTEN_BY_US=1
# docs/thinker.ini's shipped defaults (autoplay=0, lua_strict=0) are for
# normal play; force the three this harness run actually depends on,
# regardless of what the shipped file says. Keep CRLF (\r) -- the rest of
# the file is CRLF (project convention) and a stray LF-only line doesn't
# break the parser but is needlessly inconsistent.
sed -i \
    -e 's/^autoplay=.*/autoplay=1\r/' \
    -e 's/^lua_ai=.*/lua_ai=1\r/' \
    -e 's/^lua_strict=.*/lua_strict=0\r/' \
    "$INI_PATH"

# --- Clean stale logs from any prior session -----------------------------
# lua.log/autoplay.log are opened in append mode; without this a stale log
# from a previous manual session would make the very first poll below see
# an already-advanced turn number and mis-time the stall window.
rm -f "$GAME_DIR/lua.log" "$GAME_DIR/autoplay.log" "$GAME_DIR/debug.txt"

# --- Launch under Xvfb ----------------------------------------------------
# setsid: gives the whole xvfb-run/Xvfb/wine tree its own process group so
# `kill -TERM -$RUN_PID` (finish(), below) can take all of it down without
# touching this script or its caller.
before_locks="$(ls /tmp/.X*-lock 2>/dev/null | tr '\n' ' ')"

LAUNCH_ARGS=(env -u WAYLAND_DISPLAY WINEPREFIX="$WINEPREFIX_DIR" wine "$GAME_DIR/thinker.exe" -windowed)
if [ -n "$SAVE_FILE" ]; then
    LAUNCH_ARGS+=("$SAVE_FILE") # unverified, see KNOWN GAP above
fi

setsid xvfb-run -a "${LAUNCH_ARGS[@]}" >"$RUN_DIR/xvfb-run.out" 2>&1 &
RUN_PID=$!
echo "launched (process group $RUN_PID), waiting for Xvfb to come up..."

DISPLAY_NUM=""
for _ in $(seq 1 50); do
    for f in /tmp/.X*-lock; do
        [ -e "$f" ] || continue
        case " $before_locks " in
            *" $f "*) continue ;;
        esac
        DISPLAY_NUM="$(basename "$f" | sed -e 's/^\.X//' -e 's/-lock$//')"
    done
    [ -n "$DISPLAY_NUM" ] && break
    kill -0 "$RUN_PID" 2>/dev/null || break # died before Xvfb even started
    sleep 0.2
done
if [ -n "$DISPLAY_NUM" ]; then
    echo "virtual display: :$DISPLAY_NUM"
else
    echo "warn: could not determine the allocated virtual display; stall screenshots will be skipped" >&2
fi

take_screenshot() {
    local out="$1"
    if [ -z "$DISPLAY_NUM" ]; then
        return 1
    fi
    if command -v xwd >/dev/null 2>&1 && command -v convert >/dev/null 2>&1; then
        xwd -root -display ":$DISPLAY_NUM" -out "$out.xwd" 2>/dev/null \
            && convert "$out.xwd" "$out" 2>/dev/null && rm -f "$out.xwd"
    elif command -v import >/dev/null 2>&1; then
        DISPLAY=":$DISPLAY_NUM" import -window root "$out" 2>/dev/null
    else
        echo "warn: no screenshot tool available (need xwd+convert, or ImageMagick's import)" >&2
        return 1
    fi
}

# --- Watchdog ---------------------------------------------------------
LUA_LOG="$GAME_DIR/lua.log"
LAST_TURN=""
LAST_PROGRESS="$(date +%s)"
OUTCOME=""
DETAIL=""

while true; do
    sleep "$POLL_INTERVAL"
    NOW="$(date +%s)"

    if ! kill -0 "$RUN_PID" 2>/dev/null; then
        OUTCOME="CRASH"
        DETAIL="process group (pid $RUN_PID) exited on its own (last turn seen: ${LAST_TURN:-none})"
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

    if [ $((NOW - LAST_PROGRESS)) -ge "$TIMEOUT_SECONDS" ]; then
        OUTCOME="STALL"
        DETAIL="no new turn for ${TIMEOUT_SECONDS}s (last turn seen: ${LAST_TURN:-none})"
        break
    fi
done

echo "outcome: $OUTCOME -- $DETAIL"

# --- Collect artifacts, then kill everything -----------------------------
if [ "$OUTCOME" = "STALL" ]; then
    take_screenshot "$RUN_DIR/stall.png" \
        && echo "stall screenshot: $RUN_DIR/stall.png" \
        || echo "warn: stall screenshot capture failed or unavailable" >&2
fi

if kill -0 "$RUN_PID" 2>/dev/null; then
    kill -TERM "-$RUN_PID" 2>/dev/null || kill -TERM "$RUN_PID" 2>/dev/null
    for _ in $(seq 1 10); do
        kill -0 "$RUN_PID" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$RUN_PID" 2>/dev/null; then
        kill -KILL "-$RUN_PID" 2>/dev/null || kill -KILL "$RUN_PID" 2>/dev/null
    fi
fi
wait "$RUN_PID" 2>/dev/null

[ -f "$LUA_LOG" ] && cp "$LUA_LOG" "$RUN_DIR/lua.log"
[ -f "$GAME_DIR/autoplay.log" ] && cp "$GAME_DIR/autoplay.log" "$RUN_DIR/autoplay.log"
[ -f "$GAME_DIR/debug.txt" ] && cp "$GAME_DIR/debug.txt" "$RUN_DIR/debug.txt"
[ -d "$GAME_DIR/saves" ] && cp -r "$GAME_DIR/saves" "$RUN_DIR/saves"
if [ -f "$RUN_DIR/lua.log" ]; then
    grep 'state_hash turn=' "$RUN_DIR/lua.log" > "$RUN_DIR/state_hashes.log" || true
fi

{
    echo "preset: $PRESET"
    echo "target_turns: $TARGET_TURNS"
    echo "timeout_seconds: $TIMEOUT_SECONDS"
    echo "outcome: $OUTCOME"
    echo "detail: $DETAIL"
    echo "last_turn_seen: ${LAST_TURN:-none}"
} > "$RUN_DIR/outcome.txt"

echo "artifacts: $RUN_DIR"
case "$OUTCOME" in
    COMPLETED) exit 0 ;;
    STALL) exit 2 ;;
    CRASH) exit 3 ;;
    *) exit 1 ;;
esac
