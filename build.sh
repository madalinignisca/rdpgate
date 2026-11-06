#!/usr/bin/env bash
# Build RDPGate.app - a menu-bar-only SwiftUI app (no Dock icon).
#
#   ./build.sh [debug|release] [version]      ARCH=arm64|x86_64 (default: this Mac)
#
# Local builds are ad-hoc signed and need no credentials. Release signing and
# notarization live in release.sh, which calls this script first.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=${1:-release}
VERSION=${2:-0.0.0}
ARCH=${ARCH:-$(uname -m)}
APP="RDPGate.app"

# Under a domain the author owns, not a hosting provider's: the bundle ID is
# the app's identity for as long as it exists, and moving the code elsewhere
# must not change it. The keychain service names (local.rdpgate,
# local.rdpgate.identity) deliberately do not follow it: they predate this ID,
# and renaming them would orphan every saved password.
BUNDLE_ID="me.madalin.rdpgate"

echo "==> swift build -c $CONFIG --arch $ARCH"
swift build -c "$CONFIG" --arch "$ARCH"

BIN=$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)/RDPGate
[ -x "$BIN" ] || { echo "build produced no binary at $BIN" >&2; exit 1; }

echo "==> assembling $APP ($VERSION, $ARCH)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RDPGate"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>RDPGate</string>
  <key>CFBundleDisplayName</key>       <string>RDPGate</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>        <string>RDPGate</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <!-- menu bar only: no Dock icon, no app switcher entry -->
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run on this Mac. No --deep: the bundle holds a
# single executable and nothing nested. release.sh re-signs with Developer ID.
echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP" >/dev/null 2>&1 || \
  echo "    (codesign failed; the app will still run locally)"

echo
echo "Built $(pwd)/$APP"
echo "Run it with:   open $APP"
