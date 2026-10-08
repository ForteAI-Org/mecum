# Mecum vs Cua Driver comparison harness

Runs the same operations on the same windows through one MCP stdio client and writes one JSONL
row per call: latency, reply size and tokens (text and image apart), CPU/energy/footprint of the
driver and the target, WindowServer CPU, and what an independent probe saw (frontmost app,
cursor, windows and their display, hashes of AX values, selection, focus, scroll and window
titles). `summarize.py` turns the rows into tables and a `summary.json`. Method and results of the
6 October 2026 run: `Documentation/Driver/reports/CUADriverBenchmark20261006.md`.

| File | Role |
| --- | --- |
| `Server/main.swift` | Mecum's `AutomationTools` over MCP stdio (`mecum-mcp-stdio`), a benchmark tool only |
| `prepare.py` | Preflight (Stage Manager, other Mecum, power, Low Power, thermal, displays), fixtures, the meta row |
| `compare.py`, `mcpclient.py`, `rusage.py` | Scenarios, runner (ops, chain, soak, phases) and MCP client |
| `probe.swift`, `ocr.swift` | Independent observers, built to `.build/probe` and `.build/ocr` |
| `summarize.py`, `headline.py` | Tables and `summary.json` (`headline.py` still knows only `mecum` and `cua`) |
| `fixtures/` | `bench.html` (Chrome/Safari "Bench Page"), `bench.txt` (TextEdit) |

## Build

Always `/usr/bin/swift` (Xcode-beta toolchain), never the `swift` on `PATH`.

```sh
cd Tools/Driver/CUAComparison
/usr/bin/swift build -c release
/usr/bin/swiftc -O probe.swift -o .build/probe
/usr/bin/swiftc -O ocr.swift -o .build/ocr
```

Cua (checkout at `~/Forte_Projects/_bench/cua`, or set `CUA_DRIVER` to the binary; 0.34.0, commit c1c2b5f):

```sh
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
cd libs/cua-driver/rust
CARGO_PROFILE_RELEASE_STRIP=none CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none \
  cargo build --release -p cua-driver
```

The strip overrides are needed on macOS 27, where dyld rejects stripped proc-macro dylibs.

## Run

Stage Manager must be off (`defaults read com.apple.WindowManager GloballyEnabled` = 0): with it on,
the target window is stashed as a thumbnail and neither driver can adopt or bind it. Nothing here
changes it. Take the shared live lock first if other runs share the desktop.

```sh
S="$(mktemp -d /tmp/mecum-cua-bench.XXXXXX)"
python3 prepare.py --scratch "$S" --open Calculator,TextEdit --apps Calculator,TextEdit   # exit 3 = blockers
MECUM_APP_SUPPORT_DIR="$S" python3 compare.py --apps Calculator,TextEdit \
  --drivers mecum,cua,cua-overlay --reps 8 --out "$S/results.jsonl" --scratch "$S"
python3 summarize.py "$S/results.jsonl" --json "$S/summary.json"
```

`prepare.py` reports (never fixes, never kills) its findings under `blockers` (Stage Manager on,
another Mecum running, a binary missing) and `warnings` (battery, Low Power mode, thermal state),
opens the requested apps in the background (`open -g`) on their fixtures (TextEdit on a fresh copy
of `bench.txt`, Chrome in its own profile and Safari on `bench.html` in a "Bench Page" window) and
writes `fixtures.json` (pid and window title per app, read by `compare.py`) and `meta.json` into the
scratch directory. Resolve, Obsidian, Prism Launcher, kitty, Stocks and Photoshop are as on 6 October:
`prepare.py` only reports whether they run (open them with `--open`, except Resolve and Photoshop,
which need a project or a document state). `compare.py` writes the same preflight, the Mac model,
chip, RAM, macOS build and both driver commits and versions into a `kind: "meta"` first row.
Always set `MECUM_APP_SUPPORT_DIR` for Mecum. Mecum runs with its research opt-in for an unvalidated
macOS build (`MECUM_BENCH_UNVALIDATED=1`, set by the harness). Never run `sample` or another profiler
during a measured window.

### Modes

| `--mode` | What it does |
| --- | --- |
| `ops` (default) | One warm-up and `--reps` measured repetitions per driver of each operation; idle CPU in 3 consecutive 10 s windows after the last call; WindowServer baseline before and after |
| `chain` | 10 consecutive steps per app with `--pauses 0,1,3,5` seconds between them, each group after a 6 s rest. Per step: wall time, the gap since the previous call, and for Mecum whether the stream was resting |
| `soak` | `--soak-steps 200` neutral steps (TextEdit by default) per driver, driver and target footprint every 10 steps; the summary gives the slope in MB per 100 steps and any error or stall |
| `--phases` | Mecum alone, from a `MECUM_PHASES` build (see below). Rows are marked `phases: true` and `summarize.py` leaves them out of every timing aggregate |

