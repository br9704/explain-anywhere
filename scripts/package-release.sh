#!/bin/zsh
# Builds the release download: an ad-hoc signed (unsigned for Gatekeeper) app plus
# the installer, launcher, Quick Action and example settings, zipped.
#   scripts/package-release.sh            writes build/Explain-Anywhere-<version>-unsigned.zip
set -e
cd "$(dirname "$0")/.."
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' scripts/build-app.sh)"
NAME="Explain-Anywhere-$VERSION-unsigned"
OUT="build/release/$NAME"
rm -rf "build/release" && mkdir -p "$OUT/scripts" "$OUT/QuickAction"
SIGN_ID="-" scripts/build-app.sh "$OUT/Explain Anywhere.app"
cp install.sh uninstall.sh config.example.json LICENSE "$OUT/"
cp scripts/explain-anywhere "$OUT/scripts/"
cp -R "QuickAction/Explain with Claude.workflow" "$OUT/QuickAction/"
cat > "$OUT/README.txt" <<TXT
Explain Anywhere $VERSION (prebuilt, unsigned)

This app is ad-hoc signed and not notarized by Apple. To install it:

  cd $NAME
  ./install.sh

The installer copies the app to ~/Applications, removes its quarantine flag so
the Quick Action can open it, installs the Quick Action and binds Control+Shift+I.
Only do this if you trust this download. Otherwise build from source:
https://github.com/br9704/explain-anywhere#install

Needs macOS 13 or later and the Claude Code CLI, logged in (run claude once).
TXT
xattr -cr "$OUT"
(cd build/release && ditto -c -k --sequesterRsrc --keepParent "$NAME" "$NAME.zip")
shasum -a 256 "build/release/$NAME.zip"
