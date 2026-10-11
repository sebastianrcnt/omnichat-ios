#!/bin/bash
# Simulator smoke run against the local mock gateway.
#   Tools/smoke.sh <light|dark> <out.png> "<prompt>" [sheet] [wait-seconds]
# Requires: python3 Tools/mock_server.py running, the app built into ./build.
set -e
cd "$(dirname "$0")/.."
APPEARANCE=${1:-light}; OUT=${2:-/tmp/strata.png}; PROMPT=${3:-}; SHEET=${4:-}; WAIT=${5:-12}
APP=build/Build/Products/Debug-iphonesimulator/Strata.app
xcrun simctl terminate booted cc.coolservices.strata 2>/dev/null || true
xcrun simctl ui booted appearance "$APPEARANCE"
xcrun simctl install booted "$APP"
ARGS=(-StrataNoNotifications 1 -StrataMockBaseURL http://127.0.0.1:8765/v1 -StrataMockKey test-key -StrataFakeTools 1)
[ -n "$PROMPT" ] && ARGS+=(-StrataAutoSend "$PROMPT")
[ -n "$SHEET" ] && ARGS+=(-StrataOpenSheet "$SHEET")
[ -n "$BRANCH" ] && ARGS+=(-StrataDebugBranch "$BRANCH")
[ -n "$PICK_RECENT" ] && ARGS+=(-StrataAutoPickRecent 1)
[ -n "$FETCH_SECONDS" ] && ARGS+=(-StrataFakeFetchSeconds "$FETCH_SECONDS")
[ -n "$CONTEXT_WINDOW" ] && ARGS+=(-StrataContextWindow "$CONTEXT_WINDOW")
[ -n "$PREFERRED_LANG" ] && ARGS+=(-StrataPreferredLanguage "$PREFERRED_LANG")
[ -n "$FAKE_TRANSLATION" ] && ARGS+=(-StrataFakeTranslation 1 -StrataFakeTranslateSeconds "$FAKE_TRANSLATION")
[ -n "$TEXT_STEP" ] && ARGS+=(-useSystemTextSize NO -textSizeStep "$TEXT_STEP")
xcrun simctl launch booted cc.coolservices.strata "${ARGS[@]}" >/dev/null
sleep "$WAIT"
xcrun simctl io booted screenshot "$OUT" >/dev/null 2>&1
echo "wrote $OUT"
