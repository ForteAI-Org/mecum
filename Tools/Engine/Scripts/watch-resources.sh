#!/bin/bash
#
#  watch-resources.sh
#  Mecum, Engine layer
#
#  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
#
# Measures what `mecum watch` costs: CPU, memory, threads, idle wakeups and context switches in an idle
# phase (hands off), an active one (the person uses the machine) and a stall one (SIGUSR2 pauses the
# event loop while the person clicks and scrolls a lot); the tap callback's latency per phase (SIGUSR1
# closes each phase); the stop counters and the events seen. It prints a first reading next to the
# fixed numbers of the 29 Sep 2026 run and leaves every raw file under .build/watch-resources/<time>/,
# with `latest` pointing at the last run.
#
# It runs the real listen-only tap, so it records the person's pointer input for its duration and
# needs Input Monitoring for the launching terminal. It posts no input and signals only its own PIDs.
#
#   Tools/Engine/Scripts/watch-resources.sh             60 s idle, 60 s active, 30 s stall
#   IDLE=20 ACTIVE=20 STALL=15 Tools/Engine/Scripts/watch-resources.sh
#   ANALYZE=.build/watch-resources/<time> Tools/Engine/Scripts/watch-resources.sh   reads a run again

set -u

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
IDLE=${IDLE:-60}
ACTIVE=${ACTIVE:-60}
STALL=${STALL:-30}
WARM=5
STAMP=$(date +%Y%m%d-%H%M%S)
BASE="$ROOT/.build/watch-resources"
BIN="$ROOT/.build/release/mecum"

analyze() {
python3 - "$1" <<'PY' | tee "$1/summary.txt"
import json, os, re, sys

out = sys.argv[1]
MODE = "inprocess"
PHASES = ("idle", "active", "stall")
FASE = {"idle": "a riposo", "active": "in uso", "stall": "in stallo"}
KINDS = ("input", "pointer", "timer")
MIN_SAMPLES = 50

env = {}
for line in open(os.path.join(out, "environment.txt")):
    parts = line.split()
    if parts and parts[0] == "idle":
        env = {key: float(value) for key, value in zip(parts[0::2], parts[1::2])}
idle_s, active_s, stall_s = env["idle"], env["active"], env.get("stall", 0.0)

def seconds(cpu):
    total = 0.0
    for part in cpu.split(":"):
        total = total * 60 + float(part)
    return total

def kib(text):
    match = re.match(r"([\d.]+)([BKMG]?)", text)
    if not match:
        return None
    value, unit = float(match.group(1)), match.group(2)
    return value * {"B": 1 / 1024, "K": 1, "M": 1024, "G": 1024 * 1024, "": 1 / 1024}[unit]

def top_rows(path):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path, errors="replace"):
        parts = line.split()
        if len(parts) >= 7 and parts[0].isdigit():
            try:
                rows.append({"cpu": float(parts[1]), "mem": kib(parts[2]),
                             "threads": int(re.sub(r"\D", "", parts[3]) or 0),
                             "idlew": int(re.sub(r"\D", "", parts[4]) or 0),
                             "csw": int(re.sub(r"\D", "", parts[5]) or 0)})
            except ValueError:
                pass
    return rows[1:]  # top's first sample has no interval behind it

def stats(chunk):
    if not chunk:
        return {}
    return {"cpu_avg_pct": round(sum(r["cpu"] for r in chunk) / len(chunk), 3),
            "cpu_max_pct": max(r["cpu"] for r in chunk),
            # top prints IDLEW and CSW as totals since the process started, not per sample.
            "idle_wakeups_per_s": round((chunk[-1]["idlew"] - chunk[0]["idlew"]) / max(1, len(chunk) - 1), 2),
            "context_switches_per_s": round((chunk[-1]["csw"] - chunk[0]["csw"]) / max(1, len(chunk) - 1), 1),
            "threads_max": max(r["threads"] for r in chunk)}

CALLBACK = re.compile(r"callback\[(\w+)\] (input|pointer|timer): n (\d+)"
                      r"(?: p50 ([\d.]+)us p90 ([\d.]+)us p99 ([\d.]+)us max ([\d.]+)us)?"
                      r" \(since last dump(, at stop)?\)")

