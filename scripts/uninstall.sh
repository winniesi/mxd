#!/bin/zsh
set -euo pipefail
LABEL="com.winniesi.mxd"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/mxd.app"
echo "removed (config left at ~/.config/mxd)"
