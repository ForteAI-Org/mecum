#!/bin/bash

set -euo pipefail

root=$(cd "$(dirname "$0")/../../.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/agentseat-bench-contract.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

xcrun swiftc \
    -module-cache-path "$scratch/module-cache" \
    "$root/Tools/Driver/SeatBench/IdentityAllocationAssessment.swift" \
    "$root/Tools/Driver/SeatBenchTests/IdentityAllocationAssessmentTests.swift" \
    -o "$scratch/identity-allocation-assessment-tests"

"$scratch/identity-allocation-assessment-tests"