# One dump is an input, a pointer and a timer line, in that order; an input line starts the next.
def callback_dumps(text):
    dumps, stops = [], []
    for match in CALLBACK.finditer(text):
        line = {"role": match.group(1), "n": int(match.group(3))}
        if match.group(4):
            line.update(p50_us=float(match.group(4)), p90_us=float(match.group(5)),
                        p99_us=float(match.group(6)), max_us=float(match.group(7)))
        group = stops if match.group(8) else dumps
        if match.group(2) == "input" or not group:
            group.append({})
        group[-1][match.group(2)] = line
    return dumps, stops

snaps = {}
path = os.path.join(out, "snapshots.txt")
for line in open(path) if os.path.exists(path) else []:
    mode, phase, role, pid, cpu, rss, threads = line.split()
    if mode == MODE and role == "engine":
        snaps[phase] = (seconds(cpu), int(rss), int(threads))

folder = os.path.join(out, MODE)
if not os.path.exists(os.path.join(folder, "marks.txt")):
    sys.exit(f"nessuna misura in {folder}")
notes = []
entry = {}
marks = {key: int(value) for key, value in (l.split() for l in open(os.path.join(folder, "marks.txt")))}
events = [json.loads(l) for l in open(os.path.join(folder, "events.jsonl")) if l.strip().startswith("{")]
def kinds(lo, hi):
    counted = {}
    for event in events[lo:hi]:
        counted[event.get("kind", "?")] = counted.get(event.get("kind", "?"), 0) + 1
    return counted
entry["events_idle"] = kinds(marks["idle_start"], marks["idle_end"])
entry["events_active"] = kinds(marks["idle_end"], marks["active_end"])
# The paused loop prints the stall's events after the resume, so the stall owns the whole tail.
entry["events_stall"] = kinds(marks["active_end"], len(events))
stderr = open(os.path.join(folder, "stderr.log"), errors="replace").read()
counters = re.findall(r"counters: .*", stderr)
entry["counters"] = counters[-1] if counters else None
entry["pids"] = open(os.path.join(folder, "pids.txt")).read().split("\n")
exit_code = next((int(p.split()[1]) for p in entry["pids"] if p.startswith("exit ")), None)

signals_path = os.path.join(folder, "signals.txt")
sent = [tuple(l.split()) for l in open(signals_path)] if os.path.exists(signals_path) else []
entry["signals"] = [" ".join(s) for s in sent]
dumps, stops = callback_dumps(stderr)
closed = [label for label, sig, state in sent if sig == "USR1" and state == "sent"]
callback = dict(zip(closed, dumps))
if len(dumps) != len(closed):
    notes.append(f"{len(closed)} SIGUSR1 inviati, {len(dumps)} gruppi di righe callback ricevuti")
if any(set(dump) != set(KINDS) for dump in dumps + stops):
    notes.append("un gruppo di righe callback non ha input, pointer e timer")
if stops:
    # A process gone before the stall's SIGUSR1 leaves the stall to its stop lines.
    if "stall" not in callback:
        callback["stall"] = dict(stops[0], source="stop line")
    else:
        entry["callback_tail"] = stops[0]
entry["callback"] = callback

failure = re.findall(r"^mecum: (.*)$", stderr, re.M)
stall_events = events[marks["active_end"]:]
gaps = [e["gap"] for e in stall_events if e.get("kind") == "gap" and e.get("gap")]
lost = re.search(r"lost (\d+) clicks/focus (\d+) hovers/scrolls in (\d+) gaps", entry["counters"] or "")
alive = ("stall", "USR1", "sent") in sent
entry["stall"] = {
    "survived": alive and exit_code == 0 and not failure,
    "alive_at_end": alive,
    "exit": exit_code,
    "failure": failure[-1] if failure else None,
    "events_after_active": len(stall_events),
    "gap_events": len(gaps),
    "lost_in_gap_events": [sum(g["lostCritical"] for g in gaps), sum(g["lostCoalescible"] for g in gaps)],
    "counters_lost": {"clicks_focus": int(lost.group(1)), "hovers_scrolls": int(lost.group(2)),
                      "gaps": int(lost.group(3))} if lost else None,
}

