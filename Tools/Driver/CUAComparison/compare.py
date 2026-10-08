"""Mecum vs Cua Driver: the same operations on the same windows, through the same MCP stdio client.

    python3 compare.py --apps Calculator,TextEdit --reps 8 --out results.jsonl

Every call is one JSONL row: wall time at the client, reply size and estimated model tokens, CPU,
instructions and energy of the driver and of the target application, WindowServer CPU, and what an
independent probe saw around the call (frontmost app, physical cursor, target windows, AX values).
"""
import argparse, json, math, os, subprocess, sys, time
from mcpclient import MCPClient
import rusage

HERE = os.path.dirname(os.path.abspath(__file__))
CUA = os.environ.get("CUA_DRIVER", os.path.expanduser(
    "~/Forte_Projects/_bench/cua/libs/cua-driver/rust/target/release/cua-driver"))
MECUM = os.path.join(HERE, ".build/release/mecum-mcp-stdio")
PROBE = os.path.join(HERE, ".build/probe")

# One operation: a name, then what each driver calls. A cua argument {"label": ..} is resolved to the
# element_token of the latest get_window_state; {"at": (fx, fy)} to window-local screenshot pixels.
SCENARIOS = {
    "Calculator": dict(framework="SwiftUI", process="Calculator", ops=[
        ("click", ("act", {"target": "7"}), ("click", {"label": "7", "role": "AXButton"})),
        ("key", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"})),
        ("menu", ("menu", {"path": "View > Basic"}), ("invoke_menu", {"path": ["View", "Basic"]})),
    ]),
    "TextEdit": dict(framework="AppKit", process="TextEdit", ops=[
        # The insert opens a new line below line two, so the click's label never changes between reps.
        ("click", ("act", {"target": "Line two."}), ("click", {"at": (0.06, 0.115)})),
        ("hotkey", ("press_key", {"key": "right", "modifiers": ["cmd"]}), ("hotkey", {"keys": ["cmd", "right"]})),
        ("type", ("insert_text", {"text": "\nbench"}), ("type_text", {"text": "\nbench"})),
        ("key", ("press_key", {"key": "left"}), ("press_key", {"key": "left"})),
        ("scroll_down", ("scroll", {"direction": "down", "lines": 3}), ("scroll", {"direction": "down", "amount": 3})),
        ("scroll_up", ("scroll", {"direction": "up", "lines": 3}), ("scroll", {"direction": "up", "amount": 3})),
        ("menu", ("menu", {"path": "Edit > Select All"}), ("invoke_menu", {"path": ["Edit", "Select All"]})),
    ]),
    "Google Chrome": dict(framework="Chromium", process="Google Chrome", ops=[
        ("click", ("act", {"target": "Press me"}), ("click", {"label": "Press me", "role": "AXButton"})),
        ("type", ("type_text", {"target": "Name", "text": "hello"}),
                 ("type_text", {"label": "Name", "role": "AXTextField", "text": "hello"})),
        ("key", ("press_key", {"key": "tab"}), ("press_key", {"key": "tab"})),
        ("hotkey", ("press_key", {"key": "tab", "modifiers": ["shift"]}), ("hotkey", {"keys": ["shift", "tab"]})),
        ("scroll_down", ("scroll", {"direction": "down", "lines": 3}), ("scroll", {"direction": "down", "amount": 3})),
        ("scroll_up", ("scroll", {"direction": "up", "lines": 3}), ("scroll", {"direction": "up", "amount": 3})),
        ("menu", ("menu", {"path": "View > Always Show Bookmarks Bar"}),
                 ("invoke_menu", {"path": ["View", "Always Show Bookmarks Bar"]})),
    ]),
    "Prism Launcher": dict(framework="Qt 6", process="prismlauncher", ops=[
        ("click", ("act", {"target": "Meow"}), ("click", {"label": "Meow", "role": "AXCheckBox"})),
        ("key", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"})),
    ]),
    "kitty": dict(framework="OpenGL (GLFW)", process="kitty", ops=[
        ("type", ("insert_text", {"text": "echo bench"}), ("type_text", {"text": "echo bench"})),
        ("hotkey", ("press_key", {"key": "u", "modifiers": ["ctrl"]}), ("hotkey", {"keys": ["ctrl", "u"]})),
        ("key", ("press_key", {"key": "left"}), ("press_key", {"key": "left"})),
        ("scroll_up", ("scroll", {"direction": "up", "lines": 3}), ("scroll", {"direction": "up", "amount": 3})),
        ("scroll_down", ("scroll", {"direction": "down", "lines": 3}), ("scroll", {"direction": "down", "amount": 3})),
    ]),
    "Safari": dict(framework="WebKit (Safari)", process="Safari", window="Personal — Bench Page", ops=[
        ("click", ("act", {"target": "Press me"}), ("click", {"label": "Press me", "role": "AXButton"})),
        ("type", ("type_text", {"target": "Name", "text": "hello"}),
                 ("type_text", {"label": "Name", "role": "AXTextField", "text": "hello"})),
        ("key", ("press_key", {"key": "tab"}), ("press_key", {"key": "tab"})),
        ("hotkey", ("press_key", {"key": "tab", "modifiers": ["shift"]}), ("hotkey", {"keys": ["shift", "tab"]})),
        ("scroll_down", ("scroll", {"direction": "down", "lines": 3}), ("scroll", {"direction": "down", "amount": 3})),
        ("scroll_up", ("scroll", {"direction": "up", "lines": 3}), ("scroll", {"direction": "up", "amount": 3})),
        # Zoom in, then back to actual size, so each item is enabled when it is pressed.
        ("menu", ("menu", {"path": "View > Zoom In"}), ("invoke_menu", {"path": ["View", "Zoom In"]})),
        ("menu_back", ("menu", {"path": "View > Actual Size"}), ("invoke_menu", {"path": ["View", "Actual Size"]})),
    ]),
    "Stocks": dict(framework="Mac Catalyst", process="Stocks", window="Stocks", ops=[
        ("key", ("press_key", {"key": "tab"}), ("press_key", {"key": "tab"})),
        ("scroll_down", ("scroll", {"direction": "down", "lines": 3}), ("scroll", {"direction": "down", "amount": 3})),
        ("scroll_up", ("scroll", {"direction": "up", "lines": 3}), ("scroll", {"direction": "up", "amount": 3})),
    ]),
    "Obsidian": dict(framework="Electron", process="Obsidian", ops=[
        ("click", ("act", {"target": "More options"}), ("click", {"label": "More options", "role": "AXButton"})),
        ("key", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"})),
        ("hotkey", ("press_key", {"key": "o", "modifiers": ["cmd"]}), ("hotkey", {"keys": ["cmd", "o"]})),
        ("type", ("insert_text", {"text": "Driver"}), ("type_text", {"text": "Driver"})),
        ("key_close", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"})),
    ]),
    "DaVinci Resolve": dict(framework="Qt + GPU (Resolve)", process="Resolve", ops=[
        ("click", ("act", {"target": "Thumbnail View"}), ("click", {"label": "Thumbnail View", "role": "AXCheckBox"})),
        ("click_back", ("act", {"target": "List View"}), ("click", {"label": "List View", "role": "AXCheckBox"})),
        # No Escape here: it closes the Project Manager, and Resolve quits with no project open.
        ("scroll_down", ("scroll", {"direction": "down", "lines": 3}), ("scroll", {"direction": "down", "amount": 3})),
        ("scroll_up", ("scroll", {"direction": "up", "lines": 3}), ("scroll", {"direction": "up", "amount": 3})),
    ]),
}


def pid_of(process):
    out = subprocess.run(["pgrep", "-x", process], capture_output=True, text=True).stdout.split()
    if not out:
        raise RuntimeError(f"{process} is not running")
    return int(out[0])


def window_server():
    return pid_of("WindowServer")


def probe(pid):
    try:
        return json.loads(subprocess.run([PROBE, str(pid)], capture_output=True, text=True, timeout=10).stdout)
    except Exception as error:
        return {"error": str(error)}


def image_tokens(width, height):
    """Anthropic's image estimate: resized to fit 1568 px and 1.15 MP, then w*h/750."""
    scale = min(1.0, 1568 / max(width, height), math.sqrt(1_150_000 / (width * height)))
    return math.ceil((width * scale) * (height * scale) / 750)


def payload(reply):
    """Bytes on the wire, and what a client that forwards `content` puts in the model's context."""
    result = reply.get("result") or {}
    text = sum(len(item.get("text", "")) for item in result.get("content", []) if item.get("type") == "text")
    images = [item for item in result.get("content", []) if item.get("type") == "image"]
    structured = len(json.dumps(result["structuredContent"])) if "structuredContent" in result else 0
    return text, images, structured


def self_verdict(reply):
    """What the driver itself claims about the effect: Cua's `effect`, Mecum's outcome status."""
    result = reply.get("result") or {}
    structured = result.get("structuredContent") or {}
    if "effect" in structured:
        return structured["effect"] if isinstance(structured["effect"], str) else json.dumps(structured["effect"])[:60]
    texts = " ".join(item.get("text", "") for item in result.get("content", []) if item.get("type") == "text")
    if texts.startswith("{"):
        try:
            body = json.loads(texts)
            return body.get("status") or body.get("outcome", {}).get("status")
        except (ValueError, AttributeError):
            return None
    return None


def failed(reply):
    result = reply.get("result")
    if result is None:
        return reply.get("error", {}).get("message", "protocol error")
    if result.get("isError"):
        return " ".join(item.get("text", "") for item in result.get("content", []))[:300]
    texts = " ".join(item.get("text", "") for item in result.get("content", []) if item.get("type") == "text")
    if texts.startswith("{"):
        try:
            body = json.loads(texts)
            if body.get("status") in ("error", "refused", "failed"):
                return (body.get("message") or body.get("status"))[:300]
        except ValueError:
            pass
    return None


class Recorder:
    def __init__(self, path, meta):
        self.file = open(path, "a")
        self.meta = meta

    def measure(self, client, driver, app, framework, op, rep, name, arguments, target_pid, settle=0.25):
        ws = window_server()
        before_probe = probe(target_pid)
        d0, a0, w0 = rusage.sample(getattr(client, 'driver_pid', client.pid)), rusage.sample(target_pid), rusage.ps_cpu_ns(ws)
        try:
            seconds, size, reply = client.call(name, arguments)
            error = failed(reply)
        except Exception as exception:
            seconds, size, reply, error = float("nan"), 0, {}, f"exception: {exception}"
        d1, a1, w1 = rusage.sample(getattr(client, 'driver_pid', client.pid)), rusage.sample(target_pid), rusage.ps_cpu_ns(ws)
        time.sleep(settle)
        after_probe = probe(target_pid)
        text, images, structured = payload(reply)
        sizes = image_sizes(reply)
        row = dict(self.meta, driver=driver, app=app, framework=framework, op=op, rep=rep, tool=name,
                   ms=seconds * 1000, ok=error is None, error=error, self_verdict=self_verdict(reply), reply_bytes=size, text_chars=text,
                   structured_bytes=structured, images=len(images),
                   image_px=[list(s) for s in sizes if s], image_tokens=sum(image_tokens(*s) for s in sizes if s),
                   driver_cpu_ms=(d1["cpu_ns"] - d0["cpu_ns"]) / 1e6 if d0 and d1 else None,
                   driver_instructions=(d1["instructions"] - d0["instructions"]) if d0 and d1 else None,
                   driver_energy_mj=(d1["energy_nj"] - d0["energy_nj"]) / 1e6 if d0 and d1 else None,
                   driver_footprint_mb=d1["footprint"] / 2**20 if d1 else None,
                   driver_peak_mb=d1["peak_footprint"] / 2**20 if d1 else None,
                   app_cpu_ms=(a1["cpu_ns"] - a0["cpu_ns"]) / 1e6 if a0 and a1 else None,
                   app_energy_mj=(a1["energy_nj"] - a0["energy_nj"]) / 1e6 if a0 and a1 else None,
                   windowserver_cpu_ms=(w1 - w0) / 1e6 if w0 is not None and w1 is not None else None,
                   frontmost_before=before_probe.get("frontmost"), frontmost_after=after_probe.get("frontmost"),
                   cursor_moved=before_probe.get("cursor") != after_probe.get("cursor"),
                   cursor_before=before_probe.get("cursor"), cursor_after=after_probe.get("cursor"),
                   windows_before=before_probe.get("windows"), windows_after=after_probe.get("windows"),
                   effect_seen=before_probe.get("digest") != after_probe.get("digest"),
                   target_pid=target_pid)
        self.file.write(json.dumps(row) + "\n")
        self.file.flush()
        flag = "ok " if row["ok"] else "ERR"
        print(f"  {flag} {driver:5} {app:15} {op:12} r{rep} {row['ms']:8.1f} ms {size:>8} B"
              + ("" if row["ok"] else f"  {error[:120]}"), flush=True)
        return reply


def image_sizes(reply):
    """Each image's pixel size, read from its PNG or JPEG header."""
    import base64, struct
    sizes = []
    for item in (reply.get("result") or {}).get("content", []):
        if item.get("type") != "image":
            continue
        head = base64.b64decode(item["data"][:400] + "=" * (-len(item["data"][:400]) % 4))
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            sizes.append(struct.unpack(">II", head[16:24]))
        else:
            sizes.append(_jpeg_size(base64.b64decode(item["data"])))
    return sizes


def _jpeg_size(data):
    import struct
    i = 2
    while i < len(data):
        marker, length = data[i + 1], struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2):
            height, width = struct.unpack(">HH", data[i + 5:i + 9])
            return width, height
        i += 2 + length
    return None


class Cua:
    """Three launch variants, every other Cua default kept (including its post-action window watch):

    cua          cua-driver mcp --direct: the MCP process owns the runtime, no agent cursor overlay.
    cua-overlay  the daemon-backed path, whose daemon owns the AppKit loop the overlay needs (on by default
                 there). With /Applications/CuaDriver.app installed, a bare `cua-driver mcp` proxies to the
                 daemon the way the README describes. Without it, the harness is the embedding host
                 (Skills/cua-driver/EMBEDDING.md): `serve --embedded` as its own child on a private socket,
                 then `mcp --embedded --socket`. The two cases are recorded in the startup row.
    cua-fast     opt-in floor: CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0 drops the post-action watch.

    Telemetry is off in all three (CUA_DRIVER_RS_TELEMETRY_ENABLED=0). Every call carries a session label."""

    SESSION = "bench"
    APP = "/Applications/CuaDriver.app"

    def __init__(self, recorder, log, variant="cua", scratch=None):
        self.recorder = recorder
        self.name = variant
        self.daemon = None
        env = dict(os.environ, CUA_DRIVER_RS_TELEMETRY_ENABLED="0")
        if variant == "cua-fast":
            env["CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS"] = "0"
        self.launch = "direct"
        started = time.perf_counter()
        if variant == "cua-overlay" and os.path.isdir(self.APP):
            self.launch, argv = "app-daemon", [CUA, "mcp"]
        elif variant == "cua-overlay":
            self.launch = "embedded-daemon"
            socket_path = os.path.join(scratch, "cua.sock")
            embedded = dict(env, CUA_DRIVER_EMBEDDED="1")
            if os.path.exists(socket_path):
                os.remove(socket_path)
            self.daemon = subprocess.Popen([CUA, "serve", "--embedded", "--socket", socket_path],
                                           stdin=subprocess.PIPE, stdout=log, stderr=log, env=embedded)
            deadline = time.time() + 15
            while not os.path.exists(socket_path):
                if self.daemon.poll() is not None or time.time() > deadline:
                    raise RuntimeError("cua-driver serve --embedded did not open its socket")
                time.sleep(0.1)
            env, argv = embedded, [CUA, "mcp", "--embedded", "--socket", socket_path]
        else:
            argv = [CUA, "mcp", "--direct"]
        self.client = MCPClient(argv, stderr=log, env=env)
        # Resource rows read the process that does the work: the daemon, not its stdio proxy.
        self.client.driver_pid = self.daemon.pid if self.daemon else self.client.pid
        self.startup_ms = (time.perf_counter() - started) * 1000
        self.state = None
        self.client.call("start_session", {"session": self.SESSION})

    def close(self):
        try:
            self.client.call("end_session", {"session": self.SESSION})
        except Exception:
            pass
        self.client.close()
        if self.daemon:
            # Our own child only: closing its stdin is the documented stop, terminate by PID if it lingers.
            self.daemon.stdin.close()
            try:
                self.daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.daemon.terminate()

    def bind(self, pid, title=None):
        reply = self.client.call("list_windows", {"pid": pid, "session": self.SESSION})[2]
        windows = [w for w in reply["result"]["structuredContent"]["windows"]
                   if w["bounds"]["width"] > 100 and w["bounds"]["height"] > 100
                   and (title is None or w.get("title") == title)]
        windows.sort(key=lambda w: w.get("z_index", 0), reverse=True)
        if not windows:
            raise RuntimeError(f"no window above 100 px for pid {pid} (Stage Manager stash or minimized?)")
        self.pid, self.window = pid, windows[0]["window_id"]

    def observe(self, app, framework, op, rep):
        reply = self.recorder.measure(self.client, self.name, app, framework, op, rep, "get_window_state",
                                      {"pid": self.pid, "window_id": self.window, "session": self.SESSION}, self.pid)
        self.state = (reply.get("result") or {}).get("structuredContent")
        return reply

    def resolve(self, arguments):
        arguments = dict(arguments)
        label, role, at = arguments.pop("label", None), arguments.pop("role", None), arguments.pop("at", None)
        if label is not None:
            matches = [e for e in self.state["elements"] if e.get("label") == label
                       and (role is None or e.get("role") == role)]
            if not matches:
                raise RuntimeError(f"no element {label!r} {role}")
            arguments["element_token"] = matches[0]["element_token"]
        if at is not None:
            arguments["x"] = round(at[0] * self.state["screenshot_width"])
            arguments["y"] = round(at[1] * self.state["screenshot_height"])
        return dict(arguments, pid=self.pid, window_id=self.window, session=self.SESSION)

    def act(self, app, framework, op, rep, name, arguments):
        if name == "invoke_menu":
            arguments = dict(arguments, pid=self.pid, window_id=self.window, session=self.SESSION)
        else:
            arguments = self.resolve(arguments)
        return self.recorder.measure(self.client, self.name, app, framework, op, rep, name, arguments, self.pid)


class Mecum:
    name = "mecum"

    def __init__(self, recorder, log, knowledge):
        self.recorder = recorder
        env = dict(os.environ, MECUM_BENCH_UNVALIDATED="1")
        started = time.perf_counter()
        self.client = MCPClient([MECUM, knowledge], stderr=log, env=env)
        self.startup_ms = (time.perf_counter() - started) * 1000
        self.session = None

    def open(self, app, framework, rep, pid, window=None):
        arguments = {"app": app} | ({"window": window} if window else {})
        reply = self.recorder.measure(self.client, "mecum", app, framework, "open_session", rep,
                                      "open_session", arguments, pid, settle=0.5)
        text = (reply.get("result") or {}).get("content", [{}])[0].get("text", "{}")
        try:
            self.session = json.loads(text).get("session")
        except ValueError:
            self.session = None
        return self.session

    def close(self, app, framework, rep, pid):
        if self.session:
            self.recorder.measure(self.client, "mecum", app, framework, "close_session", rep,
                                  "close_session", {"session": self.session}, pid, settle=0.5)
        self.session = None

    def observe(self, app, framework, op, rep, pid, full):
        return self.recorder.measure(self.client, "mecum", app, framework, op, rep, "observe",
                                     {"session": self.session} | ({"full": True} if full else {}), pid)

    def act(self, app, framework, op, rep, name, arguments, pid):
        return self.recorder.measure(self.client, "mecum", app, framework, op, rep, name,
                                     dict(arguments, session=self.session), pid)


def idle(recorder, client, driver, app, framework, pid, seconds):
    """CPU and energy the driver and WindowServer spend while nothing is asked."""
    ws = window_server()
    d0, w0 = rusage.sample(getattr(client, 'driver_pid', client.pid)), rusage.ps_cpu_ns(ws)
    time.sleep(seconds)
    d1, w1 = rusage.sample(getattr(client, 'driver_pid', client.pid)), rusage.ps_cpu_ns(ws)
    row = dict(recorder.meta, driver=driver, app=app, framework=framework, op="idle", rep=0, tool=None,
               ms=seconds * 1000, ok=True, driver_cpu_ms=(d1["cpu_ns"] - d0["cpu_ns"]) / 1e6,
               driver_energy_mj=(d1["energy_nj"] - d0["energy_nj"]) / 1e6,
               driver_wakeups=d1["wakeups"] - d0["wakeups"], driver_footprint_mb=d1["footprint"] / 2**20,
               windowserver_cpu_ms=(w1 - w0) / 1e6)
    recorder.file.write(json.dumps(row) + "\n")
    recorder.file.flush()
    print(f"  idle  {driver:5} {app:15} {seconds}s cpu {row['driver_cpu_ms']:.1f} ms  WS {row['windowserver_cpu_ms']:.0f} ms")


def baseline(recorder, seconds):
    """WindowServer with no driver running, the floor every idle row is read against."""
    ws = window_server()
    w0 = rusage.ps_cpu_ns(ws)
    time.sleep(seconds)
    row = dict(recorder.meta, driver="none", op="baseline", ms=seconds * 1000, ok=True,
               windowserver_cpu_ms=(rusage.ps_cpu_ns(ws) - w0) / 1e6)
    recorder.file.write(json.dumps(row) + "\n")
    print(f"  baseline {seconds}s WS {row['windowserver_cpu_ms']:.0f} ms")


def run_cua(recorder, apps, reps, log, variant, scratch):
    cua = Cua(recorder, log, variant, scratch)
    recorder.file.write(json.dumps(dict(recorder.meta, driver=cua.name, op="startup", ms=cua.startup_ms, ok=True,
                                        launch=cua.launch)) + "\n")
    try:
        for app in apps:
            scenario = SCENARIOS[app]
            pid = pid_of(scenario["process"])
            try:
                cua.bind(pid, scenario.get("window"))
            except RuntimeError as error:
                print(f"  ERR {cua.name} {app}: {error}")
                continue
            framework = scenario["framework"]
            recorder.measure(cua.client, cua.name, app, framework, "list_windows", 0, "list_windows",
                             {"pid": pid, "session": cua.SESSION}, pid)
            for rep in range(reps + 1):
                cua.observe(app, framework, "observe", rep)
                for op, _, (name, arguments) in scenario["ops"]:
                    try:
                        cua.act(app, framework, op, rep, name, arguments)
                    except Exception as error:
                        print(f"  ERR {cua.name} {app} {op}: {error}")
                    cua.observe(app, framework, "observe_after", rep)
            idle(recorder, cua.client, cua.name, app, framework, pid, 10)
    finally:
        cua.close()


def run_mecum(recorder, apps, reps, log, knowledge, sessions):
    mecum = Mecum(recorder, log, knowledge)
    recorder.file.write(json.dumps(dict(recorder.meta, driver="mecum", op="startup", ms=mecum.startup_ms, ok=True)) + "\n")
    for app in apps:
        scenario = SCENARIOS[app]
        pid = pid_of(scenario["process"])
        framework = scenario["framework"]
        recorder.measure(mecum.client, "mecum", app, framework, "list_windows", 0, "windows", {"app": app}, pid)
        if not mecum.open(app, framework, 0, pid, scenario.get("window")):
            continue
        for rep in range(reps + 1):
            mecum.observe(app, framework, "observe", rep, pid, full=True)
            mecum.observe(app, framework, "observe_unchanged", rep, pid, full=False)
            for op, (name, arguments), _ in scenario["ops"]:
                mecum.act(app, framework, op, rep, name, arguments, pid)
        idle(recorder, mecum.client, "mecum", app, framework, pid, 10)
        mecum.close(app, framework, 0, pid)
        for rep in range(1, sessions + 1):
            if mecum.open(app, framework, rep, pid, scenario.get("window")):
                mecum.close(app, framework, rep, pid)
    mecum.client.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apps", default=",".join(SCENARIOS))
    parser.add_argument("--drivers", default="cua,mecum", help="mecum, cua, cua-overlay, cua-fast")
    parser.add_argument("--reps", type=int, default=8)
    parser.add_argument("--sessions", type=int, default=3, help="extra Mecum open/close cycles per app")
    parser.add_argument("--out", required=True)
    parser.add_argument("--scratch", required=True)
    options = parser.parse_args()
    apps = options.apps.split(",")
    meta = {"run": time.strftime("%Y-%m-%dT%H:%M:%S"), "reps": options.reps}
    recorder = Recorder(options.out, meta)
    log = open(os.path.join(options.scratch, "drivers-stderr.log"), "a")
    baseline(recorder, 10)
    for driver in options.drivers.split(","):
        print(f"== {driver}", flush=True)
        if driver.startswith("cua"):
            run_cua(recorder, apps, options.reps, log, driver, options.scratch)
        else:
            knowledge = os.path.join(options.scratch, f"knowledge-{int(time.time())}")
            os.makedirs(knowledge)
            run_mecum(recorder, apps, options.reps, log, knowledge, options.sessions)


if __name__ == "__main__":
    main()
