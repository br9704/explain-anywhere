#!/bin/zsh
# Explain Anywhere installer: builds the app with swiftc, installs the Quick Action
# and binds Control+Shift+I. No Xcode project and no third-party code.
#   ./install.sh                 ad-hoc signed build
#   SIGN_ID="Apple Development: Your Name (XXXXXXXXXX)" ./install.sh
#                                signed with your certificate, so macOS remembers
#                                folder permissions across rebuilds
# In a release download (no Sources folder, a prebuilt app next to this script)
# it copies that app instead of building, and clears its quarantine flag.
set -e
cd "$(dirname "$0")"

autoload -Uz is-at-least
if ! is-at-least 13.0 "$(sw_vers -productVersion)"; then echo "Needs macOS 13 or later."; exit 1; fi
PREBUILT=""
[[ ! -f Sources/main.swift && -d "Explain Anywhere.app" ]] && PREBUILT="Explain Anywhere.app"
if [[ -z "$PREBUILT" ]] && ! xcrun --find swiftc >/dev/null 2>&1; then echo "Needs the Swift compiler: run xcode-select --install"; exit 1; fi
CLAUDE=""
for c in "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do [[ -x "$c" ]] && CLAUDE="$c" && break; done
[[ -z "$CLAUDE" ]] && echo "Note: the Claude Code CLI was not found. Install it and run 'claude' once to log in."

APP="$HOME/Applications/Explain Anywhere.app"
if [[ -n "$PREBUILT" ]]; then
  echo "Copying the prebuilt, unsigned app to $APP"
  rm -rf "$APP"; mkdir -p "$(dirname "$APP")"
  ditto "$PREBUILT" "$APP"
  # The release app is ad-hoc signed and not notarized. Without this, Gatekeeper
  # silently blocks it when the Quick Action opens it in the background.
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
else
  echo "Building $APP"
  scripts/build-app.sh "$APP"
fi

echo "Installing the launcher and the Quick Action"
mkdir -p "$HOME/.local/bin" "$HOME/Library/Services"
install -m 755 scripts/explain-anywhere "$HOME/.local/bin/explain-anywhere"
rm -rf "$HOME/Library/Services/Explain with Claude.workflow"
cp -R "QuickAction/Explain with Claude.workflow" "$HOME/Library/Services/"

CONF="$HOME/.config/explain-anywhere/config.json"
if [[ ! -f "$CONF" ]]; then
  mkdir -p "$(dirname "$CONF")"
  cp config.example.json "$CONF"
  echo "Wrote default settings to $CONF"
fi

echo "Binding Control+Shift+I"
# shellcheck disable=SC2016  # "^$i" is the literal key equivalent Control+Shift+I, not a variable
defaults write pbs NSServicesStatus -dict-add '"(null) - Explain with Claude - runWorkflowAsService"' \
  '{ "enabled_context_menu" = 1; "enabled_services_menu" = 1; "key_equivalent" = "^$i"; "presentation_modes" = { ContextMenu = 1; ServicesMenu = 1; }; }'
/System/Library/CoreServices/pbs -update || true

echo "Done. Select text in any app and press Control+Shift+I, or right-click > Services > Explain with Claude."
echo "If the shortcut does nothing, tick it in System Settings > Keyboard > Keyboard Shortcuts > Services > Text."
