#!/usr/bin/env bash
# Builds MusicNotch.app into ./build.
#   scripts/build.sh            release build
#   scripts/build.sh --run      build, then (re)launch it
#   scripts/build.sh --install  build, copy to /Applications, then launch it
#
# Calls swiftc directly instead of `swift build`: some Command Line Tools installs
# ship a broken package-manifest library, and this app has no dependencies anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MusicNotch.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O -wmo -swift-version 6 \
  -target "$(uname -m)-apple-macos15.0" -sdk "$SDK" \
  -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -module-name MusicNotch \
  $(find Sources/MusicNotch -name '*.swift') \
  -o "$APP/Contents/MacOS/MusicNotch"

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

# A stable signing identity keeps macOS permissions (Automation, Keychain) across rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [[ -z "$IDENTITY" ]]; then IDENTITY="-"; fi
codesign --force --sign "$IDENTITY" --entitlements Resources/MusicNotch.entitlements "$APP"
echo "Built $APP (signed with: $IDENTITY)"

case "${1:-}" in
  --run)
    pkill -x MusicNotch 2>/dev/null || true
    open "$APP" --args "${@:2}"
    ;;
  --install)
    pkill -x MusicNotch 2>/dev/null || true
    rm -rf /Applications/MusicNotch.app
    cp -R "$APP" /Applications/
    open /Applications/MusicNotch.app
    echo "Installed to /Applications/MusicNotch.app"
    ;;
esac
