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
AULA LIGHTS for the AULA F75 keyboard

1. Drag "Aula Lights" onto the Applications folder.

2. Open it. The first time, macOS will say it can't check the app, because it isn't
   from the App Store. Click Done, then open System Settings > Privacy & Security,
   scroll down, and click "Open Anyway" next to Aula Lights. You only do this once.

3. A short setup screen asks you to connect the keyboard (USB-C cable or 2.4 GHz
   receiver) and to allow Input Monitoring. The keyboard's lighting controls share a
   connection with its keys, so macOS asks for this. Key presses are only used to draw
   the lights; nothing is saved or sent anywhere.

Optional: "Mac" in the top bar makes Alt act as Command and Win as Option, and the dial
icon turns the knob into an on-screen dial. Both install a small background helper the
first time you switch them on.

Lighting changes need the USB-C cable or the 2.4 GHz receiver; over Bluetooth the
keyboard doesn't share enough of its settings to change them safely.

Unofficial; not affiliated with AULA. Use at your own risk.
TXT

DMG="dist/Aula-Lights-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Aula Lights" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf dist/AulaLights.app
echo "Made $DMG"
