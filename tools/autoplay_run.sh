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
# KNOWN GAP #1, not solved by this script: Xvfb is headless, and the game
# has no command-line flag to auto-load a save or skip its main/New-Game
# menu (checked: only -smac/-native/-screen/-windowed are handled,
# src/main.cpp). Reaching an actual in-progress all-AI game therefore
# still needs one interactive session first (e.g. attach a VNC viewer to
# the Xvfb display this script allocates, or run with --no-xvfb on a real
# display) to get through the New Game screen once and save -- this script
# only automates the part after that: unattended turn advancement,
# monitoring, and artifact collection. Loading that save automatically on
# each harness run is unimplemented; --save is accepted and forwarded to
# `wine` as an extra argument on the chance the engine honors a bare save
# path on its command line, but this is UNVERIFIED.
#
# KNOWN GAP #2, demoted to nice-to-have (2026-07-15) -- found on the dev
# machine: under this machine's Xvfb (radv reports itself non-conformant,
# DRI3 unavailable), the game exits ~1-2s after `patch_setup` logs to
# debug.txt -- before mod_turn_upkeep / Lua init ever runs, so no lua.log
# is even created. Original hypothesis (DirectDraw/PRACX surface creation
# failing under headless rendering) tested directly and ruled out: higher
# screen depth/resolution, forcing the GDI renderer (no Direct3D/wined3d
# at all), and disabling PRACX's ddraw.dll override via
# WINEDLLOVERRIDES=ddraw=b -- each alone and all three combined -- made no
# difference, still dies at the identical point every time. A plain
# `wine notepad` survives fine under the same Xvfb instance, ruling out
# Xvfb-vs-wine breakage in general too. Not root-caused further: this
# doesn't look graphics-related at all given the above, but no other
# hypothesis has been tested. **--no-xvfb is currently the only launch
# mode confirmed to reach the game's own window at all** on this machine;
# the default (Xvfb) mode will very likely CRASH before you ever see the
# New-Game-menu gap above. Since --no-xvfb on the real desktop already
# satisfies every validation-matrix run this harness needs, this is no
# longer worth blocking on -- headless only starts to matter for
# *parallel* runs, a later concern. Use --no-xvfb for now.
#
# Usage:
#   tools/autoplay_run.sh [options]
#
# Options:
#   --preset develop|debug   Build to deploy (default: debug -- needed for
#                             debug.txt, the CRASH artifact).
#   --turns N                Stop after this many completed turns (default: 100).
#   --timeout SECONDS        Stall timeout: no new turn within this many
#                             seconds classifies the run as STALL and kills
#                             the run (default: 300). 0 disables this --
#                             useful when a human is expected to sit at a
#                             menu/dialog for a while; use together with
#                             --screenshot-interval so a long silent period
#                             is still observable without auto-killing it.
#   --screenshot-interval SECONDS  While no new turn appears, take a
#                             screenshot every this many seconds (default:
#                             60) into $RUN_DIR/waiting_*.png -- independent
#                             of --timeout, so it also fires with
#                             --timeout 0. Requires a screenshot tool and a
#                             reachable display (Xvfb mode: always; --no-xvfb
#                             mode: only if DISPLAY is set in the
#                             environment this script runs in). 0 disables.
#   --poll SECONDS            Watchdog poll interval (default: 5).
#   --game-dir DIR            Game install (default: $SMAC_DIR or
#                             ~/.wine-smac/drive_c/Games/SMAC).
#   --wineprefix DIR           WINEPREFIX (default: ~/.wine-smac).
#   --save FILE                 See KNOWN GAP #1 above -- unverified.
#   --no-xvfb                 Launch on the real/current display instead of
#                             an allocated Xvfb one -- lets you watch the
#                             window and click through the New Game screen
#                             yourself (KNOWN GAP #1). Everything else
#                             (deploy, ini patching, watchdog,
#                             classification, artifact collection) is
#                             identical. Screenshots still work in this
#                             mode if this script itself is run with
#                             DISPLAY set to a reachable X server (e.g. the
#                             XWayland instance backing a real Wayland
#                             session's X11 compat layer) -- unlike Xvfb
#                             mode, nothing here allocates or discovers a
#                             display for you; export DISPLAY (and
#                             XAUTHORITY if needed) before invoking.
#                             CURRENTLY REQUIRED on the dev machine, not
#                             just recommended: the default (Xvfb) mode
#                             hits KNOWN GAP #2 above and crashes before
#                             the game window ever comes up. Switch back
#                             to the default once #2 is fixed and you've
#                             confirmed the game reaches an in-progress,
#                             turn-advancing state.
#   --rng-seed N               Pin the mod's own RNG (random_reseed/
#                             map_rand, src/main.cpp -- NOT the same as the
#                             map-generation seed) to N instead of
#                             GetTickCount(). Needed for a real determinism
#                             comparison: without this, two process
#                             launches loading the identical save still
#                             diverge starting turn 2, because every AI
#                             faction's random() draws differ between runs
#                             regardless of the save's own state (found
#                             live, 2026-07-15). Omit for normal runs --
#                             this makes every AI faction's dice rolls
#                             identical across runs, which you want for
#                             comparison, not for varied gameplay.
#   --lua-shadow                Force lua_shadow=1 (Plan 5.1 shadow mode:
#                             every hooked AI decision runs both Lua and
#                             C++ side by side, C++ always governs,
#                             mismatches logged to lua.log/debug.txt as
#                             "lua/cpp <hook> mismatch: ..."). Needed
#                             because the ini overwrite below (docs/
#                             thinker.ini's shipped default) is
#                             lua_shadow=0 and nothing else forces it --
#                             a plain autoplay run does NOT exercise
#                             shadow mode even if the deployed thinker.ini
#                             had lua_shadow=1 before this script ran
#                             (found live, 2026-07-16: the ini get
#                             overwritten for the run's duration and only
#                             restored on exit, so the pre-run value never
#                             takes effect while the game is up). Omit for
#                             normal autoplay runs -- shadow mode adds a
#                             second AI call per hook and is only useful
#                             when you intend to inspect the log for
#                             mismatches afterward.
#   --golden-trace              Force golden_trace=1 (Plan 5.2 golden
#                             traces, Consolidation gate item c): appends
#                             one JSON-Lines fixture per facility_score/
#                             governor_priorities call to
#                             golden_traces.jsonl in the game dir --
#                             independent of --lua-shadow, doesn't invoke
#                             Lua at all, just records what C++ computed.
#                             Same "unlisted debug option" append pattern
#                             as minimal_popups below (not in docs/
#                             thinker.ini's shipped template). Unlike
#                             lua.log/debug.txt, golden_traces.jsonl is
#                             NOT cleared between runs -- it's meant to
#                             accumulate into a fixture corpus across
#                             sessions/games, not capture just one run.
#                             Replay offline afterward with native luajit:
#                             luajit tools/golden_trace_replay.lua <path>.
#
# Artifacts land under runs/<UTC timestamp>-<preset>/ (repo root): lua.log,
# autoplay.log, debug.txt (debug preset only), state_hashes.log (just the
# per-turn hash lines, for `cmp` between runs per plan 5.3), saves/, and
# outcome.txt (classification + details). stall.png is added on STALL when
# a screenshot could be captured; waiting_turnN_HHMMSSZ.png is added every
# --screenshot-interval seconds of no progress, regardless of outcome.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PRESET="debug"
TARGET_TURNS=100
TIMEOUT_SECONDS=300
SCREENSHOT_INTERVAL=60
POLL_INTERVAL=5
GAME_DIR="${SMAC_DIR:-$HOME/.wine-smac/drive_c/Games/SMAC}"
WINEPREFIX_DIR="$HOME/.wine-smac"
SAVE_FILE=""
USE_XVFB=1
RNG_SEED=""
LUA_SHADOW=0
GOLDEN_TRACE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --preset) PRESET="$2"; shift 2 ;;
        --turns) TARGET_TURNS="$2"; shift 2 ;;
        --timeout) TIMEOUT_SECONDS="$2"; shift 2 ;;
        --screenshot-interval) SCREENSHOT_INTERVAL="$2"; shift 2 ;;
        --poll) POLL_INTERVAL="$2"; shift 2 ;;
        --game-dir) GAME_DIR="$2"; shift 2 ;;
        --wineprefix) WINEPREFIX_DIR="$2"; shift 2 ;;
        --save) SAVE_FILE="$2"; shift 2 ;;
        --rng-seed) RNG_SEED="$2"; shift 2 ;;
        --lua-shadow) LUA_SHADOW=1; shift ;;
        --golden-trace) GOLDEN_TRACE=1; shift ;;
        --no-xvfb) USE_XVFB=0; shift ;;
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

