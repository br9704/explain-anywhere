#!/bin/zsh
# Builds the Explain Anywhere app bundle at the given path with swiftc.
# Used by install.sh and for release builds:
#   scripts/build-app.sh "build/Explain Anywhere.app"
#   SIGN_ID="Apple Development: Your Name (XXXXXXXXXX)" scripts/build-app.sh "<path>"
# Without SIGN_ID the bundle is ad-hoc signed.
set -e
if [[ -z "$1" ]]; then echo "Usage: scripts/build-app.sh <path/to/Explain Anywhere.app>"; exit 1; fi
case "$1" in /*) APP="$1" ;; *) APP="$PWD/$1" ;; esac
VERSION="0.1.0"
cd "$(dirname "$0")/.."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.explain-anywhere</string>
  <key>CFBundleName</key><string>Explain Anywhere</string>
  <key>CFBundleExecutable</key><string>Explain</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/Explain" -framework Cocoa -framework WebKit
codesign --force --sign "${SIGN_ID:--}" "$APP"
