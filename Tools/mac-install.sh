#!/bin/zsh
# Builds the Mac app (Debug, like the iPhone OTA builds) and installs it as ~/Applications/OpenChat.app: quits the
# running copy, swaps the bundle, and opens the new one. The app's data lives in its container, so it survives.
#
#   Tools/mac-install.sh
set -euo pipefail

REPO=${0:A:h:h}
DD=${STRATA_MAC_DD:-$REPO/build-mac}
DEST=$HOME/Applications/OpenChat.app
OLD=$HOME/Applications/Strata.app  # the name before 2026-10-21
BUNDLE=cc.coolservices.strata.mac

LOG=$(mktemp -t strata-mac-build)
# A failed build must not install the previous build's app, which is still in the derived data.
if ! xcodebuild -project "$REPO/Strata.xcodeproj" -scheme StrataMac -configuration Debug -derivedDataPath "$DD" build >"$LOG" 2>&1; then
  grep -a "error: " "$LOG" | head -20 >&2
  echo "build failed (log: $LOG)" >&2
  exit 1
fi
rm -f "$LOG"
APP="$DD/Build/Products/Debug/OpenChat.app"

if pgrep -f "($DEST|$OLD)/Contents/MacOS" >/dev/null; then
  osascript -e "tell application id \"$BUNDLE\" to quit" || true
  for _ in {1..20}; do pgrep -f "($DEST|$OLD)/Contents/MacOS" >/dev/null || break; sleep 0.25; done
fi
rm -rf "$OLD"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
open "$DEST"
echo "installed $DEST ($(git -C "$REPO" log -1 --format=%h))"
