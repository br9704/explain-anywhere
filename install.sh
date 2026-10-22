#!/bin/zsh
# Explain Anywhere installer: builds the app with swiftc, installs the Quick Action
# and binds Control+Shift+I. No Xcode project and no third-party code.
#   ./install.sh                 ad-hoc signed build
#   SIGN_ID="Apple Development: Your Name (XXXXXXXXXX)" ./install.sh
#                                signed with your certificate, so macOS remembers
#                                folder permissions across rebuilds
set -e
cd "$(dirname "$0")"

autoload -Uz is-at-least
if ! is-at-least 13.0 "$(sw_vers -productVersion)"; then echo "Needs macOS 13 or later."; exit 1; fi
if ! xcrun --find swiftc >/dev/null 2>&1; then echo "Needs the Swift compiler: run xcode-select --install"; exit 1; fi
CLAUDE=""
for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do [[ -x "$c" ]] && CLAUDE="$c" && break; done
[[ -z "$CLAUDE" ]] && echo "Note: the Claude Code CLI was not found. Install it and run 'claude' once to log in."

APP="$HOME/Applications/Explain Anywhere.app"
echo "Building $APP"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.explain-anywhere</string>
  <key>CFBundleName</key><string>Explain Anywhere</string>
  <key>CFBundleExecutable</key><string>Explain</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xcrun swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/Explain" -framework Cocoa -framework WebKit
codesign --force --sign "${SIGN_ID:--}" "$APP"

echo "Installing the launcher and the Quick Action"
mkdir -p "$HOME/.local/bin" "$HOME/Library/Services"
install -m 755 scripts/explain-anywhere "$HOME/.local/bin/explain-anywhere"
rm -rf "$HOME/Library/Services/Explain with Claude.workflow"
cp -R "QuickAction/Explain with Claude.workflow" "$HOME/Library/Services/"

CONF="$HOME/.config/explain-anywhere/config.json"
if [[ ! -f "$CONF" ]]; then
  mkdir -p "${CONF:h}"
  cp config.example.json "$CONF"
  echo "Wrote default settings to $CONF"
fi

echo "Binding Control+Shift+I"
defaults write pbs NSServicesStatus -dict-add '"(null) - Explain with Claude - runWorkflowAsService"' \
  '{ "enabled_context_menu" = 1; "enabled_services_menu" = 1; "key_equivalent" = "^$i"; "presentation_modes" = { ContextMenu = 1; ServicesMenu = 1; }; }'
/System/Library/CoreServices/pbs -update || true

echo "Done. Select text in any app and press Control+Shift+I, or right-click > Services > Explain with Claude."
echo "If the shortcut does nothing, tick it in System Settings > Keyboard > Keyboard Shortcuts > Services > Text."
