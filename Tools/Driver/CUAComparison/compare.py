"""Mecum vs Cua Driver: the same operations on the same windows, through the same MCP stdio client.

    python3 compare.py --apps Calculator,TextEdit --reps 8 --out results.jsonl --scratch DIR
    python3 compare.py --mode chain --apps TextEdit ...    # steps with 0, 1, 3 and 5 s pauses between them
    python3 compare.py --mode soak --apps TextEdit ...     # 200 steps per driver, footprint every 10
    python3 compare.py --phases --drivers mecum ...        # a MECUM_PHASES build, never mixed with timed runs

Every call is one JSONL row: wall time at the client, reply size and tokens (text and image), CPU,
instructions and energy of the driver and of the target application, WindowServer CPU, and what an
independent probe saw around the call (frontmost app, physical cursor, windows and the display each is
on, hashes of the AX values, selection, focus, scroll position and window titles). The first row of a
run is its `kind: "meta"` row: preflight, machine, driver commits. Drivers alternate per app in ABBA
order (mecum, cua, cua-overlay, then reversed) with a cooldown between blocks.

Cua is used the way its own docs say (see README, "How Cua is driven"): an action is one
`run_actions` call with `observe:true`, a re-read is a `since:"latest"` diff. `cua-legacy` keeps the
6 October pair (action, then a full `get_window_state`) as the secondary series `step_legacy`.
"""
import argparse, json, math, os, subprocess, sys, threading, time
from mcpclient import MCPClient
import prepare, rusage

HERE = os.path.dirname(os.path.abspath(__file__))
CUA = prepare.CUA
MECUM = prepare.MECUM
PROBE = prepare.PROBE
PHASES_BIN = os.environ.get("MECUM_PHASES_BIN", os.path.join(HERE, ".build-phases/release/mecum-mcp-stdio"))
PHASE_TABLE = os.path.join(HERE, "../Phases/phase-table.py")
REST_DELAY_S = 2.5          # ADR 0036: the window stream rests after this long without a use
TEXT_CHARS_PER_TOKEN = 4

# What an independent oracle looks for after each kind of operation: the probe parts that must change.
# `False` as an operation's fourth element means the probe cannot see the effect, so it stays unverified.
ORACLE = {"click": ["values", "selection", "focus", "windows"], "type": ["values", "selection"],
          "key": ["values", "selection", "focus"], "hotkey": ["values", "selection", "focus"],
          "scroll_down": ["scroll"], "scroll_up": ["scroll"]}


# One operation: a name, then what each driver calls, then optionally its oracle. A cua argument
# {"label": ..} names an element (a run_actions `name`, or the element_token of the latest read for
# cua-legacy); {"at": (fx, fy)} is window-local screenshot pixels. "{rep}" in a string is the repetition.
def scroll(direction, oracle="default"):
    return (f"scroll_{direction}", ("scroll", {"direction": direction, "lines": 3}),
            ("scroll", {"direction": direction, "amount": 3}), oracle)


def menu(op, path, oracle="default"):
    return (op, ("menu", {"path": " > ".join(path)}), ("invoke_menu", {"path": path}), oracle)


