#!/bin/sh
# Deploy Thinker build artifacts to the Alpha Centauri game folder (Wine).
#
# Usage: tools/deploy.sh [develop|debug|release] [game_dir]
#
# Defaults: develop build, game dir from $SMAC_DIR or the wine-smac prefix.
set -e

CONFIG="${1:-develop}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAME_DIR="${2:-${SMAC_DIR:-$HOME/.wine-smac/drive_c/Games/SMAC}}"
BUILD_DIR="$ROOT/build/$CONFIG"
MINGW_BIN=/usr/i686-w64-mingw32/bin

if [ ! -f "$GAME_DIR/terranx.exe" ]; then
    echo "error: terranx.exe not found in $GAME_DIR" >&2
    exit 1
fi
if [ ! -f "$BUILD_DIR/thinker.dll" ]; then
    echo "error: no build found in $BUILD_DIR (run cmake --build --preset ninja-$CONFIG)" >&2
    exit 1
fi

cp -v "$BUILD_DIR/thinker.dll" "$BUILD_DIR/thinker.exe" "$GAME_DIR/"

# Dialog definitions required by all Thinker menus (Alt+T etc.)
cp -v "$ROOT/docs/modmenu.txt" "$GAME_DIR/"
# Base name lists used by the new_base_names option
mkdir -p "$GAME_DIR/basenames"
cp "$ROOT/docs/basenames/"*.txt "$GAME_DIR/basenames/"

# Lua runtime scripts (replace wholesale so stale files never linger)
rm -rf "$GAME_DIR/lua"
cp -rv "$ROOT/lua" "$GAME_DIR/lua"

# Install default config only if none exists yet (do not clobber user settings)
if [ ! -f "$GAME_DIR/thinker.ini" ]; then
    cp -v "$ROOT/docs/thinker.ini" "$GAME_DIR/"
fi

# Note: docs/alphax.txt (optional rule changes) and docs/smac_mod are NOT
# deployed on purpose; install those manually if wanted.

# Debug builds are not statically linked: they need the mingw runtime DLLs
if [ "$CONFIG" = "debug" ]; then
    for dll in libgcc_s_dw2-1.dll libstdc++-6.dll libwinpthread-1.dll; do
        cp -v "$MINGW_BIN/$dll" "$GAME_DIR/"
    done
fi

echo "deployed $CONFIG build to $GAME_DIR"
