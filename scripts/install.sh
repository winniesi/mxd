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
# Prefer a real signing identity: macOS ties Accessibility / Input Monitoring grants to it, so
# they survive rebuilds. Ad-hoc signatures change on every build and need re-granting.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/{print $2; exit}')
codesign --force -s "${IDENTITY:--}" --identifier "$LABEL" "$APP"
echo "signed with: ${IDENTITY:-ad-hoc}"

if [[ ! -f "$CONF" ]]; then
  mkdir -p "${CONF:h}"
  cp config.example.json "$CONF"
  echo "wrote default config to $CONF"
fi

mkdir -p "${AGENT:h}"
sed "s|__APP__|$APP|" Resources/$LABEL.plist > "$AGENT"
launchctl bootstrap "gui/$UID" "$AGENT"

echo "installed. If buttons don't work, enable mxd in System Settings → Privacy & Security →"
echo "Accessibility and Input Monitoring (with ad-hoc signing, re-check after every rebuild),"
echo "then run: launchctl kickstart -k gui/$UID/$LABEL"
echo "logs: log stream --predicate 'subsystem == \"$LABEL\"'"