SCENARIOS = {
    "Calculator": dict(framework="SwiftUI", process="Calculator", chain=["click", "key"], ops=[
        ("click", ("act", {"target": "7"}), ("click", {"label": "7", "role": "AXButton"}), ["values"]),
        ("key", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"}), ["values"]),
        menu("menu", ["View", "Basic"]),
    ]),
    "TextEdit": dict(framework="AppKit", process="TextEdit", chain=["key", "hotkey", "scroll_down", "scroll_up"], ops=[
        # The insert opens a new line below line two, so the click's label never changes between reps.
        ("click", ("act", {"target": "Line two."}), ("click", {"at": (0.06, 0.115)}), ["selection"]),
        ("hotkey", ("press_key", {"key": "right", "modifiers": ["cmd"]}), ("hotkey", {"keys": ["cmd", "right"]})),
        ("type", ("insert_text", {"text": "\nbench"}), ("type_text", {"text": "\nbench"}), ["values"]),
        # Undo takes the insert back, so every repetition starts from the same text.
        ("undo", ("press_key", {"key": "z", "modifiers": ["cmd"]}), ("hotkey", {"keys": ["cmd", "z"]}), ["values"]),
        ("key", ("press_key", {"key": "left"}), ("press_key", {"key": "left"})),
        scroll("down"), scroll("up"),
        menu("menu", ["Edit", "Select All"], ["selection"]),
    ]),
    "Google Chrome": dict(framework="Chromium", process="Google Chrome",
                          chain=["key", "hotkey", "scroll_down", "scroll_up"], ops=[
        ("click", ("act", {"target": "Press me"}), ("click", {"label": "Press me", "role": "AXButton"}), ["values"]),
        ("type", ("type_text", {"target": "Name", "text": "hello{rep}"}),
                 ("type_text", {"label": "Name", "role": "AXTextField", "text": "hello{rep}"}), ["values"]),
        ("key", ("press_key", {"key": "tab"}), ("press_key", {"key": "tab"})),
        ("hotkey", ("press_key", {"key": "tab", "modifiers": ["shift"]}), ("hotkey", {"keys": ["shift", "tab"]})),
        scroll("down"), scroll("up"),
        menu("menu", ["View", "Always Show Bookmarks Bar"]),
    ]),
    "Prism Launcher": dict(framework="Qt 6", process="prismlauncher", ops=[
        ("click", ("act", {"target": "Meow"}), ("click", {"label": "Meow", "role": "AXCheckBox"}), ["values"]),
        ("key", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"})),
    ]),
    "kitty": dict(framework="OpenGL (GLFW)", process="kitty", ops=[
        ("type", ("insert_text", {"text": "echo bench"}), ("type_text", {"text": "echo bench"}), False),
        ("hotkey", ("press_key", {"key": "u", "modifiers": ["ctrl"]}), ("hotkey", {"keys": ["ctrl", "u"]}), False),
        ("key", ("press_key", {"key": "left"}), ("press_key", {"key": "left"}), False),
        scroll("up"), scroll("down"),
    ]),
    "Safari": dict(framework="WebKit (Safari)", process="Safari", window="Personal — Bench Page", ops=[
        ("click", ("act", {"target": "Press me"}), ("click", {"label": "Press me", "role": "AXButton"}), ["values"]),
        ("type", ("type_text", {"target": "Name", "text": "hello{rep}"}),
                 ("type_text", {"label": "Name", "role": "AXTextField", "text": "hello{rep}"}), ["values"]),
        ("key", ("press_key", {"key": "tab"}), ("press_key", {"key": "tab"})),
        ("hotkey", ("press_key", {"key": "tab", "modifiers": ["shift"]}), ("hotkey", {"keys": ["shift", "tab"]})),
        scroll("down"), scroll("up"),
        # Zoom in, then back to actual size, so each item is enabled when it is pressed.
        menu("menu", ["View", "Zoom In"]), menu("menu_back", ["View", "Actual Size"]),
    ]),
    "Stocks": dict(framework="Mac Catalyst", process="Stocks", window="Stocks", ops=[
        ("key", ("press_key", {"key": "tab"}), ("press_key", {"key": "tab"})),
        scroll("down"), scroll("up"),
    ]),
    "Obsidian": dict(framework="Electron", process="Obsidian", ops=[
        ("click", ("act", {"target": "More options"}), ("click", {"label": "More options", "role": "AXButton"}), False),
        ("key", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"}), False),
        ("hotkey", ("press_key", {"key": "o", "modifiers": ["cmd"]}), ("hotkey", {"keys": ["cmd", "o"]}), False),
        ("type", ("insert_text", {"text": "Driver"}), ("type_text", {"text": "Driver"}), False),
        ("key_close", ("press_key", {"key": "escape"}), ("press_key", {"key": "escape"}), False),
    ]),
    "DaVinci Resolve": dict(framework="Qt + GPU (Resolve)", process="Resolve", ops=[
        ("click", ("act", {"target": "Thumbnail View"}), ("click", {"label": "Thumbnail View", "role": "AXCheckBox"})),
        ("click_back", ("act", {"target": "List View"}), ("click", {"label": "List View", "role": "AXCheckBox"})),
        # No Escape here: it closes the Project Manager, and Resolve quits with no project open.
        scroll("down"), scroll("up"),
    ]),
    # Works in the background and never saves: the document is closed with Don't Save. Known hazards, recorded
    # and not worked around: a "Start Bar" window can make Mecum's adoption refuse (moveRefused), and right
    # after a new document Photoshop can be "not ready" for about 2 s.
    "Photoshop": dict(framework="Adobe (proprietary toolkit)", process_prefix="Adobe Photoshop", rebind="front", ops=[
        menu("new_doc", ["File", "New..."], ["windows"]),
        ("new_doc_confirm", ("press_key", {"key": "return"}), ("press_key", {"key": "return"}), ["windows"]),
        menu("menu_rotate", ["Image", "Image Rotation", "180°"], False),
        menu("menu_rotate_back", ["Image", "Image Rotation", "180°"], False),
        ("key", ("press_key", {"key": "x"}), ("press_key", {"key": "x"}), False),
        scroll("down", False), scroll("up", False),
        menu("close_doc", ["File", "Close"], ["windows"]),
        ("dont_save", ("press", {"button": "Don't Save"}), ("click", {"label": "Don't Save", "role": "AXButton"}),
         ["windows"]),
    ]),
}
# Rows that are not an operation under test: they carry no success verdict.
NOT_ACTIONS = {"observe", "observe_unchanged", "observe_after", "list_windows", "open_session", "close_session",
               "idle", "baseline", "startup", "soak_mem", "chain_step", "block_aborted", "target"}
BAD_STATUS = ("error", "refused", "failed", "honest_miss", "ambiguous")
RUN_TOOLS = {"click", "press_key", "hotkey", "type_text", "scroll"}
ROLES = {"AXButton": "button", "AXCheckBox": "checkbox", "AXTextField": "textfield"}
WINDOW_SERVER = None


class Dead(Exception):
    """The driver process stopped answering or exited: the block ends."""


def target_for(app, scenario, fixtures):
    """(pid, window title or None, app name Mecum opens) of the running target; RuntimeError if absent."""
    fixture = fixtures.get(app) or {}
    if "process_prefix" in scenario:
        name = prepare.process_name(scenario["process_prefix"])
        pid = prepare.process_pid(scenario["process_prefix"], prefix=True)
    else:
        name = app
        pid = fixture.get("pid") or prepare.process_pid(scenario["process"])
    if not pid:
        raise RuntimeError(f"{app} is not running")
    return pid, fixture.get("window") or scenario.get("window"), name


def window_server():
    global WINDOW_SERVER
    WINDOW_SERVER = WINDOW_SERVER or prepare.process_pid("WindowServer")
    return WINDOW_SERVER


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


def reply_body(reply):
    texts = " ".join(item.get("text", "") for item in (reply.get("result") or {}).get("content", [])
                     if item.get("type") == "text")
    if texts.startswith("{"):
        try:
            return json.loads(texts)
        except ValueError:
            pass
    return None


def self_verdict(reply):
    """What the driver itself claims about the effect: Cua's `effect`, Mecum's outcome status."""
    structured = (reply.get("result") or {}).get("structuredContent") or {}
    if "effect" in structured:
        return structured["effect"] if isinstance(structured["effect"], str) else json.dumps(structured["effect"])[:60]
    if "steps" in structured and structured["steps"]:
        step = structured["steps"][0]
        return step.get("effect") or ("ok" if step.get("ok") else "failed")
    body = reply_body(reply) or {}
    return body.get("status") or (body.get("outcome") or {}).get("status")


def failed(reply):
    """Why the call did not do its job, or None. An honest_miss and a failed delivery are failures."""
    result = reply.get("result")
    if result is None:
        return reply.get("error", {}).get("message", "protocol error")
    if result.get("isError"):
        return " ".join(item.get("text", "") for item in result.get("content", []))[:300]
    structured = result.get("structuredContent") or {}
    if structured.get("ok") is False or structured.get("failed_step") is not None:
        bad = next((s for s in structured.get("steps", []) if s.get("ok") is False), {})
        return f"run_actions step {structured.get('failed_step')}: {bad.get('message') or bad.get('error') or 'failed'}"[:300]
    body = reply_body(reply) or {}
    message = body.get("message") or ""
    if body.get("status") in BAD_STATUS:
        return f"{body['status']}: {message}"[:300]
    if body.get("status") == "acted_unverified" and "delivery failed" in message:
        return message[:300]
    if structured.get("effect") in ("refused", "failed"):
        return f"effect {structured['effect']}"
    return None


def moved(a, b, limit=1.0):
    return bool(a and b) and math.dist(a, b) > limit


def user_windows(reading):
    """Substantial onscreen windows of the target on a display that is not the Seat's."""
    return sum(1 for w in reading.get("windows", []) if w.get("onscreen") and not w.get("seat")
               and w.get("display", -1) != -1 and w.get("w", 0) > 100 and w.get("h", 0) > 100)


def sub(a, b, key, scale=1e6):
    return (b[key] - a[key]) / scale if a and b else None


class Recorder:
    def __init__(self, path, meta, call_timeout):
        self.file = open(path, "a")
        self.meta = meta
        self.ctx = {}
        self.timeout = call_timeout
        self.last_end = {}
        self.last = None

    def write(self, row):
        self.file.write(json.dumps(row) + "\n")
        self.file.flush()

    def row(self, **fields):
        return dict(self.meta, **self.ctx, **fields)

    def guarded(self, client, name, arguments):
        """The call, with its stdio server killed (our own child, by handle) when no reply comes."""
        fired = []
        def stop():
            fired.append(True)
            client.proc.kill()
        timer = threading.Timer(self.timeout, stop)
        timer.start()
        try:
            return client.call(name, arguments), False
        finally:
            timer.cancel()
            self.stalled = bool(fired)

    def measure(self, client, driver, app, framework, op, rep, name, arguments, target_pid, settle=0.25,
                light=False, expect=None, **extra):
        """One call. `light` skips the probes and the settle, for chain and soak steps whose timing counts."""
        pid = getattr(client, "driver_pid", client.pid)
        proxy = client.pid if pid != client.pid else None
        before = {} if light else probe(target_pid)
        ws = None if light else window_server()
        cursor0 = rusage.cursor()
        d0, a0, p0 = rusage.sample(pid), rusage.sample(target_pid), rusage.sample(proxy) if proxy else None
        w0 = rusage.ps_cpu_ns(ws) if ws else None
        started = time.perf_counter()
        gap = started - self.last_end[id(client)] if id(client) in self.last_end else None
        try:
            (seconds, size, reply), _ = self.guarded(client, name, arguments)
            error = failed(reply)
        except Exception as exception:
            seconds, size, reply, error = None, 0, {}, f"exception: {exception}"
        timed_out = self.stalled
        self.last_end[id(client)] = time.perf_counter()
        if timed_out:
            error = f"stall: no reply in {self.timeout:.0f} s, driver killed"
        d1, a1, p1 = rusage.sample(pid), rusage.sample(target_pid), rusage.sample(proxy) if proxy else None
        w1 = rusage.ps_cpu_ns(ws) if ws else None
        cursor1 = rusage.cursor()
        if not light:
            time.sleep(settle)
        after = {} if light else probe(target_pid)
        text, images, structured = payload(reply)
        sizes = [s for s in image_sizes(reply) if s]
        image_toks = sum(image_tokens(*s) for s in sizes)
        parts_b, parts_a = before.get("parts"), after.get("parts")
        verified = any(parts_b.get(p) != parts_a.get(p) for p in expect) if expect and parts_b and parts_a else None
        success = None
        if op not in NOT_ACTIONS:
            success = False if error is not None or verified is False else (True if verified else None)
        observation = ((reply.get("result") or {}).get("structuredContent") or {}).get("observation")
        row = self.row(driver=driver, app=app, framework=framework, op=op, rep=rep, tool=name,
                       ms=None if seconds is None else seconds * 1000, ok=error is None, error=error,
                       self_verdict=self_verdict(reply), reply_bytes=size, text_chars=text,
                       structured_bytes=structured, images=len(images), image_px=[list(s) for s in sizes],
                       image_tokens=image_toks, tokens_text=text / TEXT_CHARS_PER_TOKEN,
                       tokens=text / TEXT_CHARS_PER_TOKEN + image_toks,
                       observe_ok=observation.get("ok") if isinstance(observation, dict) else None,
                       driver_cpu_ms=sub(d0, d1, "cpu_ns"), proxy_cpu_ms=sub(p0, p1, "cpu_ns"),
                       driver_instructions=sub(d0, d1, "instructions", 1),
                       driver_energy_mj=sub(d0, d1, "energy_nj"),
                       driver_footprint_mb=d1["footprint"] / 2**20 if d1 else None,
                       driver_peak_mb=d1["peak_footprint"] / 2**20 if d1 else None,
                       proxy_footprint_mb=p1["footprint"] / 2**20 if p1 else None,
                       app_cpu_ms=sub(a0, a1, "cpu_ns"), app_energy_mj=sub(a0, a1, "energy_nj"),
                       app_footprint_mb=a1["footprint"] / 2**20 if a1 else None,
                       windowserver_cpu_ms=(w1 - w0) / 1e6 if w0 is not None and w1 is not None else None,
                       gap_s=gap,
                       stream_resting=(gap is not None and gap > REST_DELAY_S) if driver == "mecum" else None,
                       expect=expect or None, verified=verified, success=success,
                       frontmost_before=before.get("frontmost"), frontmost_after=after.get("frontmost"),
                       frontmost_changed=(before.get("frontmost") != after.get("frontmost")) if before and after else None,
                       cursor_moved=moved(before.get("cursor"), after.get("cursor")) if before and after else None,
                       cursor_moved_call=moved(cursor0, cursor1),
                       user_windows_before=user_windows(before) if before else None,
                       user_windows_after=user_windows(after) if after else None,
                       window_on_user_display=(user_windows(after) > user_windows(before)) if before and after else None,
                       effect_seen=before.get("digest") != after.get("digest") if before and after else None,
                       digest_before=before.get("digest"), digest_after=after.get("digest"),
                       target_pid=target_pid, **extra)
        self.write(row)
        self.last = row
        ms = row["ms"]
        print(f"  {'ok ' if row['ok'] else 'ERR'} {driver:11} {app:15} {op:16} r{rep} "
              f"{'   -    ' if ms is None else f'{ms:8.1f}'} ms {size:>8} B"
              + ("" if row["ok"] else f"  {str(error)[:120]}"), flush=True)
        if timed_out or (error and client.proc.poll() is not None):
            raise Dead(error)
        return reply

    def failure(self, driver, app, framework, op, rep, error, **extra):
        """A step the harness could not even send (no element, no window): a failed row with no timing."""
        row = self.row(driver=driver, app=app, framework=framework, op=op, rep=rep, ms=None, ok=False, error=error,
                       success=False if op not in NOT_ACTIONS else None, **extra)
        self.write(row)
        self.last = row
        print(f"  ERR {driver:11} {app:15} {op:16} r{rep}  {error[:120]}", flush=True)


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


def fill(arguments, rep):
    return {k: v.format(rep=rep) if isinstance(v, str) and "{rep}" in v else v for k, v in arguments.items()}


def normal(label):
    return label.replace("’", "'").replace("…", "...")


class Cua:
    """Launch variants, every other Cua default kept (including its post-action window watch):

    cua          cua-driver mcp --direct: the MCP process owns the runtime, no agent cursor overlay.
    cua-overlay  the daemon-backed path, whose daemon owns the AppKit loop the overlay needs (on by default
                 there). With /Applications/CuaDriver.app installed, a bare `cua-driver mcp` proxies to the
                 daemon the way the README describes. Without it, the harness is the embedding host
                 (Skills/cua-driver/EMBEDDING.md): `serve --embedded` as its own child on a private socket,
                 then `mcp --embedded --socket`. The two cases are recorded in the startup row.
    cua-fast     opt-in floor: CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS=0 drops the post-action watch.
    cua-legacy   as cua, but acting the 6 October way: the action, then a full get_window_state
                 (full_output, element tokens). The secondary series `step_legacy`.

    Telemetry is off in all of them (CUA_DRIVER_RS_TELEMETRY_ENABLED=0). Every call carries a session label."""

    SESSION = "bench"
    APP = "/Applications/CuaDriver.app"

    def __init__(self, recorder, log, variant="cua", scratch=None):
        self.recorder = recorder
        self.name = variant
        self.legacy = variant == "cua-legacy"
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
        self.state = self.shot = None
        self.pid = self.window = None
        self.last_tool = None
        self.client.call("start_session", {"session": self.SESSION})

    def startup_row(self):
        return dict(driver=self.name, op="startup", ms=self.startup_ms, ok=True, launch=self.launch)

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
        """Binds the top window above 100 px (matching `title` when given); True when the window changed."""
        reply = self.client.call("list_windows", {"pid": pid, "session": self.SESSION})[2]
        windows = [w for w in reply["result"]["structuredContent"]["windows"]
                   if w["bounds"]["width"] > 100 and w["bounds"]["height"] > 100
                   and (title is None or title in (w.get("title") or ""))]
        windows.sort(key=lambda w: w.get("z_index", 0), reverse=True)
        if not windows:
            raise RuntimeError(f"no window above 100 px for pid {pid} (Stage Manager stash or minimized?)")
        changed = (pid, windows[0]["window_id"]) != (self.pid, self.window)
        self.pid, self.window = pid, windows[0]["window_id"]
        return changed

    def open(self, app, framework, rep, target, scenario):
        pid, title, _ = target
        try:
            self.bind(pid, title)
        except RuntimeError as error:
            self.recorder.failure(self.name, app, framework, "open_session", rep, str(error))
            return False
        self.recorder.measure(self.client, self.name, app, framework, "list_windows", 0, "list_windows",
                              {"pid": pid, "session": self.SESSION}, pid)
        return True

    def read(self, app, framework, op, rep, pid, light=False, **extra):
        """A window read. Full: the 6 October payload for cua-legacy, Cua's default read otherwise.
        Diff: `since:"latest"` without a screenshot, the re-read its docs recommend."""
        arguments = {"pid": self.pid, "window_id": self.window, "session": self.SESSION}
        if op == "observe":
            arguments |= {"full_output": True} if self.legacy else {}
        elif not self.legacy:
            arguments |= {"since": "latest", "include_screenshot": False}
        else:
            arguments |= {"full_output": True}
        reply = self.recorder.measure(self.client, self.name, app, framework, op, rep, "get_window_state",
                                      arguments, pid, light=light, **extra)
        structured = (reply.get("result") or {}).get("structuredContent") or {}
        if op != "observe" and not self.legacy:
            return
        self.state = structured
        sizes = image_sizes(reply)
        self.shot = tuple(sizes[0]) if sizes else (structured.get("screenshot_width"), structured.get("screenshot_height"))

    def start_rep(self, app, framework, rep, pid):
        self.read(app, framework, "observe", rep, pid)
        if not self.legacy:
            self.read(app, framework, "observe_unchanged", rep, pid)

    def named(self, arguments):
        """run_actions arguments naming the target by role and name, or by pixels of the last screenshot."""
        arguments = dict(arguments)
        label, role, at = arguments.pop("label", None), arguments.pop("role", None), arguments.pop("at", None)
        if label is not None:
            arguments["name"] = label
            if role:
                arguments["role"] = ROLES.get(role, role.removeprefix("AX").lower())
        if at is not None:
            if not self.shot or None in self.shot:
                raise RuntimeError("no screenshot size for a pixel target")
            arguments["x"], arguments["y"] = round(at[0] * self.shot[0]), round(at[1] * self.shot[1])
        return arguments

    def resolve(self, arguments):
        """cua-legacy: the element_token of the latest full read, as on 6 October."""
        arguments = dict(arguments)
        label, role, at = arguments.pop("label", None), arguments.pop("role", None), arguments.pop("at", None)
        if label is not None:
            matches = [e for e in (self.state or {}).get("elements", [])
                       if normal(e.get("label") or "") == normal(label) and (role is None or e.get("role") == role)]
            if not matches:
                raise RuntimeError(f"no element {label!r} {role}")
            arguments["element_token"] = matches[0]["element_token"]
        if at is not None:
            arguments["x"] = round(at[0] * self.state["screenshot_width"])
            arguments["y"] = round(at[1] * self.state["screenshot_height"])
        return dict(arguments, pid=self.pid, window_id=self.window, session=self.SESSION)

    def act(self, app, framework, op, rep, spec, target, expect, rebind=None, light=False, **extra):
        name, arguments = spec[0], fill(spec[1], rep)
        pid = target[0]
        self.last_tool = name
        try:
            changed = self.bind(pid) if rebind == "front" else False
            if self.legacy and (changed or self.state is None):
                self.state = self.client.call("get_window_state", {
                    "pid": self.pid, "window_id": self.window, "session": self.SESSION,
                    "full_output": True})[2]["result"]["structuredContent"]
            base = {"pid": self.pid, "window_id": self.window, "session": self.SESSION}
            if name == "invoke_menu":
                tool, call = name, dict(arguments, **base)
            elif self.legacy:
                tool, call = name, self.resolve(arguments)
            elif name in RUN_TOOLS:
                tool, call = "run_actions", dict(base, steps=[{"tool": name, "args": self.named(arguments)}],
                                                 observe=True)
            else:
                raise RuntimeError(f"no Cua equivalent of {name}")
        except Dead:
            raise
        except Exception as error:
            self.recorder.failure(self.name, app, framework, op, rep, f"harness: {error}", **extra)
            return self.recorder.last
        self.recorder.measure(self.client, self.name, app, framework, op, rep, tool, call, pid,
                              light=light, expect=expect, **extra)
        return self.recorder.last

    def after(self, app, framework, op, rep, target, rebind=None, light=False, **extra):
        """The observation a step needs after its action: cua-legacy always, others only after a menu
        (run_actions has no menu step), as a diff read."""
        if not self.legacy and self.last_tool != "invoke_menu":
            return None
        try:
            if rebind == "front":
                self.bind(target[0])
            self.read(app, framework, "observe_after", rep, target[0], light=light, after_op=op, **extra)
        except Dead:
            raise
        except Exception as error:
            self.recorder.failure(self.name, app, framework, "observe_after", rep, f"harness: {error}",
                                  after_op=op, **extra)
        return self.recorder.last

    def release(self, app, framework, rep, pid):
        pass


class Mecum:
    name = "mecum"

    def __init__(self, recorder, log, knowledge, binary=None):
        self.recorder = recorder
        env = dict(os.environ, MECUM_BENCH_UNVALIDATED="1")
        started = time.perf_counter()
        self.client = MCPClient([binary or MECUM, knowledge], stderr=log, env=env)
        self.startup_ms = (time.perf_counter() - started) * 1000
        self.session = None
        self.launch = "phases" if binary else "release"

    def startup_row(self):
        return dict(driver="mecum", op="startup", ms=self.startup_ms, ok=True, launch=self.launch)

    def open(self, app, framework, rep, target, scenario):
        pid, window, name = target
        arguments = {"app": name} | ({"window": window} if window else {})
        reply = self.recorder.measure(self.client, "mecum", app, framework, "open_session", rep,
                                      "open_session", arguments, pid, settle=0.5)
        self.session = (reply_body(reply) or {}).get("session")
        return bool(self.session)

    def release(self, app, framework, rep, pid):
        if self.session:
            self.recorder.measure(self.client, "mecum", app, framework, "close_session", rep,
                                  "close_session", {"session": self.session}, pid, settle=0.5)
        self.session = None

    def read(self, app, framework, op, rep, pid, full, light=False, **extra):
        return self.recorder.measure(self.client, "mecum", app, framework, op, rep, "observe",
                                     {"session": self.session} | ({"full": True} if full else {}), pid,
                                     light=light, **extra)

    def start_rep(self, app, framework, rep, pid):
        self.read(app, framework, "observe", rep, pid, full=True)
        self.read(app, framework, "observe_unchanged", rep, pid, full=False)

    def act(self, app, framework, op, rep, spec, target, expect, rebind=None, light=False, **extra):
        self.recorder.measure(self.client, "mecum", app, framework, op, rep, spec[0],
                              dict(fill(spec[1], rep), session=self.session), target[0],
                              light=light, expect=expect, **extra)
        return self.recorder.last

    def after(self, *args, **kwargs):
        """Mecum's action reply already carries the scene after it."""
        return None

    def close(self):
        self.client.close()


def new_driver(name, recorder, log, scratch, phases):
    if name.startswith("cua"):
        return Cua(recorder, log, name, scratch)
    knowledge = os.path.join(scratch, f"knowledge-{int(time.time() * 1000)}")
    os.makedirs(knowledge)
    return Mecum(recorder, log, knowledge, PHASES_BIN if phases else None)


def oracle(op, entry):
    """The probe parts that confirm this operation, or None when the probe cannot see its effect."""
    given = entry[3] if len(entry) > 3 else "default"
    return None if given is False else ORACLE.get(op) if given == "default" else given


def spec_for(driver, entry):
    return entry[1] if driver.name == "mecum" else entry[2]


def chain_entries(scenario):
    names = scenario.get("chain")
    return [e for e in scenario["ops"] if names is None or e[0] in names]


def idle_windows(recorder, driver, app, framework, pid, windows, seconds):
    """CPU the driver, the target and WindowServer spend while nothing is asked, in consecutive windows."""
    client, ws = driver.client, window_server()
    d_pid = getattr(client, "driver_pid", client.pid)
    proxy = client.pid if d_pid != client.pid else None
    ended = recorder.last_end.get(id(client), time.perf_counter())
    for index in range(1, windows + 1):
        started = time.perf_counter()
        d0, a0, p0, w0, c0 = rusage.sample(d_pid), rusage.sample(pid), rusage.sample(proxy) if proxy else None, \
            rusage.ps_cpu_ns(ws), rusage.cursor()
        time.sleep(seconds)
        d1, a1, p1, w1, c1 = rusage.sample(d_pid), rusage.sample(pid), rusage.sample(proxy) if proxy else None, \
            rusage.ps_cpu_ns(ws), rusage.cursor()
        row = recorder.row(driver=driver.name, app=app, framework=framework, op="idle", rep=0, tool=None, window=index,
                           since_last_call_s=started - ended, ms=(time.perf_counter() - started) * 1000, ok=True,
                           driver_cpu_ms=sub(d0, d1, "cpu_ns"), proxy_cpu_ms=sub(p0, p1, "cpu_ns"),
                           app_cpu_ms=sub(a0, a1, "cpu_ns"), driver_energy_mj=sub(d0, d1, "energy_nj"),
                           driver_wakeups=d1["wakeups"] - d0["wakeups"], driver_footprint_mb=d1["footprint"] / 2**20,
                           app_footprint_mb=a1["footprint"] / 2**20 if a1 else None,
                           windowserver_cpu_ms=(w1 - w0) / 1e6, cursor_moved_call=moved(c0, c1))
        recorder.write(row)
        print(f"  idle  {driver.name:11} {app:15} w{index} cpu {row['driver_cpu_ms']:.1f} ms  "
              f"app {row['app_cpu_ms'] or 0:.1f} ms  WS {row['windowserver_cpu_ms']:.0f} ms", flush=True)


def baseline(recorder, seconds, where):
    """WindowServer with no driver running, the floor every idle row is read against."""
    ws = window_server()
    w0, c0 = rusage.ps_cpu_ns(ws), rusage.cursor()
    time.sleep(seconds)
    row = recorder.row(driver="none", op="baseline", where=where, ms=seconds * 1000, ok=True,
                       windowserver_cpu_ms=(rusage.ps_cpu_ns(ws) - w0) / 1e6, cursor_moved_call=moved(c0, rusage.cursor()))
    recorder.write(row)
    print(f"  baseline {where} {seconds}s WS {row['windowserver_cpu_ms']:.0f} ms", flush=True)


def ops_block(driver, app, scenario, target, reps, options):
    framework, pid = scenario["framework"], target[0]
    if not driver.open(app, framework, reps[0], target, scenario):
        return
    for rep in [0] + reps:
        driver.start_rep(app, framework, rep, pid)
        for step, entry in enumerate(scenario["ops"]):
            op = entry[0]
            driver.act(app, framework, op, rep, spec_for(driver, entry), target, oracle(op, entry),
                       rebind=scenario.get("rebind"), step=step)
            driver.after(app, framework, op, rep, target, rebind=scenario.get("rebind"), step=step)
    idle_windows(driver.recorder, driver, app, framework, pid, options.idle_windows, options.idle_seconds)
    driver.release(app, framework, 0, pid)
    for rep in range(1, options.sessions + 1) if options.extra_sessions else []:
        if driver.open(app, framework, rep, target, scenario):
            driver.release(app, framework, rep, pid)


def chain_block(driver, app, scenario, target, options):
    """10 consecutive steps with a pause between them, for each pause, from the same resting start."""
    framework, pid = scenario["framework"], target[0]
    entries = chain_entries(scenario)
    if not driver.open(app, framework, 0, target, scenario):
        return
    for pause in options.pauses:
        # A rest longer than Mecum's 2.5 s, so every group starts from a resting stream.
        time.sleep(options.group_rest)
        for index in range(options.chain_steps):
            entry = entries[index % len(entries)]
            op = entry[0]
            extra = dict(pause_s=pause, chain_step=index + 1)
            acted = driver.act(app, framework, op, index + 1, spec_for(driver, entry), target, None,
                               light=True, step=index, **extra)
            seen = driver.after(app, framework, op, index + 1, target, light=True, step=index, **extra)
            parts = [r for r in (acted, seen) if r]
            driver.recorder.write(driver.recorder.row(
                driver=driver.name, app=app, framework=framework, op="chain_step", rep=index + 1, **extra,
                tool=acted.get("tool"), step_op=op, gap_s=acted.get("gap_s"),
                stream_resting=acted.get("stream_resting"),
                ms=sum(r["ms"] for r in parts) if all(r.get("ms") is not None for r in parts) else None,
                ok=all(r.get("ok") for r in parts), error=next((r["error"] for r in parts if r.get("error")), None)))
            time.sleep(pause)
    driver.release(app, framework, 0, pid)


def soak_block(driver, app, scenario, target, options):
    """`soak_steps` neutral steps, the driver's and the target's footprint every `soak_every`."""
    framework, pid = scenario["framework"], target[0]
    entries = chain_entries(scenario)
    if not driver.open(app, framework, 0, target, scenario):
        return
    for n in range(1, options.soak_steps + 1):
        entry = entries[(n - 1) % len(entries)]
        driver.act(app, framework, entry[0], n, spec_for(driver, entry), target, None, light=True, soak_step=n)
        driver.after(app, framework, entry[0], n, target, light=True, soak_step=n)
        if n % options.soak_every == 0:
            client = driver.client
            d = rusage.sample(getattr(client, "driver_pid", client.pid))
            a = rusage.sample(pid)
            driver.recorder.write(driver.recorder.row(
                driver=driver.name, app=app, framework=framework, op="soak_mem", rep=0, soak_step=n, ok=True, ms=None,
                driver_footprint_mb=d["footprint"] / 2**20 if d else None,
                driver_peak_mb=d["peak_footprint"] / 2**20 if d else None,
                app_footprint_mb=a["footprint"] / 2**20 if a else None))
    driver.release(app, framework, 0, pid)


def schedule(drivers, reps, order):
    """[(driver, reps)] blocks: ABBA (forward then reversed), the odd repetition going to the forward pass."""
    first = (reps + 1) // 2
    if order == "forward" or len(drivers) < 2 or reps < 2:
        return [(d, list(range(1, reps + 1))) for d in drivers]
    return [(d, list(range(1, first + 1))) for d in drivers] + \
           [(d, list(range(first + 1, reps + 1))) for d in reversed(drivers)]


def run_app(app, drivers, options, recorder, log, fixtures):
    scenario = SCENARIOS[app]
    try:
        target_for(app, scenario, fixtures)
    except RuntimeError as error:
        recorder.failure("none", app, scenario["framework"], "target", 0, str(error))
        return
    if options.mode == "ops":
        blocks = schedule(drivers, options.reps, options.order)
    elif options.mode == "chain" and options.order == "abba" and len(drivers) > 1:
        blocks = [(d, []) for d in drivers + drivers[::-1]]
    else:
        blocks = [(d, []) for d in drivers]
    seen = set()
    for index, (name, reps) in enumerate(blocks):
        if index:
            print(f"-- cooldown {options.cooldown} s", flush=True)
            time.sleep(options.cooldown)
        series = "step_legacy" if name == "cua-legacy" else "step"
        recorder.ctx = dict(mode=options.mode, block=index, series=series,
                            order_pass="forward" if index < len(drivers) else "reverse")
        print(f"== {app} · {name} · block {index} ({recorder.ctx['order_pass']})", flush=True)
        driver = None
        try:
            driver = new_driver(name, recorder, log, options.scratch, options.phases)
            recorder.write(recorder.row(**driver.startup_row()))
            options.extra_sessions = name == "mecum" and name not in seen
            seen.add(name)
            target = target_for(app, scenario, fixtures)
            {"ops": lambda: ops_block(driver, app, scenario, target, reps, options),
             "chain": lambda: chain_block(driver, app, scenario, target, options),
             "soak": lambda: soak_block(driver, app, scenario, target, options)}[options.mode]()
        except Dead as error:
            print(f"  block aborted: {error}", flush=True)
            recorder.write(recorder.row(driver=name, app=app, op="block_aborted", ok=False, error=str(error)))
        except Exception as error:
            print(f"  block failed: {error}", flush=True)
            recorder.write(recorder.row(driver=name, app=app, op="block_aborted", ok=False, error=f"{error}"))
        finally:
            if driver:
                driver.close()
    recorder.ctx = {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apps", default=",".join(s for s in SCENARIOS if s != "Photoshop"))
    parser.add_argument("--drivers", default="mecum,cua,cua-overlay",
                        help="mecum, cua, cua-overlay, cua-legacy (6 Oct action + full read), cua-fast")
    parser.add_argument("--mode", choices=["ops", "chain", "soak"], default="ops")
    parser.add_argument("--reps", type=int, default=8, help="measured repetitions per driver, split over ABBA passes")
    parser.add_argument("--order", choices=["abba", "forward"], default="abba")
    parser.add_argument("--cooldown", type=float, default=15, help="seconds between blocks")
    parser.add_argument("--sessions", type=int, default=3, help="extra Mecum open/close cycles per app")
    parser.add_argument("--idle-windows", type=int, default=3)
    parser.add_argument("--idle-seconds", type=float, default=10)
    parser.add_argument("--pauses", default="0,1,3,5", help="chain mode: seconds between steps")
    parser.add_argument("--chain-steps", type=int, default=10)
    parser.add_argument("--group-rest", type=float, default=6, help="chain mode: rest before each pause group")
    parser.add_argument("--soak-steps", type=int, default=200)
    parser.add_argument("--soak-every", type=int, default=10)
    parser.add_argument("--call-timeout", type=float, default=60, help="a call with no reply by then kills its driver")
    parser.add_argument("--phases", action="store_true", help="Mecum from a MECUM_PHASES build, with signposts")
    parser.add_argument("--out", required=True)
    parser.add_argument("--scratch", required=True)
    options = parser.parse_args()
    options.pauses = [float(p) for p in options.pauses.split(",")]
    apps, drivers = options.apps.split(","), options.drivers.split(",")
    if options.phases and drivers != ["mecum"]:
        sys.exit("--phases runs mecum alone: a phases build is slower and must never be mixed with timed drivers")
    if options.mode == "soak" and options.apps == parser.get_default("apps"):
        apps = ["TextEdit"]
    os.makedirs(options.scratch, exist_ok=True)
    fixtures_path = os.path.join(options.scratch, "fixtures.json")
    fixtures = json.load(open(fixtures_path)) if os.path.exists(fixtures_path) else {}
    meta = {"run": time.strftime("%Y-%m-%dT%H:%M:%S"), "reps": options.reps, "phases": options.phases or None}
    recorder = Recorder(options.out, meta, options.call_timeout)
    recorder.write(dict(meta, kind="meta", mode=options.mode, order=options.order, apps=apps, selected=drivers,
                        pauses=options.pauses if options.mode == "chain" else None,
                        soak_steps=options.soak_steps if options.mode == "soak" else None,
                        cooldown=options.cooldown, idle=[options.idle_windows, options.idle_seconds],
                        fixtures=fixtures, **prepare.meta()))
    log = open(os.path.join(options.scratch, "drivers-stderr.log"), "a")
    phase_log = None
    if options.phases:
        phase_log = subprocess.Popen([sys.executable, PHASE_TABLE, "record", "--process", "mecum-mcp-stdio",
                                      options.out + ".signposts.ndjson"],
                                     stdout=open(options.out + ".phases.txt", "w"), stderr=log)
        time.sleep(2)
    try:
        if options.mode == "ops":
            baseline(recorder, 10, "start")
        for app in apps:
            run_app(app, drivers, options, recorder, log, fixtures)
        if options.mode == "ops":
            baseline(recorder, 10, "end")
    finally:
        if phase_log:
            phase_log.send_signal(2)
            phase_log.wait(timeout=30)


if __name__ == "__main__":
    main()
