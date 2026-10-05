#!/bin/bash
#
# Measures the living memory's SQLite store on temporary files: several real processes writing to
# one file, their write latencies, the waits contention cost them, one explicit checkpoint, and a
# lock held by one process beyond the others' budget. Prints hardware, OS, the linked SQLite and
# the configuration with every figure, because a figure without them is not a measurement.
#
# This is local cost, not a product claim: no provider, no app, no desktop.
#
# Usage: measure-memory-store.sh [processes] [writes-per-process] [payload-bytes] [hold-ms] [budget-ms]
#        Defaults: 3 processes, 200 writes each, 256 bytes, a 1500 ms hold, a 100 ms budget for the
#        held scenario. Needs `swift build --product memory-probe` (done here when missing).

set -euo pipefail

processes=${1:-3}
writes=${2:-200}
payload=${3:-256}
hold_ms=${4:-1500}
budget_ms=${5:-100}

root=$(cd "$(dirname "$0")/../../.." && pwd)
probe="$root/.build/debug/memory-probe"
if [ ! -x "$probe" ]; then
    (cd "$root" && swift build --product memory-probe >/dev/null)
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/mecum-measure.XXXXXX")
trap 'rm -rf "$work"' EXIT

echo "== environment"
echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "hardware: $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GiB"
echo "os: $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "filesystem: $(mount | grep ' on / ' | sed 's/.*(\([^,]*\).*/\1/')"
echo "linked: $(printf 'version\nexit\n' | "$probe")"
echo "probe: $probe (debug build)"
echo "configuration: lockBudget 2000 ms, retryPause 5 ms, maximumRetryPause 100 ms, synchronous FULL, WAL, wal_autocheckpoint 1000 (store defaults)"
echo "corpus: $processes processes x $writes writes of one memory_events row with a $payload-byte source_key, one file"
echo

echo "== A. concurrent writers, store defaults; process 1 checkpoints while the others are still open"
db="$work/a.sqlite"
for p in $(seq 1 "$processes"); do
    if [ "$p" -eq 1 ]; then
        ( printf 'open %s\nmeasure s%d %d %d\n' "$db" "$p" "$writes" "$payload"; sleep 2; printf 'checkpoint\ndiagnostics\nclose\nexit\n' ) | "$probe" > "$work/a.$p.out" &
    else
        ( printf 'open %s\nmeasure s%d %d %d\n' "$db" "$p" "$writes" "$payload"; sleep 3; printf 'diagnostics\nclose\nexit\n' ) | "$probe" > "$work/a.$p.out" &
    fi
done
wait
for p in $(seq 1 "$processes"); do
    echo "process $p: $(grep '^measured' "$work/a.$p.out")"
done
echo "checkpoint by process 1 with $((processes - 1)) other processes open: $(grep '^checkpoint' "$work/a.1.out")"
ls -l "$db" "$db-wal" 2>/dev/null | awk '{print "file after all closed:", $5, "bytes", $9}'
echo

echo "== B. single writer, same corpus per process, for the contention cost above"
db="$work/b.sqlite"
printf 'open %s\nmeasure s1 %d %d\ndiagnostics\nclose\nexit\n' "$db" "$writes" "$payload" | "$probe" | grep -E '^measured'
echo

echo "== C. one process holds the write lock for $hold_ms ms; $processes already-open writers wait with a $budget_ms ms budget"
db="$work/c.sqlite"
for p in $(seq 1 "$processes"); do
    ( printf 'open %s %d\n' "$db" "$budget_ms"; sleep 1; printf 'measure w%d 20 %d\ndiagnostics\nclose\nexit\n' "$p" "$payload" ) | "$probe" > "$work/c.$p.out" &
done
( sleep 0.3; printf 'open %s\nhold-for %d 1 16\nclose\nexit\n' "$db" "$hold_ms" ) | "$probe" > "$work/c.hold.out" &
wait
echo "holder: $(grep -E '^(held|committed)' "$work/c.hold.out" | tr '\n' ' ')"
for p in $(seq 1 "$processes"); do
    echo "waiter $p: $(grep '^measured' "$work/c.$p.out")"
done
echo "rows after: $(printf 'open %s\ncount-events w1\ncount-events w2\ncount-apps\nclose\nexit\n' "$db" | "$probe" | grep -E '^(events|apps)' | tr '\n' ' ')"
