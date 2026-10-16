#!/bin/bash
# Stops aula-remap, removes it, and restores the keyboard's original Alt/Win keys.
set -uo pipefail
LABEL="com.aulalights.remap"
DEST="$HOME/Library/Application Support/aula-remap"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
[ -x "$DEST/aula-remap" ] && "$DEST/aula-remap" --reset
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$DEST"
echo "Uninstalled. Alt and Win are back to normal."
