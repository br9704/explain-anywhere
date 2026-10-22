#!/bin/zsh
# Removes Explain Anywhere. Your settings and notes are kept unless you pass --all.
set -e
pkill -f "Explain Anywhere.app/Contents/MacOS/Explain" 2>/dev/null || true
rm -rf "$HOME/Applications/Explain Anywhere.app" "$HOME/Library/Services/Explain with Claude.workflow"
rm -f "$HOME/.local/bin/explain-anywhere"
rm -rf "$HOME/Library/Caches/explain-anywhere"
/usr/libexec/PlistBuddy -c 'Delete :NSServicesStatus:"(null) - Explain with Claude - runWorkflowAsService"' \
  "$HOME/Library/Preferences/pbs.plist" 2>/dev/null || true
/System/Library/CoreServices/pbs -update || true
defaults delete io.github.explain-anywhere 2>/dev/null || true
if [[ "$1" == "--all" ]]; then rm -rf "$HOME/.config/explain-anywhere"; echo "Settings removed."; fi
echo "Explain Anywhere removed. The log and saved notes were left where they are."
