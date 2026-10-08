"""One command for the whole Mecum vs Cua Driver benchmark (see `./bench.sh --help`).

Order: preflight (abort on blockers), build both drivers, per-call run, chain, soak, optional phases, model
tasks, summaries, then report.py. Everything of one run lives in ~/Forte_Projects/_bench/runs/<YYYYMMDD-HHMM>/.
The only processes this script ends are the apps prepare.py launched, by PID.
"""
import argparse, json, os, re, signal, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
SWIFT = "/usr/bin/swift"
SWIFTC = "/usr/bin/swiftc"
RUNS = os.path.expanduser("~/Forte_Projects/_bench/runs")
PHASES_BUILD = os.path.expanduser("~/Forte_Projects/_bench/phases-build")
FALLBACK_APPS = ("Calculator,TextEdit,Google Chrome,Safari,Obsidian,Stocks,kitty,DaVinci Resolve,Prism Launcher")
CHAIN_APPS = "Calculator,TextEdit,Google Chrome"
TASK_OF_APP = {"Calculator": "calculator", "TextEdit": "textedit", "Google Chrome": "chrome-form", "Safari": "safari-form",
               "Obsidian": "obsidian", "kitty": "kitty", "Photoshop": "photoshop", "Prism Launcher": "prism-toggle"}
# Process name that `ps` shows for an app prepare.py launched, to check a PID is still that app before ending it.
PROCESS_OF = {"Calculator": "Calculator", "TextEdit": "TextEdit", "Google Chrome": "Google Chrome", "Safari": "Safari",
              "Stocks": "Stocks", "Obsidian": "Obsidian", "kitty": "kitty", "Prism Launcher": "prismlauncher"}


def default_apps():
    try:
        sys.path.insert(0, HERE)
        from compare import SCENARIOS
        return ",".join(a for a in SCENARIOS if a != "Photoshop")
    except Exception:
        return FALLBACK_APPS


class Run:
    def __init__(self, options):
        self.o, self.failed, self.steps = options, [], []
        self.started = time.time()
        self.dir = os.path.expanduser(options.run_dir) if options.run_dir else os.path.join(RUNS, time.strftime("%Y%m%d-%H%M"))
        self.env = dict(os.environ, MECUM_APP_SUPPORT_DIR=self.dir)

    def path(self, name):
        return os.path.join(self.dir, name)

    def sh(self, name, argv, cwd=HERE, env=None, check=False):
        """Runs one phase with its output in logs/<name>.log; returns the exit code (None when dry-run)."""
        print(f"[{time.strftime('%H:%M:%S')}] {name}: {' '.join(argv)}", flush=True)
        if self.o.dry_run:
            return None
        os.makedirs(self.path("logs"), exist_ok=True)
        t0 = time.time()
        with open(self.path(f"logs/{name}.log"), "w") as log:
            code = subprocess.run(argv, cwd=cwd, env=env or self.env, stdout=log, stderr=subprocess.STDOUT).returncode
        self.steps.append(dict(name=name, exit=code, seconds=round(time.time() - t0)))
        print(f"    exit {code} in {time.time() - t0:.0f} s", flush=True)
        if code and not check:
            self.failed.append(name)
        return code


def estimate(o, run, apps, tasks):
    """Rough minutes per phase from the knobs: about 14 s a repetition of the operations, 1.4 s a chain or soak step."""
    drivers = len(o.drivers.split(","))
    n = len(apps)
    ops = n * (2 * drivers * o.cooldown + drivers * ((o.reps + 1) * 14 + o.idle_windows * o.idle_seconds) + 15) / 60
    chain_apps = [a for a in o.chain_apps.split(",") if a]
    pauses = [float(p) for p in o.pauses.split(",")]
    chain = len(chain_apps) * drivers * (sum(o.chain_steps * (1.4 + p) + o.group_rest for p in pauses) + o.cooldown) / 60
    soak = drivers * (o.soak_steps * 1.4 + o.cooldown) / 60
    phases = 4 if o.phases else 0
    parts = {"preflight and builds": 3, "per-call run": ops, "chain": chain, "soak": soak, "phases": phases}
    if tasks:
        line = subprocess.run([PY, "tasks.py", "--dry-run", "--tasks", ",".join(tasks), "--reps", str(o.task_reps), "--drivers", o.drivers,
                               "--max-minutes", str(o.task_max_minutes)], cwd=HERE, capture_output=True, text=True).stdout
        m = re.search(r"estimate (\d+) min \(cap (\d+)", line)
        parts["model tasks"] = min(int(m.group(1)), int(m.group(2))) if m else 0
    return parts


def blockers_of(run):
    try:
        return json.load(open(run.path("meta.json"))).get("blockers", [])
    except Exception:
        return ["meta.json missing"]


def prepare(run, apps, open_apps):
    argv = [PY, "prepare.py", "--scratch", run.dir, "--apps", ",".join(apps)]
    if open_apps:
        argv += ["--open", ",".join(a for a in apps if a in PROCESS_OF)]
    code = run.sh("prepare-open" if open_apps else "prepare-preflight", argv, check=True)
    return code, [] if run.o.dry_run else blockers_of(run)


