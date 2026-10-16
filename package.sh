#!/bin/bash
# Makes the file to share: dist/Aula-Lights-<version>.dmg, a universal app (Apple silicon
# and Intel) with an Applications shortcut and a short "Read Me First" note.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
mkdir -p dist
VERSION="$VERSION" ARCHS="arm64 x86_64" INSTALL=0 OUT=dist ./build.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R dist/AulaLights.app "$STAGE/Aula Lights.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me First.txt" <<'TXT'
AULA LIGHTS: make your AULA F75 work like a real Mac keyboard

1. Drag "Aula Lights" onto the Applications folder.

2. Open Aula Lights from Applications. Your Mac will say it can't check the app,
   because it isn't from the App Store. Click Done.

3. Open System Settings > Privacy & Security, scroll down, and click "Open Anyway"
   next to Aula Lights. You only do this once.

4. The app then shows three quick steps:
   - Connect the keyboard (USB-C cable or the 2.4 GHz wireless receiver).
   - Allow keyboard access when your Mac asks.
   - Choose "Mac" so Alt works as Command and Win works as Option.

To go back to the original keys, click "Windows" at the top right of the app.

Free. Not made by or affiliated with AULA.
TXT

DMG="dist/Aula-Lights-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Aula Lights" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf dist/AulaLights.app
echo "Made $DMG"