REQUIRED_CMDS=(wine)
[ "$USE_XVFB" = "1" ] && REQUIRED_CMDS+=(xvfb-run)
for cmd in "${REQUIRED_CMDS[@]}"; do
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
# minimal_popups is an undocumented debug-only option (src/main.h: "unlisted
# option", DEBUG-gated in src/main.cpp) not in docs/thinker.ini's template,
# so it can't be sed-replaced -- append it. Removes the BEGINPROJECT/
# CHANGEPROJECT/DONEPROJECT call sites entirely (src/patch.cpp), which live
# inside the un-decompiled engine binary and call their popups by hardcoded
# address, bypassing the six autoplay-shimmed primitives entirely (found
# live, 2026-07-15: secret-project completion needed two manual clicks even
# with autoplay=1). Only covers project dialogs, not the still-open tech-
# discovery announcement gap (tech_achieved, same un-decompiled-code class
# of problem, no fix attempted yet).
printf 'minimal_popups=1\r\n' >> "$INI_PATH"
if [ -n "$RNG_SEED" ]; then
    printf 'fixed_rng_seed=%s\r\n' "$RNG_SEED" >> "$INI_PATH"
fi
if [ "$LUA_SHADOW" = "1" ]; then
    sed -i -e 's/^lua_shadow=.*/lua_shadow=1\r/' "$INI_PATH"