def build(run):
    o = run.o
    run.sh("build-mecum", [SWIFT, "build", "-c", "release"], check=True)
    for name, source, out in (("probe", "probe.swift", ".build/probe"), ("ocr", "ocr.swift", ".build/ocr"),
                              ("axread", "tasks/axread.swift", ".build/axread")):
        src, dst = os.path.join(HERE, source), os.path.join(HERE, out)
        if not os.path.exists(dst) or os.path.getmtime(src) > os.path.getmtime(dst):
            run.sh(f"build-{name}", [SWIFTC, "-O", source, "-o", out], check=True)
    cua = os.environ.get("CUA_DRIVER", os.path.expanduser("~/Forte_Projects/_bench/cua/libs/cua-driver/rust/target/release/cua-driver"))
    root = os.path.abspath(os.path.join(os.path.dirname(cua), "../.."))  # libs/cua-driver/rust
    if os.path.exists(os.path.join(root, "Cargo.toml")):
        env = dict(run.env, PATH="/opt/homebrew/opt/rustup/bin:" + os.environ["PATH"], CARGO_PROFILE_RELEASE_STRIP="none",
                   CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP="none")
        run.sh("build-cua", ["cargo", "build", "--release", "-p", "cua-driver"], cwd=root, env=env, check=True)
    else:
        print(f"    no Cua checkout at {root}: using the binary as it is", flush=True)
    if o.phases:
        run.sh("build-phases", [SWIFT, "build", "-c", "release", "-Xswiftc", "-DMECUM_PHASES", "--scratch-path", PHASES_BUILD], check=True)


def compare(run, name, apps, extra, out):
    o = run.o
    argv = [PY, "compare.py", "--apps", apps, "--drivers", o.drivers, "--cooldown", str(o.cooldown), "--out", run.path(out),
            "--scratch", run.dir] + extra
    return run.sh(name, argv)


