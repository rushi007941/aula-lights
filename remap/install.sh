#!/bin/bash
# Builds aula-remap and installs it as a LaunchAgent so it runs at every login.
set -euo pipefail
cd "$(dirname "$0")"

LABEL="com.aulalights.remap"
DEST="$HOME/Library/Application Support/aula-remap"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "Building..."
mkdir -p "$DEST"
swiftc -O aula-remap.swift -o "$DEST/aula-remap"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DEST/aula-remap</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DEST/aula-remap.log</string>
  <key>StandardErrorPath</key><string>$DEST/aula-remap.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Alt is now Command and Win is now Option on the AULA F75."
echo "Log: $DEST/aula-remap.log"