Order and fairness: drivers alternate per app in ABBA order, for example mecum, cua, cua-overlay,
cua-overlay, cua, mecum (`--order forward` for one pass). `--reps` is per driver and splits over the two
passes, the odd one going to the first. A cooldown (`--cooldown`, 15 s) separates blocks; every block
starts a fresh driver process. TextEdit's `undo` step takes the insert back and Chrome and Safari type
`hello{rep}`, so a repetition starts from the same text; the digest before each repetition's first call
is in the rows. A call with no reply for `--call-timeout` (60 s) kills its driver (our child, by handle),
is recorded as a stall and ends the block.

Success is an effect the independent probe confirmed: an operation names the probe parts that must
change (`values`, `selection`, `focus`, `scroll`, `windows`); `False` there means the probe cannot see
the effect and the row stays unverified. `honest_miss`, `ambiguous`, `refused`, `error` and an
`acted_unverified` whose message says "delivery failed" are failures. If both drivers show 0 confirmed
for an operation, the probe is blind to it or nothing happened: read it as such.

### Photoshop

Framework "Adobe (proprietary toolkit)", process found by name prefix. Never saves: New Document
(menu, then Return), Image Rotation 180 degrees twice, a key, scrolls, File > Close and Don't Save
(Mecum `press`, Cua `click` by name). Known hazards are recorded as failures, not worked around: a
"Start Bar" window can make Mecum's adoption refuse (`moveRefused`), and right after a new document
Photoshop can be "not ready" for about 2 s. Cua rebinds to the top window before each step, since the
dialog and the document are separate windows.

## Driver variants

| `--drivers` | Launched as | Notes |
| --- | --- | --- |
| `mecum` | `.build/release/mecum-mcp-stdio <knowledge dir>` (`MECUM_BIN` overrides) | One Seat session per app block |
| `cua` | `cua-driver mcp --direct` | The MCP process owns the runtime; no agent cursor overlay |
| `cua-overlay` | Daemon-backed Cua, overlay on (its default) | See below |
| `cua-legacy` | As `cua`, acting the 6 October way | Secondary series `step_legacy` |
| `cua-fast` | `cua-driver mcp --direct` with `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0` | Opt-in floor, never in a report |

Every Cua variant keeps Cua's defaults, including the 1000 ms post-action window watch, and runs
with telemetry off (`CUA_DRIVER_RS_TELEMETRY_ENABLED=0`).

`cua-overlay`, chosen automatically and recorded as `launch` in the `startup` row:

- `app-daemon`: `/Applications/CuaDriver.app` is installed. The harness runs a bare
  `cua-driver mcp`, which proxies to the daemon the CLI auto-launches. Untested: the app was not
  installed here.
- `embedded-daemon`: no app installed. The harness is the embedding host
  (`libs/cua-driver/rust/Skills/cua-driver/EMBEDDING.md`, "Launching the daemon-backed host"): it
  spawns `cua-driver serve --embedded --socket <scratch>/cua.sock` as its own child, then speaks MCP
  to `cua-driver mcp --embedded --socket <same>`. Driver CPU and footprint rows read the daemon pid;
  the stdio proxy is in `proxy_cpu_ms` and `proxy_footprint_mb`.

## How Cua is driven

Parity means Cua is used the way its docs tell users to use it at c1c2b5f
(`libs/cua-driver/rust/Skills/cua-driver/`):

- **Step** (`series: "step"`): one `run_actions` call with `observe:true`, the target named by
  `role`/`name` (or `x`,`y` pixels of the last screenshot for the TextEdit caret click), `pid` and
  `window_id` on the call. SKILL.md "Act through `run_actions` with `observe:true`, even for a single
  step"; WORKFLOW.md "Batch known actions" and the `run_actions` schema ("TARGET BY NAME"). The reply
  carries the `since:"latest"` diff, no screenshot. Menus are not a `run_actions` tool: `invoke_menu`
  followed by a diff read (`observe_after`), the re-read WORKFLOW.md "Observe" recommends.
- **Full read** (`observe`): plain `get_window_state`, the 250-node markdown tree and a screenshot
  (WORKFLOW.md "Observe"; MACOS.md, the 250-node cap).