def end_launched(run):
    """Ends only the apps prepare.py launched (not already running), by PID, after checking the PID is still that app."""
    try:
        fixtures = json.load(open(run.path("fixtures.json")))
    except Exception:
        return
    for app, info in fixtures.items():
        pid = info.get("pid")
        if not pid or info.get("already_running"):
            continue
        name = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
        if os.path.basename(name) == PROCESS_OF.get(app, app) or os.path.basename(name).startswith(PROCESS_OF.get(app, app)):
            os.kill(pid, signal.SIGTERM)
            print(f"    ended {app} (pid {pid}), launched by prepare.py", flush=True)
        else:
            print(f"    left {app} (pid {pid}): the pid is now {name or 'gone'}", flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter,
                                usage="bench.sh [--apps A,B,...] [--reps 8] [--quick] [--phases] [options]")
    p.add_argument("--apps", help="apps to measure (default: every app of compare.py except Photoshop)")
    p.add_argument("--reps", type=int, default=8, help="measured repetitions per driver and operation")
    p.add_argument("--quick", action="store_true", help="smoke test: 2 reps, chain pauses 0 and 3 s, soak 20 steps, one task rep, short idle and cooldown")
    p.add_argument("--phases", action="store_true", help="also the Mecum phase breakdown (builds a MECUM_PHASES binary)")
    p.add_argument("--drivers", default="mecum,cua,cua-overlay")
    p.add_argument("--chain-apps", default=CHAIN_APPS, help="apps for chain mode (default %(default)s; the app list is intersected)")
    p.add_argument("--pauses", default="0,1,3,5")
    p.add_argument("--chain-steps", type=int, default=10)
    p.add_argument("--group-rest", type=float, default=6)
    p.add_argument("--soak-apps", default="TextEdit")
    p.add_argument("--soak-steps", type=int, default=200)
    p.add_argument("--task-reps", type=int, default=3)
    p.add_argument("--task-max-minutes", type=float, default=60, help="cap of the task phase (tasks.py drops later reps beyond it)")
    p.add_argument("--skip-tasks", action="store_true", help="skip the real-model task phase")
    p.add_argument("--cooldown", type=float, default=15)
    p.add_argument("--idle-windows", type=int, default=3)
    p.add_argument("--idle-seconds", type=float, default=10)
    p.add_argument("--sessions", type=int, default=3)
    p.add_argument("--run-dir", help="default ~/Forte_Projects/_bench/runs/<YYYYMMDD-HHMM>")
    p.add_argument("--out-dir", default="~/Downloads", help="where the two Markdown reports go")
    p.add_argument("--dry-run", action="store_true", help="print the estimate and every command, run nothing")
    o = p.parse_args()
    if o.quick:
        o.reps, o.pauses, o.soak_steps, o.task_reps = 2, "0,3", 20, 1
        o.cooldown, o.idle_windows, o.idle_seconds, o.sessions, o.group_rest = 5, 1, 5, 1, 3
        o.chain_steps = min(o.chain_steps, 5)
        o.chain_apps = o.chain_apps.split(",")[0]
    apps = (o.apps or default_apps()).split(",")
    run = Run(o)
    chain_apps = [a for a in o.chain_apps.split(",") if a in apps]
    o.chain_apps = ",".join(chain_apps)
    tasks = [] if o.skip_tasks else [TASK_OF_APP[a] for a in apps if a in TASK_OF_APP]
    parts = estimate(o, run, apps, tasks)
    print(f"Run directory: {run.dir}\nApps: {', '.join(apps)}; drivers: {o.drivers}; reps {o.reps}"
          + (" (quick)" if o.quick else "") + f"\nEstimate (rough): {sum(parts.values()):.0f} min  "
          + "; ".join(f"{k} {v:.0f}" for k, v in parts.items()), flush=True)
    if not o.dry_run:
        os.makedirs(run.dir, exist_ok=True)
    try:
        code, blockers = prepare(run, apps, False)
        hard = [b for b in blockers if "is not built at" not in b]
        if hard:
            sys.exit("preflight blockers, nothing was run:\n  " + "\n  ".join(hard))
        build(run)
        code, blockers = prepare(run, apps, True)
        if blockers:
            sys.exit("preflight blockers, nothing was run:\n  " + "\n  ".join(blockers))
        shared = ["--idle-windows", str(o.idle_windows), "--idle-seconds", str(o.idle_seconds)]
        compare(run, "ops", ",".join(apps), ["--mode", "ops", "--reps", str(o.reps), "--sessions", str(o.sessions)] + shared, "ops.jsonl")
        if chain_apps:
            compare(run, "chain", o.chain_apps, ["--mode", "chain", "--pauses", o.pauses, "--chain-steps", str(o.chain_steps),
                                                 "--group-rest", str(o.group_rest)], "chain.jsonl")
        soak_apps = ",".join(a for a in o.soak_apps.split(",") if a in apps)
        if soak_apps:
            compare(run, "soak", soak_apps, ["--mode", "soak", "--soak-steps", str(o.soak_steps)], "soak.jsonl")
        if o.phases:
            env = dict(run.env, MECUM_PHASES_BIN=os.path.join(PHASES_BUILD, "release/mecum-mcp-stdio"))
            run.sh("phases", [PY, "compare.py", "--phases", "--drivers", "mecum", "--apps", "Calculator", "--reps", "4", "--cooldown", str(o.cooldown),
                              "--out", run.path("phases.jsonl"), "--scratch", run.dir], env=env)
        if tasks:
            claude = os.environ.get("CLAUDE_CLI", "/Users/mac/.local/bin/claude")
            if o.dry_run or os.path.exists(claude):
                os.makedirs(run.path("tasks"), exist_ok=True) if not o.dry_run else None
                run.sh("tasks", [PY, "tasks.py", "--out", run.path("tasks.jsonl"), "--scratch", run.path("tasks"), "--tasks", ",".join(tasks),
                                 "--reps", str(o.task_reps), "--drivers", o.drivers, "--max-minutes", str(o.task_max_minutes)])
            else:
                print(f"    model tasks skipped: {claude} not found", flush=True)
        finish(run, apps)
    finally:
        if not o.dry_run:
            end_launched(run)
        print(f"Elapsed: {(time.time() - run.started) / 60:.1f} min" + (f"; phases that failed: {', '.join(run.failed)}" if run.failed else ""), flush=True)
    sys.exit(1 if run.failed else 0)


def finish(run, apps):
    o = run.o
    present = lambda n: os.path.exists(run.path(n))  # noqa: E731
    raw = [n for n in ("ops.jsonl", "chain.jsonl", "soak.jsonl", "phases.jsonl") if present(n) or o.dry_run]
    if not raw:
        print("no raw rows: nothing to summarize", flush=True)
        return
    summary = run.path("summary.json")
    print(f"[{time.strftime('%H:%M:%S')}] summarize: summarize.py {' '.join(raw)} --json summary.json > tables.md", flush=True)
    if not o.dry_run:
        with open(run.path("tables.md"), "w") as out:
            subprocess.run([PY, "summarize.py"] + [run.path(n) for n in raw] + ["--json", summary], cwd=HERE, stdout=out, env=run.env)
    tasks_summary = None
    if present("tasks.jsonl") or (o.dry_run and not o.skip_tasks):
        tasks_summary = run.path("tasks-summary.json")
        run.sh("tasks-summary", [PY, "tasks.py", "--summary", tasks_summary, run.path("tasks.jsonl")])
    info = dict(started=time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(run.started)), finished=time.strftime("%Y-%m-%dT%H:%M:%S"),
                elapsed_s=round(time.time() - run.started), argv=sys.argv[1:], apps=apps, steps=run.steps, failed=run.failed)
    if not o.dry_run:
        json.dump(info, open(run.path("run.json"), "w"), indent=1)
    argv = [PY, "report.py", "--summary", summary, "--run", run.path("run.json"), "--out-dir", o.out_dir]
    if tasks_summary and (present("tasks-summary.json") or o.dry_run):
        argv += ["--tasks", tasks_summary]
    if present("phases.jsonl.phases.txt"):
        argv += ["--phases-txt", run.path("phases.jsonl.phases.txt")]
    run.sh("report", argv)


if __name__ == "__main__":
    main()
