"""Preflight, fixtures and the meta row of a run.

    python3 prepare.py --scratch DIR [--open TextEdit,Calculator,Google\\ Chrome,Safari] [--apps ...] [--plan]

Reads the state that would make a run unfair (Stage Manager, another Mecum, power, thermal state,
displays, permissions), optionally opens target apps in the background (`open -g`) with their fixtures,
waits until each has a usable window, and writes `fixtures.json` (pid, window title and whether this
script launched it, per app) and `meta.json` into DIR. `--plan` prints what --open would do and opens
nothing. It never changes a system setting and never stops a process: anything wrong is reported under
`blockers` and `warnings`.
"""
import argparse, glob, json, os, re, shlex, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
PROBE = os.path.join(HERE, ".build/probe")
DESK = os.path.join(HERE, ".build/desk")
CUA = os.environ.get("CUA_DRIVER", os.path.expanduser(
    "~/Forte_Projects/_bench/cua/libs/cua-driver/rust/target/release/cua-driver"))
MECUM = os.environ.get("MECUM_BIN", os.path.join(HERE, ".build/release/mecum-mcp-stdio"))
FIXTURES = os.path.join(HERE, "fixtures")
# Every target: the process the harness binds to (`prefix`: by name prefix, as Photoshop carries its year) and the
# seconds to wait for a usable window. Resolve and Photoshop are slow; `settle` waits for their window list to hold still.
TARGETS = {
    "Calculator": dict(process="Calculator", wait=30),
    "TextEdit": dict(process="TextEdit", wait=30),
    "Google Chrome": dict(process="Google Chrome", wait=60),
    "Safari": dict(process="Safari", wait=60),
    "Obsidian": dict(process="Obsidian", wait=120),
    "Stocks": dict(process="Stocks", wait=45),
    "kitty": dict(process="kitty", wait=30),
    "DaVinci Resolve": dict(process="Resolve", wait=420, settle=True),
    "Prism Launcher": dict(process="prismlauncher", wait=60),
    "Photoshop": dict(process="Adobe Photoshop", prefix=True, wait=420, settle=True),
}
BENCH_PAGE = "file://" + os.path.join(FIXTURES, "bench.html")
OBSIDIAN_CONFIG = os.path.expanduser("~/Library/Application Support/obsidian/obsidian.json")
CLAUDE = os.environ.get("CLAUDE_CLI", os.path.expanduser("~/.local/bin/claude"))


def sh(*argv, cwd=None):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=20, cwd=cwd).stdout.strip()
    except Exception:
        return ""


def processes():
    """[(pid, ppid, executable basename)] for every process."""
    out = []
    for line in sh("ps", "-axo", "pid=,ppid=,comm=").splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit():
            out.append((int(parts[0]), int(parts[1]), os.path.basename(parts[2])))
    return out


def process_pid(name, prefix=False):
    """Lowest pid whose executable is `name` (or starts with it); None when not running."""
    found = [pid for pid, _, comm in processes() if comm.startswith(name) and (prefix or comm == name)]
    return min(found) if found else None


