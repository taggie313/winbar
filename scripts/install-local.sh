#!/bin/bash
# Development convenience: build, install to ~/Applications/Winbar.app, and relaunch.
#
#   scripts/install-local.sh
#
# Honours WINBAR_SIGN_IDENTITY like build-app.sh. Sign with a Developer ID if you can: an ad-hoc
# build resets Winbar's Accessibility grant every time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh"

DEST="$HOME/Applications/Winbar.app"

# Quit the menu bar app, but not a `winbar setup` or `doctor` that happens to be running: the same
# binary serves both, and only the menu bar app runs with no arguments.
for pid in $(pgrep -x Winbar || true); do
  if [ -z "$(ps -o args= -p "$pid" | awk '{ $1 = ""; print }' | tr -d '[:space:]')" ]; then
    kill "$pid" 2>/dev/null || true
  fi
done
sleep 1

mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$ROOT/dist/Winbar.app" "$DEST"
open "$DEST"
echo "installed $DEST"
