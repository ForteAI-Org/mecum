"""Preflight, fixtures and the meta row of a run.

    python3 prepare.py --scratch DIR [--open TextEdit,Calculator,Google\\ Chrome,Safari] [--apps ...]

Reads the state that would make a run unfair (Stage Manager, another Mecum, power, thermal state,
displays), optionally opens target apps in the background with their fixtures, and writes
`fixtures.json` (pid and window title per app) and `meta.json` into DIR. It never changes a system
setting and never stops a process: anything wrong is reported under `blockers` and `warnings`.
"""
import argparse, json, os, plistlib, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "../../.."))
PROBE = os.path.join(HERE, ".build/probe")
CUA = os.environ.get("CUA_DRIVER", os.path.expanduser(
    "~/Forte_Projects/_bench/cua/libs/cua-driver/rust/target/release/cua-driver"))
MECUM = os.environ.get("MECUM_BIN", os.path.join(HERE, ".build/release/mecum-mcp-stdio"))
FIXTURES = os.path.join(HERE, "fixtures")
# App name for `open -a`, and the process name the harness binds to.
LAUNCHABLE = {"Calculator": "Calculator", "TextEdit": "TextEdit", "Google Chrome": "Google Chrome", "Safari": "Safari",
              "Stocks": "Stocks", "Obsidian": "Obsidian", "kitty": "kitty", "Prism Launcher": "prismlauncher"}
# Checked only: they need a project or document state a launch cannot give them.
CHECK_ONLY = {"DaVinci Resolve": "Resolve", "Photoshop": "Adobe Photoshop"}


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
    for tool, path in (("probe", PROBE), ("mecum-mcp-stdio", MECUM), ("cua-driver", CUA)):
        if not os.path.exists(path):
            blockers.append(f"{tool} is not built at {path}")
    return dict(state, blockers=blockers, warnings=warnings)


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


def open_fixtures(apps, scratch):
    """Opens each app in the background on its fixture; {app: {pid, window, note}}."""
    out = {}
    for app in apps:
        process = LAUNCHABLE[app]
        note, window, args = "", None, ["open", "-g", "-a", app]
        if app == "TextEdit":
            copy = os.path.join(scratch, f"bench-{int(time.time())}.txt")
            shutil.copy(os.path.join(FIXTURES, "bench.txt"), copy)
            window, args = os.path.basename(copy), args + [copy]
        elif app == "Google Chrome":
            profile = os.path.join(scratch, "chrome-profile")
            args = ["open", "-g", "-n", "-a", app, "--args", f"--user-data-dir={profile}", "--no-first-run",
                    "--no-default-browser-check", "--new-window", "file://" + os.path.join(FIXTURES, "bench.html")]
            window = "Bench Page"
        elif app == "Safari":
            args += ["file://" + os.path.join(FIXTURES, "bench.html")]
            window = "Bench Page"
        before = process_pid(process)
        subprocess.run(args, capture_output=True)
        if app == "Google Chrome":
            pid = wait_for(lambda: next((p for p, _, c in sorted(processes()) if c == process
                                         and "user-data-dir=" + os.path.join(scratch, "chrome-profile")
                                         in sh("ps", "-o", "args=", "-p", str(p))), None))
        else:
            pid = wait_for(lambda: process_pid(process))
        titles = wait_for(lambda: [t for t in window_titles(pid) if window is None or window in t]) if pid else None
        if pid and window and not titles:
            note = f"no window titled like {window!r} after 12 s; open the fixture in its own window"
        elif titles and window:
            window = titles[0]
        out[app] = {"pid": pid, "window": window, "already_running": before is not None, "note": note}
    return out


def status(apps):
    """Which target processes are running, with their window titles."""
    out = {}
    for app in apps:
        process = LAUNCHABLE.get(app) or CHECK_ONLY.get(app)
        pid = process_pid(process, prefix=app in CHECK_ONLY)
        out[app] = {"pid": pid, "process": process_name(process) if app in CHECK_ONLY else process,
                    "windows": window_titles(pid) if pid else []}
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scratch", required=True)
    parser.add_argument("--open", default="", help="apps to open in the background on their fixtures")
    parser.add_argument("--apps", default="", help="apps to report on (default: the opened ones)")
    options = parser.parse_args()
    os.makedirs(options.scratch, exist_ok=True)
    opened = [a for a in options.open.split(",") if a]
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