def front_app():
    """(pid, bundle path) of the frontmost application, from LaunchServices; (None, None) when unknown."""
    try:
        asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=5).stdout.strip()
        info = subprocess.run(["lsappinfo", "info", "-only", "pid", "-only", "bundlepath", asn],
                              capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None, None
    pid, path = re.search(r'pid"?\s*=\s*(\d+)', info), re.search(r'bundle ?path"?\s*=\s*"([^"]+)"', info)
    return (int(pid.group(1)) if pid else None), (path.group(1) if path else None)


def home_front(target_names):
    """The application to keep in front between drivers: the one in front now, or Finder when that is a target."""
    home = front_app()
    if home[1] is None or any(os.path.basename(home[1]).startswith(n) for n in target_names):
        return process_pid("Finder"), "/System/Library/CoreServices/Finder.app"
    return home


def restore_front(home):
    """Brings back the application that was in front when the run started, as the person left it.
    A driver that leaves its target active (a menu that raises the window, for example) would otherwise
    change the starting state of the next driver. Returns the (pid, bundle path) that was in front before."""
    before = front_app()
    if home and home[1] and before[0] != home[0]:
        subprocess.run(["open", "-a", home[1]], check=False)
        time.sleep(1)
    return before


def process_name(prefix):
    """The full executable name of the first process starting with `prefix`, e.g. the Photoshop year."""
    for pid, _, comm in sorted(processes()):
        if comm.startswith(prefix):
            return comm
    return None


def probe(pid):
    try:
        return json.loads(subprocess.run([PROBE, str(pid)], capture_output=True, text=True, timeout=10).stdout)
    except Exception:
        return {}


def machine():
    system = {}
    try:
        system = json.loads(subprocess.run([PROBE, "--system"], capture_output=True, text=True, timeout=10).stdout)
    except Exception:
        pass
    return {"model": sh("sysctl", "-n", "hw.model"), "chip": sh("sysctl", "-n", "machdep.cpu.brand_string"),
            "ram_gb": round(int(sh("sysctl", "-n", "hw.memsize") or 0) / 2**30, 1),
            "cores": system.get("cores"),
            "macos": sh("sw_vers", "-productVersion"), "build": sh("sw_vers", "-buildVersion"),
            "thermal_state": system.get("thermalState"), "low_power_mode": system.get("lowPowerMode"),
            "displays": system.get("displays")}


def power():
    text = sh("pmset", "-g", "ps")
    source = re.search(r"Now drawing from '([^']+)'", text)
    percent = re.search(r"(\d+)%", text)
    return {"source": source.group(1) if source else None, "battery_percent": int(percent.group(1)) if percent else None}


def stage_manager():
    value = sh("defaults", "read", "com.apple.WindowManager", "GloballyEnabled")
    return int(value) if value.isdigit() else None


def other_mecum():
    """Mecum processes that are not this run's own children. Reported, never stopped."""
    table = processes()
    parent = {pid: ppid for pid, ppid, _ in table}
    mine = set()
    for pid, _, _ in table:
        at = pid
        while at > 1 and at not in mine:
            if at == os.getpid():
                mine.add(pid)
                break
            at = parent.get(at, 0)
    return [f"{pid} {comm}" for pid, _, comm in table
            if "mecum" in comm.lower() and pid not in mine and pid != os.getpid()]


def drivers():
    status = sh("git", "status", "--porcelain", "--", "Sources", "Package.swift", "Tools/Driver/CUAComparison/Server",
                cwd=REPO).splitlines()
    cua_root = os.path.abspath(os.path.join(os.path.dirname(CUA), "../../../.."))
    binary_time = lambda path: time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(os.path.getmtime(path))) \
        if os.path.exists(path) else None
    return {"mecum": {"commit": sh("git", "rev-parse", "--short", "HEAD", cwd=REPO), "dirty_files": len(status),
                      "binary": MECUM, "binary_built": binary_time(MECUM)},
            "cua": {"version": sh(CUA, "--version"), "commit": sh("git", "rev-parse", "--short", "HEAD", cwd=cua_root),
                    "binary": CUA, "binary_built": binary_time(CUA),
                    "app_daemon_installed": os.path.isdir("/Applications/CuaDriver.app")}}


def preflight():
    state = {"stage_manager": stage_manager(), "other_mecum": other_mecum(), "power": power(), "machine": machine()}
    blockers, warnings = [], []
    if state["stage_manager"] != 0:
        blockers.append(f"Stage Manager is not off (GloballyEnabled={state['stage_manager']})")
    if state["other_mecum"]:
        blockers.append("another Mecum is running: " + ", ".join(state["other_mecum"]))
    if state["power"]["source"] != "AC Power":
        warnings.append(f"power source is {state['power']['source']}")
    if state["machine"]["low_power_mode"]:
        warnings.append("Low Power mode is on")
    if state["machine"]["thermal_state"] not in (None, "nominal"):
        warnings.append(f"thermal state is {state['machine']['thermal_state']}")
    grants = permissions()
    for key, label in (("accessibility", "Accessibility"), ("screenRecording", "Screen Recording")):
        if grants is not None and not grants.get(key):
            blockers.append(f"{label} permission is missing for the terminal that runs the benchmark")
    for tool, path in (("probe", PROBE), ("mecum-mcp-stdio", MECUM), ("cua-driver", CUA)):
        if not os.path.exists(path):
            blockers.append(f"{tool} is not built at {path}")
    return dict(state, blockers=blockers, warnings=warnings)


