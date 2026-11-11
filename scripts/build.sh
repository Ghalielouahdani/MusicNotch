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

# Needs Swift 6.0+ and the macOS 15 SDK or newer: Xcode 16+, or its Command Line Tools.
SWIFT_VERSION="$(swiftc --version 2>&1 | grep -oE 'Swift version [0-9]+\.[0-9]+' | head -1 | awk '{ print $3 }')"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0)"
if [[ -z "$SWIFT_VERSION" || "${SWIFT_VERSION%%.*}" -lt 6 ]]; then
  echo "MusicNotch needs Swift 6.0 or newer (found: ${SWIFT_VERSION:-none})." >&2
  echo "Install Xcode 16 or later, or run: xcode-select --install" >&2
  exit 1
fi
if [[ "${SDK_VERSION%%.*}" -lt 15 ]]; then
  echo "MusicNotch needs the macOS 15 SDK or newer (found: $SDK_VERSION). Update Xcode or its Command Line Tools." >&2
  exit 1
fi

APP="build/MusicNotch.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling with Swift $SWIFT_VERSION, macOS $SDK_VERSION SDK…"
swiftc -O -wmo -swift-version 6 \
  -target "$(uname -m)-apple-macos15.0" -sdk "$SDK" \
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