order = ("idle_start", "idle_end", "active_end", "stall_end")
if snaps.get("idle_start"):
    rows = top_rows(os.path.join(folder, "top-engine.log"))
    i, a = int(idle_s), int(active_s)
    chunks = {"idle": rows[: i - 1], "active": rows[i: i + a - 1], "stall": rows[i + a:]}
    def cpu(start, end, span):
        if not (snaps.get(start) and snaps.get(end)) or not span:
            return None, None
        spent = snaps[end][0] - snaps[start][0]
        return round(spent, 3), round(spent / span * 100, 3)
    result = {}
    for phase, start, end, span in (("idle", "idle_start", "idle_end", idle_s),
                                    ("active", "idle_end", "active_end", active_s),
                                    ("stall", "active_end", "stall_end", stall_s)):
        result[f"{phase}_cpu_seconds"], result[f"{phase}_cpu_pct"] = cpu(start, end, span)
        result[f"top_{phase}"] = stats(chunks[phase])
    result["rss_kib"] = [snaps[p][1] if snaps.get(p) else None for p in order]
    result["threads"] = [snaps[p][2] if snaps.get(p) else None for p in order]
    entry["engine"] = result

report = {MODE: entry, "notes": notes}
json.dump(report, open(os.path.join(out, "summary.json"), "w"), indent=2, sort_keys=True)

def verdict(ok, text):
    print(("  OK   " if ok else "  !!   ") + text)

def note(text):
    print("  --   " + text)

def kind(phase, name):
    return callback.get(phase, {}).get(name)

def triple(line):
    if not line:
        return "-"
    if "p99_us" not in line:
        return f"n {line['n']}"
    return f"{line['p50_us']}/{line['p99_us']}/{line['max_us']} (n {line['n']})"

def enough(line):
    return bool(line) and "p99_us" in line and line["n"] >= MIN_SAMPLES

def outcome():
    stall = entry["stall"]
    if stall["failure"]:
        return "morto: " + stall["failure"][:60]
    if not stall["alive_at_end"]:
        return "processo sparito prima della fine"
    lost = stall["counters_lost"]
    if lost:
        return f"vivo, {lost['gaps']} gap, persi {lost['clicks_focus']} click/focus {lost['hovers_scrolls']} hover/scroll"
    return f"vivo, {stall['gap_events']} gap"

print("\n[in-process]")
span = {"idle": idle_s, "active": active_s, "stall": stall_s}
if "engine" in entry:
    r = entry["engine"]
    wake = r["top_idle"].get("idle_wakeups_per_s")
    print(f"  CPU a riposo {r['idle_cpu_pct']}%  in uso {r['active_cpu_pct']}%  in stallo {r['stall_cpu_pct']}%  "
          f"RSS {[round(x / 1024, 1) if x else None for x in r['rss_kib']]} MiB  "
          f"thread {r['threads']}  wakeup a riposo {wake}/s")
    if r["idle_cpu_pct"] is not None:
        verdict(r["idle_cpu_pct"] <= 0.1, "a riposo ≤ 0,1% CPU (soglia B9)")
    if wake is not None:
        verdict(wake <= 5, "a riposo senza polling (≤ 5 wakeup/s)")
    rss = r["rss_kib"]
    if rss[0] and rss[2]:
        verdict(rss[2] - rss[0] < 20 * 1024, f"memoria stabile (+{round((rss[2] - rss[0]) / 1024, 1)} MiB)")
print(f"  eventi a riposo  {entry['events_idle']}")
print(f"  eventi in uso    {entry['events_active']}")
print(f"  eventi in stallo {entry['events_stall']} (stampati dopo la ripresa)")
verdict(sum(entry["events_active"].values()) > 0, "il tap riceve input nella fase attiva")
verdict(entry["events_active"].get("focus", 0) > 0, "cambi di app ricevuti come focus (hai cambiato app?)")
verdict(sum(v for k, v in entry["events_idle"].items() if k not in ("focus", "hover")) == 0,
        "nessun click/scroll inventato a riposo")
verdict(entry["events_active"].get("gap", 0) == 0, "nessun gap a ritmo umano")
for phase in PHASES:
    for name in KINDS:
        print(f"  callback {name:7} {FASE[phase]:9} p50/p99/max µs {triple(kind(phase, name))}")
for phase in PHASES:
    line = kind(phase, "timer")
    print(f"  timer/s {FASE[phase]:9} {line['n'] / span[phase]:.1f}" if line and span[phase] else f"  timer/s {FASE[phase]:9} -")
if entry["counters"]:
    print(f"  {entry['counters']}")