- **Diff read** (`observe_unchanged`): `get_window_state` with `since:"latest"` and
  `include_screenshot:false`, the counterpart of Mecum's unchanged read (WORKFLOW.md "Observe",
  `since`; MACOS.md "pass `since:"latest"` and `include_screenshot:false`").
- **Legacy step** (`cua-legacy`, `series: "step_legacy"`): the action by `element_token`, then
  `get_window_state` with `full_output:true` (the previous full payload). Kept only to compare with
  6 October.

The equivalent step of Mecum is its action call alone: the reply already has the scene.

## Row schema

Call rows keep the 6 October fields (`driver`, `app`, `framework`, `op`, `rep`, `tool`, `ms`, `ok`,
`error`, `self_verdict`, `reply_bytes`, `text_chars`, `images`, `image_px`, `image_tokens`,
`driver_cpu_ms`, `driver_instructions`, `driver_energy_mj`, `driver_footprint_mb`, `driver_peak_mb`,
`app_cpu_ms`, `app_energy_mj`, `windowserver_cpu_ms`, `frontmost_before/after`, `cursor_moved`,
`effect_seen`, `target_pid`) and add:

| Field | Meaning |
| --- | --- |
| `kind` | `meta` on the first row (preflight, machine, driver versions), absent on call rows |
| `mode`, `block`, `order_pass`, `series` | Run mode, ABBA block, `forward`/`reverse`, `step` or `step_legacy` |
| `step`, `after_op` | Position of the operation in the repetition; the operation an `observe_after` row follows |
| `tokens_text`, `image_tokens`, `tokens` | Text tokens (chars / 4), image tokens (w x h / 750 after resize), their sum |
| `proxy_cpu_ms`, `proxy_footprint_mb`, `app_footprint_mb` | Cua stdio proxy beside the daemon; the target's footprint |
| `expect`, `verified`, `success` | Probe parts that must change; whether they did; true/false/null (unverified) |
| `frontmost_changed`, `cursor_moved`, `cursor_moved_call`, `user_windows_before/after`, `window_on_user_display` | Intrusion: another app became frontmost, the cursor moved (probe window and the call alone), a window of the target newly onscreen on a display that is not the Seat's (vendor `0xF0A7`) |
| `gap_s`, `stream_resting` | Seconds since the previous call ended; for Mecum, `gap_s > 2.5` (ADR 0036), inferred and not observed |
| `pause_s`, `chain_step`, `soak_step` | Chain and soak position |
| `window`, `since_last_call_s` | Idle windows (`op: "idle"`), CPU also in `proxy_cpu_ms`, `app_cpu_ms` |
| `digest_before`, `digest_after` | Probe digest around the call |

Chain mode also writes one `op: "chain_step"` row per step (wall time of the step, Cua's observation
included) and soak writes `op: "soak_mem"` rows every 10 steps.

## summary.json

`python3 summarize.py results.jsonl [more.jsonl] --json summary.json` writes, per driver, app and
operation: n, reported-ok and confirmed counts with Wilson 95% intervals, latency p50/p90/p99/mean/
stdev, tokens (text, image, total), CPU (ms and ms per second of the call) and energy; per app the
equivalent steps, the full and unchanged/diff reads, idle windows, intrusion counts, chain and soak;
per driver startup, footprint median and peak; plus the meta rows and the WindowServer baseline.
It reads the 6 October `all.jsonl` too: missing fields become null, so deltas can be computed against
it. `python3 summarize.py --selftest` checks the statistics helpers.

## Phase breakdown

A separate run, never mixed with the timed one (a signpost build is slower, and `compare.py` refuses
`--phases` with any driver but `mecum`):

```sh
/usr/bin/swift build -c release -Xswiftc -DMECUM_PHASES --scratch-path ~/Forte_Projects/_bench/phases-build
MECUM_PHASES_BIN=~/Forte_Projects/_bench/phases-build/release/mecum-mcp-stdio \
  python3 compare.py --phases --drivers mecum --apps Calculator --reps 4 --out "$S/phases.jsonl" --scratch "$S"
```

The harness records `Tools/Driver/Phases/phase-table.py record` for the run; its table is written
to `<out>.phases.txt` and the raw signposts to `<out>.signposts.ndjson`.

## Limits

- The Mecum stream's rest is inferred from the gap; the phases run shows the real `preview.rest` events.
- WindowServer CPU is read through `ps` at 10 ms resolution: per-call values are coarse, idle windows are fine.
- The probe sees AX values, not pixels: kitty, Obsidian and Photoshop pixel effects stay unverified.
- The physical cursor moves when the person uses the Mac; idle and baseline rows carry the same check as a control.