fi
if [ "$GOLDEN_TRACE" = "1" ]; then
    printf 'golden_trace=1\r\n' >> "$INI_PATH"
fi

# --- Clean stale logs from any prior session -----------------------------
# lua.log/autoplay.log are opened in append mode; without this a stale log
# from a previous manual session would make the very first poll below see
# an already-advanced turn number and mis-time the stall window.
# golden_traces.jsonl is deliberately NOT included here -- see --golden-trace
# above, it's meant to accumulate across runs, not reset per run.
rm -f "$GAME_DIR/lua.log" "$GAME_DIR/autoplay.log" "$GAME_DIR/debug.txt"

# --- Launch -------------------------------------------------------------
# setsid: gives the whole xvfb-run/Xvfb/wine tree (or, in --no-xvfb mode,
# just wine) its own process group so `kill -TERM -$RUN_PID` (finish(),
# below) can take all of it down without touching this script or its
# caller.
#
# cwd MUST be $GAME_DIR before exec'ing wine: thinker.exe's own launcher
# (src/launch.cpp) checks for "terranx.exe" as a path relative to its
# process's current directory, not relative to its own .exe location (that
# convenience is Explorer's doing on real Windows, not the process's).
# Launching `wine /abs/path/thinker.exe` from an unrelated cwd -- which an
# earlier version of this script did -- makes that check fail, and the
# game answers with a plain Win32 MessageBox ("Cannot find terranx.exe"),
# which is NOT one of the six autoplay-bypassed dialogs (src/autoplay.cpp)
# and so blocks forever even with autoplay=1. Confirmed by screenshot
# while building this fix -- a prior smoke test's STALL was almost
# certainly this dialog, not the New Game menu. `(cd ... && exec setsid
# ...)` in a subshell keeps the cwd fix local to the launched tree without
# perturbing this script's own cwd, and `exec` means `$!` after
# backgrounding the subshell still names the (now setsid-image) process
# directly, so the kill logic below is unaffected.
WINE_ARGS=(wine "$GAME_DIR/thinker.exe" -windowed)
if [ -n "$SAVE_FILE" ]; then
    WINE_ARGS+=("$SAVE_FILE") # unverified, see KNOWN GAP above
