#!/bin/bash
# Builds AulaLights.app.
#
#   ./build.sh                 build for this Mac and install to ~/Applications (development)
#   ARCHS="arm64 x86_64" INSTALL=0 OUT=dist ./build.sh
#                              universal build left in dist/ (what package.sh does)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
ARCHS="${ARCHS:-$(uname -m)}"
INSTALL="${INSTALL:-1}"
OUT="${OUT:-.}"
APP="$OUT/AulaLights.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"

# One binary per architecture, then joined into a universal one.
app_bins=(); np_archs=(); helper_bins=()
for arch in $ARCHS; do
  swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos14.0" *.swift -o "$TMP/AulaLights-$arch"
  swiftc -O -target "$arch-apple-macos14.0" remap/aula-remap.swift -o "$TMP/aula-remap-$arch"
  app_bins+=("$TMP/AulaLights-$arch"); helper_bins+=("$TMP/aula-remap-$arch"); np_archs+=(-arch "$arch")
done
lipo -create "${app_bins[@]}" -output "$APP/Contents/MacOS/AulaLights"
lipo -create "${helper_bins[@]}" -output "$APP/Contents/Resources/aula-remap"   # Mac layout + dial helper
clang -dynamiclib -fobjc-arc -O2 "${np_archs[@]}" -mmacosx-version-min=14.0 -framework Foundation \
  NowPlaying/NowPlaying.m -o "$APP/Contents/Resources/NowPlaying.dylib"
cp Fonts/*.ttf Fonts/OFL-*.txt "$APP/Contents/Resources/Fonts/"

# App icon, drawn by the app itself
"$APP/Contents/MacOS/AulaLights" make-icon "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Aula Lights</string>
  <key>CFBundleDisplayName</key><string>Aula Lights</string>
  <key>CFBundleIdentifier</key><string>com.aulalights.app</string>
  <key>CFBundleExecutable</key><string>AulaLights</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Unofficial app for the AULA F75. Not affiliated with AULA.</string>
  <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

# Sign with the local certificate when present (the identity stays the same across
# builds, so macOS keeps the Input Monitoring permission). Falls back to ad-hoc.
IDENTITY="AULA Lights Local Signing"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then SIGN="$IDENTITY"; else
  echo "Note: '$IDENTITY' certificate not found; ad-hoc signing (permission resets on each rebuild)."; SIGN="-"; fi
codesign --force --sign "$SIGN" "$APP/Contents/Resources/aula-remap" "$APP/Contents/Resources/NowPlaying.dylib"
codesign --force --sign "$SIGN" "$APP"

if [ "$INSTALL" = "1" ]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/AulaLights.app"
  cp -R "$APP" "$HOME/Applications/" && rm -rf "$APP"
  echo "Built and copied to ~/Applications/AulaLights.app"
else
  echo "Built $APP ($ARCHS)"
fi