print("\n[verdetti sul callback]")
for phase in PHASES:
    line = kind(phase, "input")
    if not line or "max_us" not in line:
        note(f"{FASE[phase]}: nessun campione input")
    else:
        verdict(line["max_us"] <= 1000, f"{FASE[phase]}: nessun callback input > 1 ms (max {line['max_us']} µs)")
stall, active = kind("stall", "input"), kind("active", "input")
if enough(stall) and enough(active):
    change = (stall["p99_us"] - active["p99_us"]) / active["p99_us"] * 100
    verdict(abs(change) <= 5, f"p99 input in stallo entro il 5% di quello in uso ({change:+.1f}%, isolamento B9)")
else:
    note(f"isolamento, campioni insufficienti (ne servono {MIN_SAMPLES} in uso e in stallo)")
for phase in PHASES:
    line = kind(phase, "pointer")
    if enough(line):
        verdict(line["p50_us"] <= 0.5 and line["max_us"] <= 60,
                f"{FASE[phase]}: pointer p50 ≤ 0,5 µs e max ≤ 60 µs (obiettivo di T6): {line['p50_us']}/{line['max_us']} µs")
    else:
        note(f"{FASE[phase]}: pointer, campioni insufficienti (ne servono {MIN_SAMPLES})")
verdict(entry["stall"]["survived"] and entry["stall"]["counters_lost"] is not None,
        f"sopravvive allo stallo con i gap contati: {outcome()}")

print("\n[riferimento, misura del 29/09/2026] p50/p99/max µs")
print("  originale       input 1042/2575/2874   pointer 0.4/13.5/57      timer 10/s a riposo")
print("  T1 prima di T6  input 2.5/13.7/37      pointer 1.1/22.9/135.4")
print(f"  questa misura   input {triple(kind('active', 'input'))}   pointer {triple(kind('active', 'pointer'))}   (in uso)")

for line in open(os.path.join(out, "environment.txt")):
    if line.startswith("binary "):
        print("  " + line.strip())
for text in notes:
    note(text)
print("\nNon misurato qui: il ritardo di consegna (il callback è misurato dal suo corpo), throughput su burst sintetici"
      "\n(nei test unitari). SIGUSR2 ferma solo il lettore dello stream; il thread consumatore continua a svuotare"
      "\nla coda, quindi lo stallo non mette sotto pressione la coda.")
PY
}

if [ -n "${ANALYZE:-}" ]; then
    analyze "$ANALYZE"
    exit 0
fi

OUT="$BASE/$STAMP"
mkdir -p "$OUT"
ln -sfn "$OUT" "$BASE/latest"

CHILDREN=()
cleanup() {
    for pid in "${CHILDREN[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
}
trap 'cleanup; echo; echo "interrotto: file parziali in $OUT"; exit 130' INT TERM

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

countdown() {
    local seconds=$1 label=$2
    while [ "$seconds" -gt 0 ]; do
        printf '\r  %s: %3d s ' "$label" "$seconds"
        sleep 1
        seconds=$((seconds - 1))
    done
    printf '\r  %s: fatto        \n' "$label"
}

# One line: mode, phase label, role, pid, cumulative CPU time, RSS in KiB, threads.
snapshot() {
    local phase=$1 mode=$2 pid=${ENGINE:-}
    [ -z "$pid" ] && return
    kill -0 "$pid" 2>/dev/null || return
    local line threads
    line=$(ps -o time=,rss= -p "$pid" | awk '{print $1, $2}')
    threads=$(ps -M -p "$pid" | tail -n +2 | wc -l | tr -d ' ')
    echo "$mode $phase engine $pid $line $threads" >> "$OUT/snapshots.txt"
}

# True while the pid is still a live mecum, so an exited and reused pid is never signalled.
ours() { ps -o comm= -p "$1" 2>/dev/null | grep -Eq 'mecum$'; }

# Signals one of this run's processes and records `<label> <signal> sent|gone` in signals.txt.
signal_to() {
    local pid=$1 sig=$2 label=$3
    if [ -n "$pid" ] && ours "$pid" && kill "-$sig" "$pid" 2>/dev/null; then
        echo "$label $sig sent" >> "$DIR/signals.txt"
    else
        echo "$label $sig gone" >> "$DIR/signals.txt"
    fi
}