def permissions():
    """{"accessibility": bool, "screenRecording": bool} as the terminal chain grants them to child binaries; None when unreadable."""
    try:
        return json.loads(subprocess.run([DESK, "permissions"], capture_output=True, text=True, timeout=10).stdout)
    except Exception:
        return None


def claude_state():
    """'missing', 'logged out' or 'ok' for the Claude CLI the task phase drives."""
    if not os.path.exists(CLAUDE):
        return "missing"
    try:
        status = json.loads(subprocess.run([CLAUDE, "auth", "status"], capture_output=True, text=True, timeout=30).stdout)
    except Exception:
        return "logged out"
    return "ok" if status.get("loggedIn") else "logged out"


def human_blockers(need_claude=True):
    """[(key, Italian text with the exact fix)] for what only a person can change. Nothing is changed or killed here."""
    out = []
    if stage_manager() != 0:
        out.append(("stage-manager", "Stage Manager è acceso: spegnilo da Centro di Controllo (Stage Manager)."))
    mecums = other_mecum()
    if mecums:
        out.append(("mecum", f"Mecum è in esecuzione ({', '.join(mecums)}) e tiene il display virtuale: chiudilo con Mecum > Esci (⌘Q)."))
    grants = permissions()
    for key, label in (("accessibility", "Accessibilità"), ("screenRecording", "Registrazione schermo")):
        if grants is not None and not grants.get(key):
            out.append((key, f"Manca il permesso {label} per il terminale da cui lanci bench.sh (lo ereditano probe, Mecum e Cua): "
                             f"Impostazioni di Sistema > Privacy e sicurezza > {label}, attivalo per il terminale e riaprilo."))
    if need_claude:
        state = claude_state()
        if state == "missing":
            out.append(("claude", f"La CLI claude non c'è in {CLAUDE}: installala, oppure imposta CLAUDE_CLI, oppure lancia con --skip-tasks."))
        elif state == "logged out":
            out.append(("claude", "La CLI claude non è autenticata: esegui `claude auth login` in un terminale."))
    return out


def on_battery():
    return power()["source"] == "Battery Power"


def meta():
    return dict(preflight(), drivers=drivers())


def window_titles(pid):
    return [w.get("title", "") for w in probe(pid).get("axWindows", [])]


def wait_for(find, seconds=12):
    end = time.time() + seconds
    while time.time() < end:
        found = find()
        if found:
            return found
        time.sleep(0.5)
    return None


def chrome_profile(scratch):
    return os.path.join(scratch, "chrome-profile")


def target_pid(app, scratch):
    """Pid of the target; Chrome is the instance started on this run's own profile."""
    t = TARGETS[app]
    if app == "Google Chrome":
        mark = "user-data-dir=" + chrome_profile(scratch)
        return next((p for p, _, c in sorted(processes()) if c == t["process"] and mark in sh("ps", "-o", "args=", "-p", str(p))), None)
    return process_pid(t["process"], prefix=t.get("prefix", False))


def bundle_name(app):
    """The name `open -a` takes; Photoshop carries its year."""
    if app == "Photoshop":
        found = sorted(glob.glob("/Applications/Adobe Photoshop*/Adobe Photoshop*.app"))
        return os.path.basename(found[-1])[:-4] if found else "Adobe Photoshop 2026"
    return app


def obsidian_vault(scratch):
    """(vault path, scratch) of the vault Obsidian shows: the one it has open (the vault of the 6 October run),
    else a scratch vault inside the run directory."""
    try:
        vaults = list(json.load(open(OBSIDIAN_CONFIG)).get("vaults", {}).values())
        path = next((v["path"] for v in vaults if v.get("open")), vaults[0]["path"] if vaults else None)
    except Exception:
        path = None
    if path and os.path.isdir(path):
        return path, False
    return os.path.join(scratch, "obsidian-vault"), True


