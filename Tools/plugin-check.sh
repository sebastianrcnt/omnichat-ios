#!/bin/zsh
# Runs one of the app's site plugins against the real site on this Mac and prints what the model would receive.
#
#   tools/plugin-check.sh <name> ['<args JSON>']
#   tools/plugin-check.sh wikipedia_summary '{"title":"Alan Turing"}'
#   LOAD=30 LIMIT=48000 PLUGINS=/some/dir tools/plugin-check.sh ...
#
# Uses the plugins and PluginCore.swift in this checkout, so edits to a plugin show up on the next run without
# building the app. Progress goes to stderr, the result to stdout. LOAD is the page timeout in seconds (default 15),
# SCRIPT the script limit (10), LIMIT the result length (24000).
set -e
ROOT=${0:A:h:h}
HERE=$ROOT/tools/plugin-check
CORE=$ROOT/Strata/Tools/PluginCore.swift
TEMPLATE=$ROOT/Packages/OpenChatPackageKit/Sources/OpenChatPackageKit/URLTemplate.swift
BIN=${TMPDIR:-/tmp}/strata-plugin-check
if [[ ! -x $BIN || $HERE/main.swift -nt $BIN || $CORE -nt $BIN || $TEMPLATE -nt $BIN ]]; then
  swiftc -O $CORE $TEMPLATE $HERE/main.swift -o $BIN 2>&1 | grep -v warning || true
fi
exec $BIN ${PLUGINS:-$ROOT/Strata/Resources/Plugins} "$@"