fi

# SCREENSHOT_DISPLAY: full ":N" form, used by take_screenshot() below
# regardless of mode. Xvfb mode discovers it (the display it just
# allocated); --no-xvfb mode takes whatever DISPLAY this script itself
# inherited (e.g. an XWayland instance backing the real desktop) -- it is
# NOT allocated or overridden for you in that mode.
SCREENSHOT_DISPLAY=""
if [ "$USE_XVFB" = "1" ]; then
    # `env` (not the shell) parses the leading VAR=val pairs here -- that
    # only works via the shell's own syntax for a literal command line,
    # not when the words come from an array, hence going through env
    # explicitly for both -u WAYLAND_DISPLAY and WINEPREFIX.
    #
    # -u WAYLAND_DISPLAY: this dev machine is Wayland-only: forces Wine's
    # x11 driver onto the Xvfb display instead of the native Wayland
    # driver, which would otherwise leak the window onto the real desktop.
    before_locks="$(ls /tmp/.X*-lock 2>/dev/null | tr '\n' ' ')"
    ( cd "$GAME_DIR" && exec setsid xvfb-run -a env -u WAYLAND_DISPLAY WINEPREFIX="$WINEPREFIX_DIR" "${WINE_ARGS[@]}" ) \
        >"$RUN_DIR/launch.out" 2>&1 &
    RUN_PID=$!
    echo "launched under Xvfb (process group $RUN_PID), waiting for the display to come up..."

    for _ in $(seq 1 50); do
        for f in /tmp/.X*-lock; do
            [ -e "$f" ] || continue
            case " $before_locks " in
                *" $f "*) continue ;;
            esac
            SCREENSHOT_DISPLAY=":$(basename "$f" | sed -e 's/^\.X//' -e 's/-lock$//')"
        done
        [ -n "$SCREENSHOT_DISPLAY" ] && break
        kill -0 "$RUN_PID" 2>/dev/null || break # died before Xvfb even started
        sleep 0.2
    done
    if [ -n "$SCREENSHOT_DISPLAY" ]; then
        echo "virtual display: $SCREENSHOT_DISPLAY"
    else
        echo "warn: could not determine the allocated virtual display; screenshots will be skipped" >&2
    fi
else
    # Real/current display: no Xvfb, no WAYLAND_DISPLAY override -- wine
    # picks whatever driver is native here, same as the CLAUDE.md manual
    # launch command.
    ( cd "$GAME_DIR" && exec setsid env WINEPREFIX="$WINEPREFIX_DIR" "${WINE_ARGS[@]}" ) \
        >"$RUN_DIR/launch.out" 2>&1 &
    RUN_PID=$!
    echo "launched on the current display (process group $RUN_PID)"
    if [ -n "${DISPLAY:-}" ]; then
        SCREENSHOT_DISPLAY="$DISPLAY"
        echo "screenshots will use inherited DISPLAY=$SCREENSHOT_DISPLAY"
    else
        echo "warn: no DISPLAY in this script's environment; screenshots will be skipped" >&2
    fi
fi

take_screenshot() {
    local out="$1"
    if [ -z "$SCREENSHOT_DISPLAY" ]; then
        return 1
    fi
    if command -v xwd >/dev/null 2>&1 && command -v convert >/dev/null 2>&1; then
        xwd -root -display "$SCREENSHOT_DISPLAY" -out "$out.xwd" 2>/dev/null \
            && convert "$out.xwd" "$out" 2>/dev/null && rm -f "$out.xwd"
    elif command -v import >/dev/null 2>&1; then
        DISPLAY="$SCREENSHOT_DISPLAY" import -window root "$out" 2>/dev/null
    else
        echo "warn: no screenshot tool available (need xwd+convert, or ImageMagick's import)" >&2
        return 1
    fi
}