say "Build release di mecum"
if ! (cd "$ROOT" && xcrun swift build -c release --product mecum > "$OUT/build.log" 2>&1); then
    echo "build fallita, vedi $OUT/build.log"
    exit 1
fi
{
    echo "date $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "macos $(sw_vers -productVersion) $(sw_vers -buildVersion)"
    echo "hardware $(sysctl -n hw.model) $(sysctl -n machdep.cpu.brand_string) cores $(sysctl -n hw.ncpu)"
    echo "commit $(cd "$ROOT" && git rev-parse --short HEAD) dirty $(cd "$ROOT" && git status --porcelain | wc -l | tr -d ' ')"
    echo "binary $(basename "$BIN") bytes $(stat -f%z "$BIN") otool_L_lines $(otool -L "$BIN" | wc -l | tr -d ' ')"
    echo "idle $IDLE active $ACTIVE stall $STALL warm $WARM"
} > "$OUT/environment.txt"

run_mode() {
    local mode=inprocess
    DIR="$OUT/$mode"
    mkdir -p "$DIR"
    say "Avvio mecum watch"
    ENGINE=""
    # --duration is only a safety net: SIGTERM ends the run once the stall is over.
    "$BIN" watch --raw --json --duration $((WARM + IDLE + ACTIVE + STALL + 60)) \
        > "$DIR/events.jsonl" 2> "$DIR/stderr.log" &
    ENGINE=$!
    CHILDREN+=("$ENGINE")
    sleep "$WARM"
    if ! kill -0 "$ENGINE" 2>/dev/null; then
        echo "  mecum watch è uscito subito:"
        sed 's/^/    /' "$DIR/stderr.log"
        grep -qi "input monitoring\|inputMonitoringDenied" "$DIR/stderr.log" \
            && echo "  → concedi Input Monitoring al terminale, chiudilo, riaprilo e rilancia."
        return 1
    fi
    echo "engine $ENGINE" > "$DIR/pids.txt"
    local samples=$((IDLE + ACTIVE + STALL))
    top -l "$samples" -s 1 -pid "$ENGINE" -stats pid,cpu,mem,threads,idlew,csw,power \
        > "$DIR/top-engine.log" 2>&1 &
    CHILDREN+=("$!")

    snapshot idle_start "$mode"
    echo "idle_start $(wc -l < "$DIR/events.jsonl")" > "$DIR/marks.txt"
    say "FASE 1/3 · $IDLE s · NON toccare mouse, trackpad e tastiera"
    countdown "$IDLE" "idle"
    snapshot idle_end "$mode"
    signal_to "$ENGINE" USR1 idle
    echo "idle_end $(wc -l < "$DIR/events.jsonl")" >> "$DIR/marks.txt"

    say "FASE 2/3 · $ACTIVE s · usa il Mac: muovi, clicca, scrolla, cambia app, apri un popup e cliccaci subito dentro, fermati ogni tanto sopra un bottone"
    countdown "$ACTIVE" "attiva"
    snapshot active_end "$mode"
    signal_to "$ENGINE" USR1 active
    echo "active_end $(wc -l < "$DIR/events.jsonl")" >> "$DIR/marks.txt"

    signal_to "$ENGINE" USR2 stall_start
    say "FASE 3/3 · $STALL s · consumatore fermo: clicca, fai clic destro e scrolla il più possibile, veloce e senza pause, su una zona innocua (il desktop o una finestra vuota del Finder); Esc chiude i menu"
    countdown "$STALL" "stallo"
    snapshot stall_end "$mode"
    signal_to "$ENGINE" USR1 stall
    echo "stall_end $(wc -l < "$DIR/events.jsonl")" >> "$DIR/marks.txt"
    sleep 1
    signal_to "$ENGINE" USR2 stall_end
    say "Fine della misura: puoi fermarti. Il consumatore riparte e smaltisce, poi lo stop."
    sleep 3
    signal_to "$ENGINE" TERM stop

    wait "$ENGINE"
    echo "exit $?" >> "$DIR/pids.txt"
    wait 2>/dev/null
    CHILDREN=()
    return 0
}

run_mode || { echo "interrotto: file in $OUT"; exit 1; }

say "Lettura"
analyze "$OUT"

echo
echo "Report: $BASE/latest  (summary.json, summary.txt e i file grezzi)"