def open_steps(app, scratch, stamp):
    """[(what, argv)] that open one app in the background on its fixture, in order; the single source of the plan and of the run."""
    name, open_a = bundle_name(app), ["open", "-g", "-a", bundle_name(app)]
    if app == "TextEdit":
        return [("fresh copy of bench.txt, opened in its own window", open_a + [os.path.join(scratch, f"bench-{stamp}.txt")])]
    if app == "Google Chrome":
        return [("own profile, a window titled Bench Page", ["open", "-g", "-n", "-a", name, "--args", f"--user-data-dir={chrome_profile(scratch)}",
                                                              "--no-first-run", "--no-default-browser-check",
                                                              # A fresh profile builds the page's accessibility tree only on
                                                              # demand; both drivers read the page through it.
                                                              "--force-renderer-accessibility", "--new-window", BENCH_PAGE])]
    if app == "Safari":
        return [("if Safari already runs: AXPress File > New Window first (no activation)", [DESK, "press", "<pid>", "File", "New Window"]),
                ("bench page, a window whose title ends with Bench Page", open_a + [BENCH_PAGE]),
                ("fallback when no such window appeared: New Window again, then the page", open_a + [BENCH_PAGE])]
    if app == "Obsidian":
        vault, scratch_vault = obsidian_vault(scratch)
        if scratch_vault:
            return [(f"scratch vault {vault}", ["open", "-g", "obsidian://open?path=" + vault])]
        return [(f"the open vault {vault}", open_a)]
    if app == "DaVinci Resolve":
        return [("Project Manager (what Resolve shows with no project loaded)", open_a)]
    if app == "Photoshop":
        return [("Home screen, no document (it cannot save)", open_a)]
    return [("", open_a)]


def plan(apps, scratch):
    """Printable open/wait plan, nothing opened."""
    lines = []
    for app in apps:
        t = TARGETS[app]
        rule = ("a window whose title ends with Bench Page" if app == "Safari" else "a window whose title has Bench Page" if app == "Google Chrome"
                else "a usable window")
        lines.append(f"{app}: wait up to {t['wait']} s for {rule}" + (" and for its window list to hold still" if t.get("settle") else "")
                     + "; quit at the end only if this run launched it, by pid")
        for what, argv in open_steps(app, scratch, "<time>"):
            lines.append(f"    {what + ': ' if what else ''}{shlex.join(argv)}")
    return lines


def usable(pid, need_ax=False):
    """Titles of the target's windows once it has one a person could use (an AX window, or a real-sized window;
    slow apps show a splash that is only the second, so they need an AX window)."""
    shot = probe(pid)
    titles = [w.get("title", "") for w in shot.get("axWindows", [])]
    big = [w for w in shot.get("windows", []) if w.get("w", 0) >= 100 and w.get("h", 0) >= 100]
    return titles if titles or (big and not need_ax) else None


def ready(app, pid, scratch, window, ends=False):
    """Waits for a usable window (and, with a title wanted, one that has it); returns (titles, seconds waited)."""
    t, start, last = TARGETS[app], time.time(), None
    while time.time() - start < t["wait"]:
        titles = usable(pid, t.get("settle", False))
        if titles is not None and (window is None or any((x.endswith(window) if ends else window in x) for x in titles)):
            if not t.get("settle") or titles == last:
                return titles, round(time.time() - start)
            last = titles
        time.sleep(2 if t.get("settle") else 0.5)
    return usable(pid, t.get("settle", False)), round(time.time() - start)


