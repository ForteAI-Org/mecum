#!/bin/bash
#
#  run-tier.sh
#  AgentSeatKit
#
#  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
#
# Runs one test tier and refuses to believe its exit status on its own.
#
# A live HID tap plus repeated virtual display creation ends the process with
# exit code 0 and no summary line at all (docs/spi-ledger.md), so a green exit
# proves nothing about whether the tier finished. What is trustworthy is the
# summary the runner printed and the reported, executed and skipped counts, which is why every
# tier here declares how many tests it must report.
#
# Usage: run-tier.sh <label> <expected-tests|-> <command...>
#        `-` means "no count declared": exit status plus at least one summary.

set -uo pipefail

if [ "$#" -lt 3 ]; then
    echo "usage: run-tier.sh <label> <expected-tests|-> <command...>" >&2
    exit 2
fi

label=$1
expected=$2
shift 2

log="${TMPDIR:-/tmp}/agentseat-tier-${label}.log"

printf '\n== %s\n' "$label"
"$@" 2>&1 | tee "$log"
pipeline_status=("${PIPESTATUS[@]}")
status=${pipeline_status[0]}
if [ "${pipeline_status[1]}" -ne 0 ]; then
    echo "FAIL $label: the transcript could not be written" >&2
    exit 1
fi

# Keep the validated result in the same log the compatibility report reads.
python3 "$(dirname "$0")/tier-result.py" "$label" "$expected" "$status" "$log" | tee -a "$log"
exit "${PIPESTATUS[0]}"
