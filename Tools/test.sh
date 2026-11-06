#!/bin/zsh
# The full unit suite in two passes on one simulator: everything else in parallel, then the suites listed in
# Tools/serial-test-suites.txt one test at a time. Exits non-zero if either pass failed; a failed test is retried once.
#
#   Tools/test.sh [log]        default log: build-sim/test.log
set -uo pipefail

REPO=${0:A:h:h}
SIM=${STRATA_SIM:-E2BD5F08-3E78-42BF-A837-84219B893F05}
LOG=${1:-$REPO/build-sim/test.log}
cd "$REPO"

suites=(${(f)"$(grep -v '^#' Tools/serial-test-suites.txt)"})
common=(-project Strata.xcodeproj -scheme Strata -destination "id=$SIM" -collect-test-diagnostics never
        -derivedDataPath build-sim -retry-tests-on-failure -test-iterations 2)

mkdir -p "${LOG:h}"
: >"$LOG"
xcodebuild test "${common[@]}" -parallel-testing-enabled YES -parallel-testing-worker-count 1 \
  "${suites[@]/#/-skip-testing:StrataTests/}" >>"$LOG" 2>&1
PARALLEL=$?
xcodebuild test-without-building "${common[@]}" "${suites[@]/#/-only-testing:StrataTests/}" >>"$LOG" 2>&1
SERIAL=$?
(( PARALLEL == 0 && SERIAL == 0 ))
