#!/bin/bash
# Run the pure unit tier without letting AppKit pumping end SeatSession's async main.
set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "usage: unit-test-command.sh <swift command...>" >&2
    exit 2
fi

# Keeping the other targets in SwiftPM preserves their XCTest execution as well
# as their Swift Testing suites. Filtered-out and empty Swift Testing bundles
# produce no summary, so the enclosing tier requires 25 here and one below.
"$@" test --no-parallel --skip '^SeatSessionTests[./]'
mecum_unit_bin_dir=$("$@" build --show-bin-path)
exec .build/native-driver-test-main \
    "$mecum_unit_bin_dir/SeatSessionTests.xctest/Contents/MacOS/SeatSessionTests" \
    --no-parallel
