# Mecum vs Cua Driver comparison harness

Runs the same operations on the same windows through one MCP stdio client and writes one JSONL
row per call: latency, reply size and estimated model tokens, CPU/energy of the driver and the
target, WindowServer CPU, and what an independent probe saw (frontmost app, cursor, windows, AX
values). Method and results of the 6 October 2026 run:
`Documentation/Driver/reports/CUADriverBenchmark20261006.md`.

| File | Role |
| --- | --- |
| `Server/main.swift` | Mecum's `AutomationTools` over MCP stdio (`mecum-mcp-stdio`), a benchmark tool only |
| `compare.py`, `mcpclient.py`, `rusage.py` | Scenarios, runner and MCP client |
| `probe.swift`, `ocr.swift` | Independent observers, built to `.build/probe` and `.build/ocr` |
| `summarize.py`, `headline.py` | Tables from the JSONL (`headline.py` still knows only `mecum` and `cua`) |

## Build

Always `/usr/bin/swift` (Xcode-beta toolchain), never the `swift` on `PATH`.

```sh
cd Tools/Driver/CUAComparison
/usr/bin/swift build -c release
/usr/bin/swiftc -O probe.swift -o .build/probe
/usr/bin/swiftc -O ocr.swift -o .build/ocr
```

Cua (checkout at `~/Forte_Projects/_bench/cua`, or set `CUA_DRIVER` to the binary):

```sh
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
cd libs/cua-driver/rust
CARGO_PROFILE_RELEASE_STRIP=none CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none \
  cargo build --release -p cua-driver
```

The strip overrides are needed on macOS 27, where dyld rejects stripped proc-macro dylibs.

## Run

Stage Manager must be off: with it on, the target window is stashed as a thumbnail and neither
driver can adopt or bind it. Launch the target apps first, then:

```sh
MECUM_BENCH_SCRATCH="$(mktemp -d /tmp/mecum-cua-bench.XXXXXX)"
MECUM_APP_SUPPORT_DIR="$MECUM_BENCH_SCRATCH" python3 compare.py \
  --apps Calculator --drivers mecum,cua,cua-overlay --reps 1 \
  --out results.jsonl --scratch "$MECUM_BENCH_SCRATCH"
python3 summarize.py results.jsonl
```

Always set `MECUM_APP_SUPPORT_DIR` for Mecum. Mecum runs with its research opt-in for an
unvalidated macOS build (`MECUM_BENCH_UNVALIDATED=1`, set by the harness).

## Driver variants

| `--drivers` | Launched as | Notes |
| --- | --- | --- |
| `mecum` | `.build/release/mecum-mcp-stdio <knowledge dir>` | One Seat session per app block |
| `cua` | `cua-driver mcp --direct` | The MCP process owns the runtime; no agent cursor overlay (the overlay calls return `facility_unavailable`) |
| `cua-overlay` | Daemon-backed Cua, overlay on (its default) | See below |
| `cua-fast` | `cua-driver mcp --direct` with `CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0` | Opt-in floor, not part of any default run |

Every Cua variant keeps Cua's defaults, including the 1000 ms post-action window watch, and runs
with telemetry off (`CUA_DRIVER_RS_TELEMETRY_ENABLED=0`, also persisted by `cua-driver telemetry`).

`cua-overlay`, chosen automatically and recorded as `launch` in the `startup` row:

- `app-daemon`: `/Applications/CuaDriver.app` is installed. The harness runs a bare
  `cua-driver mcp`, which proxies to the daemon the CLI auto-launches with
  `open -n -g -a CuaDriver --args serve`. This is the README's "Standalone" mode
  (`libs/cua-driver/README.md`, section "macOS process identity and permissions"). Untested: the
  app was not installed here.
- `embedded-daemon`: no app installed. The harness is the embedding host
  (`libs/cua-driver/rust/Skills/cua-driver/EMBEDDING.md`, "Launching the daemon-backed host"): it
  spawns `cua-driver serve --embedded --socket <scratch>/cua.sock` as its own child with
  `CUA_DRIVER_EMBEDDED=1`, then speaks MCP to `cua-driver mcp --embedded --socket <same>`. The
  daemon owns the AppKit loop the overlay needs and inherits the launching process's grants.
  Driver CPU rows read the daemon, not the stdio proxy.

Overlay default and flags (`--no-overlay`, `--cursor-theme`, ...): `cua-driver --help`, section
"agent cursor overlay", and `libs/cua-driver/rust/Skills/cua-driver/RUNTIME.md`, "Cursor feedback".
The overlay needs the daemon: `README.md` and `EMBEDDING.md` both say direct mode lacks it.
