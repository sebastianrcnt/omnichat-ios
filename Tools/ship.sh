#!/bin/zsh
# The usual round after a change: the full unit suite on the simulator (with the Mac app building alongside), then,
# only when it passed, the Mac install, the over-the-air page and a push of main. No TestFlight (Tools/testflight.sh).
#
#   Tools/ship.sh              test, then install + OTA + push
#   Tools/ship.sh --no-push    the same without the push
#
# A failed test is retried once within the same run (-retry-tests-on-failure), so a flaky one doesn't cost a second
# full run; the retries are listed at the end. Each step prints when it ended.
set -uo pipefail

REPO=${0:A:h:h}
SIM=${STRATA_SIM:-E2BD5F08-3E78-42BF-A837-84219B893F05}
LOG=${STRATA_TEST_LOG:-$REPO/build-sim/ship-test.log}
PUSH=1
[[ ${1:-} == --no-push ]] && PUSH=0
cd "$REPO"

START=$SECONDS
step() { printf '⏱ %-14s %3ds\n' "$1" $((SECONDS - START)); }

xcodegen generate -q
mkdir -p "${LOG:h}"
rm -f "$LOG"

# The Mac app builds while the suite runs (its own derived data); mac-install.sh then finds it up to date.
MACLOG=$(mktemp -t strata-mac-build)
xcodebuild build -project Strata.xcodeproj -scheme StrataMac -destination 'platform=macOS' -derivedDataPath build-mac \
  -allowProvisioningUpdates >"$MACLOG" 2>&1 &
MAC=$!

xcodebuild test -project Strata.xcodeproj -scheme Strata -destination "id=$SIM" -collect-test-diagnostics never \
  -derivedDataPath build-sim -retry-tests-on-failure -test-iterations 2 >"$LOG" 2>&1
step tests
wait $MAC
MACOK=$?
step mac-build
xcrun simctl shutdown "$SIM" 2>/dev/null

grep -aE "Test run with|TEST (SUCCEEDED|FAILED)" "$LOG" | tail -2
# Tests that failed at least once: on a run that still succeeded, these passed on the retry.
grep -aoE "Test [A-Za-z0-9_]+\(\)[^✔]* failed after" "$LOG" | sed -E 's/ recorded.*| failed after//' | sort -u | sed 's/^/retried: /'

if [[ ! -s $LOG ]] || ! grep -aq "TEST SUCCEEDED" "$LOG"; then
  echo "tests failed (log: $LOG)" >&2
  exit 1
fi
if (( MACOK != 0 )); then
  grep -a "error: " "$MACLOG" | head -20 >&2
  echo "Mac build failed (log: $MACLOG)" >&2
  exit 1
fi
rm -f "$MACLOG"

Tools/mac-install.sh || exit 1
step mac-install
Tools/ota.sh || exit 1
step ota
if (( PUSH )); then
  git push -q origin main || exit 1
  echo pushed
  step push
fi