# --- Watchdog ---------------------------------------------------------
# game_alive: NOT just `kill -0 $RUN_PID`. thinker.exe (src/launch.cpp) is
# a launcher stub -- CreateProcess(terranx.exe, CREATE_SUSPENDED), inject
# the DLL, resume, then **exit itself by design**. $RUN_PID (the
# setsid-image of that launcher) therefore disappears on every successful
# run, not just crashed ones -- confirmed live this session: `terranx.exe`
# kept running and responding to input for several minutes after $RUN_PID
# had already gone away and this script (in an earlier version) had
# already declared CRASH and exited. A real crash/exit needs BOTH the
# original process gone AND no terranx.exe process found.
game_alive() {
    kill -0 "$RUN_PID" 2>/dev/null && return 0
    pgrep -x terranx.exe >/dev/null 2>&1 && return 0
    return 1
}

LUA_LOG="$GAME_DIR/lua.log"
LAST_TURN=""
LAST_PROGRESS="$(date +%s)"
LAST_SCREENSHOT=0
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

    # Periodic "still waiting" screenshot, independent of --timeout (fires
    # even with --timeout 0): lets you review afterward what the screen
    # looked like every time it sat idle for a while, without killing the
    # run over it -- useful for a human-driven session (New Game screen,
    # a dialog outside the autoplay funnel, ...).
    if [ "$SCREENSHOT_INTERVAL" -gt 0 ] 2>/dev/null \
       && [ $((NOW - LAST_PROGRESS)) -ge "$SCREENSHOT_INTERVAL" ] \
       && [ $((NOW - LAST_SCREENSHOT)) -ge "$SCREENSHOT_INTERVAL" ]; then
        shot="$RUN_DIR/waiting_turn${LAST_TURN:-none}_$(date -u +%H%M%SZ).png"
        if take_screenshot "$shot"; then
            echo "$(date -u +%FT%TZ) still waiting (turn ${LAST_TURN:-none}) -- screenshot: $shot"
        fi
        LAST_SCREENSHOT="$NOW"
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
if [ "$OUTCOME" = "STALL" ]; then
    take_screenshot "$RUN_DIR/stall.png" \
        && echo "stall screenshot: $RUN_DIR/stall.png" \
        || echo "warn: stall screenshot capture failed or unavailable" >&2
fi

# The process-group kill covers everything descended from $RUN_PID, but
# per game_alive()'s comment above, terranx.exe is very often NOT a
# descendant of $RUN_PID by the time we get here (the launcher that
# spawned it already exited on its own) -- kill it by name explicitly too,
# then wineserver -k as a final sweep for anything left in this prefix
# (winedevice.exe helpers, etc.). Scope caveat, acceptable for this
# single-user dev tool: pkill -x terranx.exe is not scoped to just this
# run's process tree, so a second concurrent run/manual session would
# collide -- don't run two of these against the same WINEPREFIX at once.
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

[ -f "$LUA_LOG" ] && cp "$LUA_LOG" "$RUN_DIR/lua.log"
[ -f "$GAME_DIR/autoplay.log" ] && cp "$GAME_DIR/autoplay.log" "$RUN_DIR/autoplay.log"
[ -f "$GAME_DIR/debug.txt" ] && cp "$GAME_DIR/debug.txt" "$RUN_DIR/debug.txt"
# golden_traces.jsonl accumulates in $GAME_DIR across runs (never cleared,
# see --golden-trace above) -- this is a snapshot copy of the corpus as it
# stood at the end of *this* run, not a per-run-only file.
[ -f "$GAME_DIR/golden_traces.jsonl" ] && cp "$GAME_DIR/golden_traces.jsonl" "$RUN_DIR/golden_traces.jsonl"
[ -d "$GAME_DIR/saves" ] && cp -r "$GAME_DIR/saves" "$RUN_DIR/saves"
if [ -f "$RUN_DIR/lua.log" ]; then
    grep 'state_hash turn=' "$RUN_DIR/lua.log" > "$RUN_DIR/state_hashes.log" || true
fi

{
    echo "preset: $PRESET"
    echo "target_turns: $TARGET_TURNS"
    echo "timeout_seconds: $TIMEOUT_SECONDS"
    echo "screenshot_interval_seconds: $SCREENSHOT_INTERVAL"
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