def open_fixtures(apps, scratch):
    """Opens each app in the background on its fixture and waits for it; {app: {pid, window, already_running, launched, note, ...}}."""
    out, stamp = {}, int(time.time())
    for app in apps:
        t, window, ends, note = TARGETS[app], None, False, ""
        before = target_pid(app, scratch)
        steps = open_steps(app, scratch, stamp)
        if app == "TextEdit":
            copy = os.path.join(scratch, f"bench-{stamp}.txt")
            shutil.copy(os.path.join(FIXTURES, "bench.txt"), copy)
            window = os.path.basename(copy)
        elif app in ("Google Chrome", "Safari"):
            window, ends = "Bench Page", app == "Safari"
        elif app == "Obsidian" and obsidian_vault(scratch)[1]:
            os.makedirs(os.path.join(obsidian_vault(scratch)[0], ".obsidian"), exist_ok=True)
            open(os.path.join(obsidian_vault(scratch)[0], "Welcome.md"), "w").write("Benchmark scratch vault.\n")
        print(f"[open] {app}", flush=True)
        if app == "Safari":
            pid, note = open_safari(steps, before)
        else:
            if not (app == "Obsidian" and before):  # an Obsidian already running keeps its vault
                subprocess.run(steps[0][1], capture_output=True)
            pid = wait_for(lambda: target_pid(app, scratch), 30)
        titles, waited = ready(app, pid, scratch, window, ends) if pid else (None, 0)
        if not pid:
            note = note or "did not start"
        elif titles is None:
            note = note or f"no usable window after {waited} s"
        elif window and not any((x.endswith(window) if ends else window in x) for x in titles):
            note = note or f"no window titled like {window!r} after {waited} s; open the fixture in its own window"
        elif app == "DaVinci Resolve" and not any("Project Manager" in x for x in titles):
            note = f"Resolve is not on its Project Manager (windows {titles}): the view toggles will fail"
        elif window and titles:
            window = next(x for x in titles if (x.endswith(window) if ends else window in x))
        out[app] = {"pid": pid, "window": window, "already_running": before is not None, "launched": before is None and pid is not None,
                    "note": note, "ready_s": waited, "titles": titles}
        print(f"    pid {pid}, ready in {waited} s" + (f", NOTE: {note}" if note else ""), flush=True)
    return out


def open_safari(steps, before):
    """(pid, note): Safari on the bench page in a window of its own. A running Safari gets a new window through AXPress
    first, so the page cannot land in the person's window; the same is the fallback when open -g reused a window."""
    page, pid, note = steps[1][1], before, ""

    def new_window():
        count = len(window_titles(pid)) if pid else 0
        subprocess.run([DESK, "press", str(pid), "File", "New Window"], capture_output=True)
        return wait_for(lambda: len(window_titles(pid)) > count, 10)

    if before and not new_window():
        note = "File > New Window added no window"
    subprocess.run(page, capture_output=True)
    pid = wait_for(lambda: process_pid("Safari"), 30)
    if pid and not wait_for(lambda: any(x.endswith("Bench Page") for x in window_titles(pid)), 15):
        if new_window():
            subprocess.run(page, capture_output=True)
        else:
            note = note or "no window titled like 'Bench Page' and File > New Window added none"
    return pid, note


def status(apps):
    """Which target processes are running, with their window titles."""
    out = {}
    for app in apps:
        t = TARGETS[app]
        pid = process_pid(t["process"], prefix=t.get("prefix", False))
        out[app] = {"pid": pid, "process": process_name(t["process"]) if t.get("prefix") else t["process"],
                    "windows": window_titles(pid) if pid else []}
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scratch", required=True)
    parser.add_argument("--open", default="", help="apps to open in the background on their fixtures")
    parser.add_argument("--apps", default="", help="apps to report on (default: the opened ones)")
    parser.add_argument("--plan", action="store_true", help="print the open/wait plan of --open and exit; opens nothing")
    options = parser.parse_args()
    opened = [a for a in options.open.split(",") if a]
    if options.plan:
        return print("\n".join(plan(opened, options.scratch)))
    os.makedirs(options.scratch, exist_ok=True)
    fixtures = open_fixtures(opened, options.scratch) if opened else {}
    report = meta()
    report["targets"] = status([a for a in options.apps.split(",") if a] or opened)
    with open(os.path.join(options.scratch, "fixtures.json"), "w") as out:
        json.dump(fixtures, out, indent=1)
    with open(os.path.join(options.scratch, "meta.json"), "w") as out:
        json.dump(report, out, indent=1)
    print(json.dumps(dict(report, fixtures=fixtures), indent=1))
    sys.exit(3 if report["blockers"] else 0)


if __name__ == "__main__":
    main()
