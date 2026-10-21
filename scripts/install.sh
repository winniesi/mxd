#!/bin/zsh
# Build mxd, bundle it as ~/Applications/mxd.app and run it via a LaunchAgent.
set -euo pipefail
cd "${0:A:h}/.."

APP="$HOME/Applications/mxd.app"
LABEL="com.winniesi.mxd"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
CONF="$HOME/.config/mxd/config.json"

swift build -c release

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true

mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/release/mxd "$APP/Contents/MacOS/mxd"
codesign --force -s - --identifier "$LABEL" "$APP"

if [[ ! -f "$CONF" ]]; then
  mkdir -p "${CONF:h}"
  cp config.example.json "$CONF"
  echo "wrote default config to $CONF"
fi

mkdir -p "${AGENT:h}"
sed "s|__APP__|$APP|" Resources/$LABEL.plist > "$AGENT"
launchctl bootstrap "gui/$UID" "$AGENT"

echo "installed. If buttons don't work, enable mxd in System Settings → Privacy & Security →"
echo "Accessibility and Input Monitoring (re-check after every rebuild: the ad-hoc signature changes),"
echo "then run: launchctl kickstart -k gui/$UID/$LABEL"
echo "logs: log stream --predicate 'subsystem == \"$LABEL\"'"
