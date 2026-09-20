#!/bin/bash
# Builds dist/Winbar.app from source and signs it.
#
#   scripts/build-app.sh
#
# Environment:
#   WINBAR_SIGN_IDENTITY  codesigning identity (name or SHA-1), or "-" for ad-hoc.
#                         Default: the first "Developer ID Application" identity in the keychain,
#                         else ad-hoc with a warning.
#
# Signs for local use (no secure timestamp). scripts/release.sh re-signs with a timestamp for
# notarization.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The VERSION file is the single source of truth: stamped into Info.plist here, and read back from
# Info.plist by `winbar --version` at run time.
VERSION="$(tr -d '[:space:]' <VERSION)"
[ -n "$VERSION" ] || { echo "VERSION is empty" >&2; exit 1; }

# arm64 only: the VMs Winbar manages are Windows on Apple silicon, which an Intel Mac can't run.
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Winbar"

APP="$ROOT/dist/Winbar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Winbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
printf 'APPL????' >"$APP/Contents/PkgInfo"

# A real identity matters for more than distribution: macOS keys privacy grants (Accessibility,
# Automation, Local Network) to the signature's designated requirement. Ad-hoc signatures change on
# every build and silently invalidate those grants; a Developer ID requirement is bundle id + team,
# so grants survive rebuilds. `${VAR+set}` so that an explicit "-" is honoured.
if [ "${WINBAR_SIGN_IDENTITY+set}" = set ]; then
  IDENTITY="$WINBAR_SIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
  if [ -z "$IDENTITY" ]; then
    echo "warning: no Developer ID Application identity found; signing ad-hoc." >&2
    echo "         Privacy grants (Accessibility etc.) will reset on every rebuild." >&2
    IDENTITY="-"
  fi
fi

if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
else
  # Hardened runtime needs the apple-events entitlement for Winbar's utmctl/osascript children to
  # reach UTM.
  codesign --force --options runtime --timestamp=none \
    --entitlements Resources/Winbar.entitlements --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

echo "built $APP ($VERSION, signed: $([ "$IDENTITY" = "-" ] && echo ad-hoc || echo "$IDENTITY"))"
