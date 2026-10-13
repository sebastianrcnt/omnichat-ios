#!/bin/zsh
# Runs the app's page extractor on real pages on this Mac and saves what the model would receive.
#
#   tools/extract-check.sh                     # every URL in tools/extract-check/sites.txt
#   tools/extract-check.sh <url> [<url>...]    # just these
#   OUT=/some/dir SETTLE=3 tools/extract-check.sh ...
#
# Prints one line per page (method, Readability's length, final length) and writes the full text of each page to
# $OUT/NN.txt (default: a new folder under $TMPDIR). Uses the extractor files in this checkout, so edits to
# Extractor.js show up on the next run without building the app.
set -e
ROOT=${0:A:h:h}
HERE=$ROOT/tools/extract-check
BIN=${TMPDIR:-/tmp}/strata-extract-check
OUT=${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/extract-XXXX")}
if [[ ! -x $BIN || $HERE/main.swift -nt $BIN ]]; then
  swiftc -O $HERE/main.swift -o $BIN 2>&1 | grep -v warning || true
fi
if (( $# )); then urls=("$@"); else urls=(${(f)"$(grep -v '^#' $HERE/sites.txt | grep -v '^$')"}); fi
$BIN $ROOT/Strata/Resources/Readability/Readability.js ${EXTRACTOR:-$ROOT/Strata/Resources/Readability/Extractor.js} $OUT $urls
echo "full text: $OUT"
