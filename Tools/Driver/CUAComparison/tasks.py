"""Real-model task phase: the same tasks, prompt and model, driven by Claude Code through one driver's MCP server.

    python3 tasks.py --out results.jsonl --scratch DIR [--tasks calculator,kitty] [--reps 3] [--dry-run]
    python3 tasks.py --summary summary.json results.jsonl [more.jsonl ...]

Each run starts `claude -p` with built-in tools off and exactly one MCP server named `driver`, reads its
stream-json, and writes one `run` row plus one `tool` row per tool call. Success comes from an independent
check after the run (AX values, files, a local state server), never from the model's own claim.
"""
import argparse, json, math, os, subprocess, sys, threading, time, unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
CLAUDE = os.environ.get("CLAUDE_CLI", "/Users/mac/.local/bin/claude")
CUA = os.environ.get("CUA_DRIVER", os.path.expanduser(
    "~/Forte_Projects/_bench/cua/libs/cua-driver/rust/target/release/cua-driver"))
MECUM = os.path.join(HERE, ".build/release/mecum-mcp-stdio")
PROBE = os.path.join(HERE, ".build/probe")
AXREAD = os.path.join(HERE, ".build/axread")
CUA_APP = "/Applications/CuaDriver.app"
DRIVERS = ["mecum", "cua", "cua-overlay"]
CONFIG = json.load(open(os.path.join(HERE, "tasks.json")))


# ---------------------------------------------------------------- observers (independent of the drivers)

def pid_of(process):
    out = subprocess.run(["pgrep", "-x", process], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def ensure_app(app, process):
    """Launch in the background if it is not running; never activates it."""
    if pid_of(process) is None:
        subprocess.run(["open", "-g", "-a", app], check=False)
        for _ in range(60):
            if pid_of(process):
                break
            time.sleep(0.5)
    return pid_of(process)


def run_json(argv):
    try:
        return json.loads(subprocess.run(argv, capture_output=True, text=True, timeout=20).stdout)
    except Exception as error:
        return {"error": str(error)}


def read_ax(pid, titles_only=False):
    return run_json([AXREAD, str(pid)] + (["--titles"] if titles_only else []))


def clean(text):
    """Display strings carry invisible format characters (direction marks) and thousands separators."""
    return "".join(c for c in text if unicodedata.category(c) != "Cf" and c not in " ,").strip()


def wait_for(predicate, seconds=20):
    end = time.time() + seconds
    while time.time() < end:
        if predicate():
            return True
        time.sleep(0.5)
    return False


class Sampler(threading.Thread):
    """Samples the desktop every 2 s during a run: frontmost process and physical cursor (intrusion),
    plus the target's window titles when a check needs them. The probe reads AX, so it adds a little load."""

    def __init__(self, pid, titles):
        super().__init__(daemon=True)
        self.pid, self.titles, self.stop_flag = pid, titles, threading.Event()
        self.samples, self.seen_titles = [], set()

    def run(self):
        while not self.stop_flag.is_set():
            shot = run_json([PROBE, str(self.pid)])
            self.samples.append((shot.get("frontmost"), tuple(shot.get("cursor") or ())))
            if self.titles:
                self.seen_titles.update(read_ax(self.pid, titles_only=True).get("titles", []))
            self.stop_flag.wait(2)

    def intrusion(self, front0, cursor0):
        front = sum(1 for f, _ in self.samples if f and front0 and f != front0)
        cursors = [cursor0] + [c for _, c in self.samples]
        moves = sum(1 for a, b in zip(cursors, cursors[1:]) if a and b and a != b)
        return dict(samples=len(self.samples), focus_changes=front, cursor_moves=moves)


# ---------------------------------------------------------------- local state server for the browser tasks

STATE = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        body = open(os.path.join(HERE, "tasks/form.html"), "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        state = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        STATE[state.get("run")] = state
        self.send_response(204)
        self.end_headers()


def serve_forms():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


# ---------------------------------------------------------------- tasks: prepare (state + prompt variables) and check

class Ctx:
    def __init__(self, task, rep, run_id, scratch, server):
        self.task, self.rep, self.id, self.scratch, self.server = task, rep, run_id, scratch, server
        self.vars, self.pid, self.stale, self.skip, self.cleanup = {}, None, None, None, None
        self.sampler = None


def prep_calculator(c):
    a = 12 + c.rep
    c.expect = str(a * 7 + 5)
    c.vars = dict(a=a)
    shown = [clean(e.get("value", "")) for e in read_ax(c.pid)["elements"]]
    c.stale = c.expect in shown


def check_calculator(c):
    shown = [clean(e.get("value", "")) for e in read_ax(c.pid)["elements"]]
    return c.expect in shown, f"display values {shown[:4]}, expected {c.expect}"


def prep_textedit(c):
    marker = f"Benchmark scratch document {c.id}."
    lines = [marker] + open(os.path.join(HERE, "fixtures/bench.txt")).read().splitlines()[1:]
    escape = lambda s: s.replace("\\", "\\\\").replace("{", "\\{").replace("}", "\\}")
    path = os.path.join(c.scratch, f"bench-{c.id}.rtf")
    open(path, "w").write("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24 "
                          + "\\par\n".join(escape(l) for l in lines) + "}")
    c.marker, c.line = marker, f"Appended line {c.id}"
    c.vars = dict(file=os.path.basename(path), line=c.line)
    subprocess.run(["open", "-g", "-a", "TextEdit", path], check=False)
    if not wait_for(lambda: any(e.get("value", "").startswith(c.marker) for e in read_ax(c.pid)["elements"])):
        c.skip = "document did not open"


def check_textedit(c):
    areas = [e for e in read_ax(c.pid)["elements"] if e.get("value", "").startswith(c.marker)]
    if not areas:
        return None, "document not found after the run"
    area = areas[0]
    bold = "".join(r["text"] for r in area.get("runs", []) if "bold" in r["font"].lower())
    last = area["value"].rstrip().splitlines()[-1] if area["value"].strip() else ""
    ok = last == c.line and c.line in bold
    return ok, f"last line {last!r}, bold text {bold[-60:]!r}, fonts {sorted({r['font'] for r in area.get('runs', [])})}"


def prep_form(c):
    c.vars = dict(run=c.id, name=f"Bench{c.rep}", color=["Blue", "Green", "Blue"][c.rep % 3])
    url = f"http://127.0.0.1:{c.server.server_port}/form.html?run={c.id}"
    profile = os.environ.get("BENCH_CHROME_PROFILE")
    if c.task["app"] == "Google Chrome" and profile:
        # Chrome hands a URL to the running instance of that profile, so the page lands in the benchmark's Chrome.
        argv = ["open", "-g", "-n", "-a", "Google Chrome", "--args", f"--user-data-dir={profile}", url]
    else:
        argv = ["open", "-g", "-a", c.task["app"], url]
    subprocess.run(argv, check=False)
    if not wait_for(lambda: c.id in STATE):
        c.skip = "form page did not load"


def check_form(c):
    state = STATE.get(c.id) or {}
    want = dict(name=c.vars["name"], color=c.vars["color"], presses=3)
    got = {k: state.get(k) for k in want}
    return got == want, f"page state {got}, expected {want}"


def obsidian_vault():
    config = os.path.expanduser("~/Library/Application Support/obsidian/obsidian.json")
    vaults = list(json.load(open(config)).get("vaults", {}).values())
    return next((v["path"] for v in vaults if v.get("open")), vaults[0]["path"] if vaults else None)


def find_note(vault, title):
    for root, _, files in os.walk(vault):
        if f"{title}.md" in files:
            return os.path.join(root, f"{title}.md")


def prep_obsidian(c):
    c.vault = obsidian_vault()
    c.vars = dict(title=f"Bench note {c.id}")
    if not c.vault:
        c.skip = "no Obsidian vault found"
    elif find_note(c.vault, c.vars["title"]):
        c.stale = True


def check_obsidian(c):
    note = find_note(c.vault, c.vars["title"])
    if note:  # Moved, never deleted: the note is the agent's test output inside the person's vault.
        os.makedirs(os.path.join(c.scratch, "notes"), exist_ok=True)
        os.rename(note, os.path.join(c.scratch, "notes", os.path.basename(note)))
    return bool(note), f"note {'found' if note else 'missing'} in {c.vault}"


def prep_kitty(c):
    # The marker file is the oracle: the OCR models are missing on this Mac, and a file needs no OCR.
    c.out = os.path.join(c.scratch, f"kitty-{c.id}.txt")
    c.vars = dict(command=f"echo bench-ok-{c.id} | tee {c.out}")


def check_kitty(c):
    got = open(c.out).read().strip() if os.path.exists(c.out) else None
    return got == f"bench-ok-{c.id}", f"file content {got!r}"


def prep_photoshop(c):
    c.vars = {}
    c.baseline = set(read_ax(c.pid, titles_only=True).get("titles", []))
    c.sample_titles = True


def check_photoshop(c):
    final = set(read_ax(c.pid, titles_only=True).get("titles", []))
    new = {t for t in c.sampler.seen_titles - c.baseline if "Layer 1" in t}
    closed = final <= c.baseline
    # ponytail: the 800x600 size is not readable from a title, only the new document with its layer and the close are checked.
    return bool(new) and closed, f"new titles with a layer {sorted(new)}, closed again {closed}"


def prism_checkbox(c):
    return next((e for e in read_ax(c.pid)["elements"] if e["role"] == "AXCheckBox" and e.get("label") == "Meow"), None)


def prep_prism(c):
    box = prism_checkbox(c)
    c.vars, c.before = {}, box.get("value") if box else None
    if not box:
        c.skip = "Meow checkbox not in the AX tree of the front window"


def check_prism(c):
    box = prism_checkbox(c)
    after = box.get("value") if box else None
    return box is not None and after != c.before, f"Meow value {c.before!r} -> {after!r}"


HOOKS = {
    "calculator": (prep_calculator, check_calculator), "textedit": (prep_textedit, check_textedit),
    "chrome-form": (prep_form, check_form), "safari-form": (prep_form, check_form),
    "obsidian": (prep_obsidian, check_obsidian), "kitty": (prep_kitty, check_kitty),
    "photoshop": (prep_photoshop, check_photoshop), "prism-toggle": (prep_prism, check_prism),
    "selftest": (lambda c: setattr(c, "vars", {"word": f"w{c.id}"}),
                 lambda c: (c.id in c.final_text, "final message holds the run id")),
}


# ---------------------------------------------------------------- driver launch (minimal copy of compare.py's)

class Launch:
    """One MCP server config for `claude --mcp-config`; the embedded Cua daemon is our own child."""

    def __init__(self, driver, scratch, run_id):
        self.daemon, self.info = None, {}
        telemetry = {"CUA_DRIVER_RS_TELEMETRY_ENABLED": "0"}
        if driver == "mecum":
            support, knowledge = (os.path.join(scratch, f"{run_id}-{n}") for n in ("support", "knowledge"))
            os.makedirs(support), os.makedirs(knowledge)
            spec = dict(command=MECUM, args=[knowledge],
                        env=dict(MECUM_BENCH_UNVALIDATED="1", MECUM_APP_SUPPORT_DIR=support))
        elif driver == "cua":
            spec = dict(command=CUA, args=["mcp", "--direct"], env=telemetry)
        elif driver == "cua-overlay" and os.path.isdir(CUA_APP):
            self.info["launch"] = "app-daemon"
            spec = dict(command=CUA, args=["mcp"], env=telemetry)
        elif driver == "cua-overlay":
            self.info["launch"] = "embedded-daemon"
            socket_path = os.path.join(scratch, f"{run_id}-cua.sock")
            env = dict(os.environ, **telemetry, CUA_DRIVER_EMBEDDED="1")
            started = time.perf_counter()
            self.daemon = subprocess.Popen([CUA, "serve", "--embedded", "--socket", socket_path], stdin=subprocess.PIPE,
                                           stdout=open(os.path.join(scratch, "daemon.log"), "a"), stderr=subprocess.STDOUT, env=env)
            deadline = time.time() + 15
            while not os.path.exists(socket_path):
                if self.daemon.poll() is not None or time.time() > deadline:
                    raise RuntimeError("cua-driver serve --embedded did not open its socket")
                time.sleep(0.1)
            self.info["daemon_start_ms"] = (time.perf_counter() - started) * 1000
            spec = dict(command=CUA, args=["mcp", "--embedded", "--socket", socket_path],
                        env=dict(telemetry, CUA_DRIVER_EMBEDDED="1"))
        elif driver == "selftest":
            spec = dict(command=sys.executable, args=[os.path.abspath(__file__), "--fake-server"])
        else:
            raise ValueError(driver)
        self.config = json.dumps({"mcpServers": {"driver": spec}})

    def close(self):
        if self.daemon:
            self.daemon.stdin.close()  # the documented stop; terminate by PID if it lingers
            try:
                self.daemon.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.daemon.terminate()


def fake_server():
    """Stand-in MCP server for the harness self-test: one tool, one second of latency."""
    for line in sys.stdin:
        msg = json.loads(line)
        if "id" not in msg:
            continue
        method, result = msg["method"], {}
        if method == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "say", "description": "Returns the given word after a pause.",
                                 "inputSchema": {"type": "object", "properties": {"word": {"type": "string"}}, "required": ["word"]}}]}
        elif method == "tools/call":
            time.sleep(1)
            result = {"content": [{"type": "text", "text": "said " + msg["params"]["arguments"].get("word", "")}]}
        print(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}), flush=True)


# ---------------------------------------------------------------- one run

def claude_argv(launch, prompt_cfg):
    return [CLAUDE, "-p", "--model", CONFIG["model"], "--effort", CONFIG["effort"],
            "--output-format", "stream-json", "--verbose",
            "--mcp-config", launch.config, "--strict-mcp-config",
            "--tools", "", "--allowedTools", "mcp__driver", "--permission-mode", "dontAsk",
            # Quitting apps is outside every task and could end a process the harness does not own.
            "--disallowedTools", "mcp__driver__kill_app",
            "--system-prompt", CONFIG["system_prompt"], "--disable-slash-commands",
            "--setting-sources", "", "--no-session-persistence", "--max-budget-usd", "2"]


def parse_stream(events, t0):
    """events: [(arrival time, parsed line)]. Returns the run totals and the per-call rows."""
    calls, order, usage, result = {}, [], {}, {}
    last_result_at, init_at, text, message_ids, servers = None, None, "", [], {}
    for at, event in events:
        kind = event.get("type")
        if kind == "system" and event.get("subtype") == "init":
            init_at = last_result_at = at
            servers = {s["name"]: s["status"] for s in event.get("mcp_servers", [])}
        elif kind == "assistant":
            message = event["message"]
            if message["id"] not in message_ids:
                message_ids.append(message["id"])
            usage[message["id"]] = message.get("usage", {})
            for block in message["content"]:
                if block["type"] == "text":
                    text = block["text"]
                elif block["type"] == "tool_use":
                    calls[block["id"]] = dict(tool=block["name"].removeprefix("mcp__driver__"), t_use=at,
                                              think_ms=((at - last_result_at) * 1000) if last_result_at else None,
                                              turn=len(message_ids), args_chars=len(json.dumps(block["input"])),
                                              turn_input_tokens=sum(usage[message["id"]].get(k, 0) for k in
                                                                    ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")))
                    order.append(block["id"])
        elif kind == "user":
            content = event["message"]["content"]
            for block in content if isinstance(content, list) else []:
                if block.get("type") == "tool_result" and block["tool_use_id"] in calls:
                    call = calls[block["tool_use_id"]]
                    body = block["content"] if isinstance(block["content"], list) else [{"type": "text", "text": str(block["content"])}]
                    call.update(tool_ms=(at - call["t_use"]) * 1000, is_error=bool(block.get("is_error")),
                                result_chars=sum(len(b.get("text", "")) for b in body if b.get("type") == "text"),
                                result_images=sum(1 for b in body if b.get("type") == "image"))
                    last_result_at = at
        elif kind == "result":
            result = event
    totals = result.get("usage") or {}
    if not totals:  # no result event (timeout, kill): the last usage of each message
        totals = {k: sum(u.get(k, 0) for u in usage.values()) for k in
                  ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")}
    return dict(servers=servers, init_s=(init_at - t0) if init_at else None, final_message=result.get("result", text),
                result_subtype=result.get("subtype"), is_error=result.get("is_error"), turns=result.get("num_turns", len(message_ids)),
                cost_usd=result.get("total_cost_usd"), api_ms=result.get("duration_api_ms"), usage=totals), [calls[i] for i in order]


def run_one(task, driver, rep, scratch, out, server):
    run_id = f"{int(time.time()) % 100000}{rep}{DRIVERS.index(driver) if driver in DRIVERS else 9}"
    ctx = Ctx(task, rep, run_id, scratch, server)
    row = dict(kind="run", run_id=run_id, driver=driver, task=task["id"], rep=rep, model=CONFIG["model"], effort=CONFIG["effort"],
               outside_declared_support=driver in task.get("outside_declared_support", []), started=time.strftime("%Y-%m-%dT%H:%M:%S"))
    prepare, check = HOOKS[task["id"]]
    ctx.pid = ensure_app(task.get("app", task["process"]), task["process"]) if task["id"] != "selftest" else os.getpid()
    if ctx.pid is None:
        return write(out, dict(row, status="skipped", reason="app not running"))
    prepare(ctx)
    if ctx.skip or ctx.stale:
        return write(out, dict(row, status="skipped", reason=ctx.skip or "check already true before the run"))
    prompt = CONFIG["preamble"] + task["prompt"].format(**ctx.vars) if task["id"] != "selftest" else task["prompt"].format(**ctx.vars)
    launch = Launch(driver, scratch, run_id)
    front0 = run_json([PROBE, str(ctx.pid)])
    ctx.sampler = Sampler(ctx.pid, getattr(ctx, "sample_titles", False))
    events, lines = [], []
    t0 = time.time()
    proc = subprocess.Popen(claude_argv(launch, task), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, cwd=scratch, start_new_session=True,
                            env=dict(os.environ, CLAUDE_CODE_DISABLE_AUTO_MEMORY="1"))
    ctx.sampler.start()

    def reader():
        for line in proc.stdout:
            at = time.time()
            lines.append(line)
            try:
                events.append((at, json.loads(line)))
            except ValueError:
                pass
    reading = threading.Thread(target=reader, daemon=True)
    reading.start()
    proc.stdin.write(prompt)
    proc.stdin.close()
    stop = None
    deadline = t0 + task["timeout_s"]
    while proc.poll() is None:
        turns = len({e["message"]["id"] for _, e in events if e.get("type") == "assistant"})
        if time.time() > deadline:
            stop = "timeout"
        elif turns > CONFIG["max_turns"]:
            stop = "max_turns"
        if stop:
            proc.terminate()  # our own child: SIGTERM lets claude close the MCP server's stdin first
            try:
                proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, 9)
            break
        time.sleep(0.25)
    wall = time.time() - t0
    reading.join(timeout=5)
    ctx.sampler.stop_flag.set()
    ctx.sampler.join(timeout=10)
    launch.close()
    stderr = proc.stderr.read()[-500:]
    summary, calls = parse_stream(events, t0)
    ctx.final_text = summary["final_message"] or ""
    try:
        ok, detail = check(ctx)
    except Exception as error:
        ok, detail = None, f"check failed: {error}"
    os.makedirs(os.path.join(scratch, "streams"), exist_ok=True)
    open(os.path.join(scratch, "streams", f"{run_id}-{driver}-{task['id']}.jsonl"), "w").writelines(lines)
    usage = summary["usage"]
    billed = sum(usage.get(k, 0) for k in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
    tool_ms = [c["tool_ms"] for c in calls if "tool_ms" in c]
    row.update(status="done", stop=stop, success=ok, check=detail, wall_s=wall, init_s=summary["init_s"], turns=summary["turns"],
               tool_calls=len(calls), tool_errors=sum(1 for c in calls if c.get("is_error")), tool_ms_total=sum(tool_ms),
               input_tokens=usage.get("input_tokens", 0), output_tokens=usage.get("output_tokens", 0),
               cache_creation_tokens=usage.get("cache_creation_input_tokens", 0), cache_read_tokens=usage.get("cache_read_input_tokens", 0),
               billed_tokens=billed, cost_usd=summary["cost_usd"], api_ms=summary["api_ms"], mcp=summary["servers"],
               final_message=summary["final_message"], claude_stderr=stderr or None, **launch.info,
               **ctx.sampler.intrusion(front0.get("frontmost"), tuple(front0.get("cursor") or ())))
    write(out, row)
    for i, call in enumerate(calls):
        write(out, dict(kind="tool", run_id=run_id, driver=driver, task=task["id"], rep=rep, idx=i,
                        **{k: v for k, v in call.items() if k not in ("t_use",)}), quiet=True)
    return row


def write(out, row, quiet=False):
    out.write(json.dumps(row) + "\n")
    out.flush()
    if not quiet:
        print(f"  {row['task']:13} {row['driver']:11} r{row['rep']} {row.get('status')} "
              + (f"success={row.get('success')} wall={row.get('wall_s', 0):.0f}s calls={row.get('tool_calls')} "
                 f"tokens={row.get('billed_tokens')} cost={row.get('cost_usd')} | {row.get('check') or row.get('reason')}"
                 if row.get("status") == "done" else row.get("reason", "")), flush=True)
    return row


# ---------------------------------------------------------------- summary

def pct(values, q):
    values = sorted(v for v in values if v is not None and v == v)
    if not values:
        return None
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def wilson(successes, n, z=1.96):
    if n == 0:
        return None
    p = successes / n
    centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return [round(max(0, centre - half), 3), round(min(1, centre + half), 3)]


def stats(values):
    return dict(median=pct(values, 0.5), p90=pct(values, 0.9))


def cell(runs, tools):
    done = [r for r in runs if r["status"] == "done"]
    decided = [r for r in done if r["success"] is not None]
    wins = sum(1 for r in decided if r["success"])
    return dict(
        runs=len(runs), skipped=len(runs) - len(done), inconclusive=len(done) - len(decided),
        success=dict(count=wins, of=len(decided), wilson95=wilson(wins, len(decided))),
        wall_s=stats([r["wall_s"] for r in done]), billed_tokens=stats([r["billed_tokens"] for r in done]),
        cost_usd=stats([r["cost_usd"] for r in done]), tool_calls=stats([r["tool_calls"] for r in done]),
        tool_ms=stats([t["tool_ms"] for t in tools if "tool_ms" in t]), think_ms=stats([t["think_ms"] for t in tools if t.get("think_ms") is not None]),
        tool_errors=sum(r["tool_errors"] for r in done),
        intrusion=dict(focus_changes=sum(r["focus_changes"] for r in done), cursor_moves=sum(r["cursor_moves"] for r in done),
                       runs_with_any=sum(1 for r in done if r["focus_changes"] or r["cursor_moves"])),
        outside_declared_support=any(r["outside_declared_support"] for r in runs))


def summarize(paths, out_path):
    rows = [json.loads(l) for p in paths for l in open(p) if l.strip()]
    runs = [r for r in rows if r["kind"] == "run"]
    tools = [r for r in rows if r["kind"] == "tool"]
    result = {}
    for driver in sorted({r["driver"] for r in runs}):
        mine = [r for r in runs if r["driver"] == driver]
        keep = lambda rs: [t for t in tools if t["run_id"] in {r["run_id"] for r in rs}]
        supported = [r for r in mine if not r["outside_declared_support"]]
        result[driver] = dict(
            tasks={t: cell([r for r in mine if r["task"] == t], keep([r for r in mine if r["task"] == t]))
                   for t in sorted({r["task"] for r in mine})},
            all_runs=cell(mine, keep(mine)), within_declared_support=cell(supported, keep(supported)))
    json.dump(result, open(out_path, "w"), indent=1)
    for driver, body in result.items():
        for name, c in {**body["tasks"], "ALL(supported)": body["within_declared_support"]}.items():
            s = c["success"]
            print(f"{driver:11} {name:15} ok {s['count']}/{s['of']} {s['wilson95']} wall med {c['wall_s']['median']} "
                  f"tokens med {c['billed_tokens']['median']} calls med {c['tool_calls']['median']} intr {c['intrusion']['runs_with_any']}")


# ---------------------------------------------------------------- main

def plan(tasks, drivers, reps):
    # Rep-major so a time cap leaves complete reps; the driver order flips every rep (ABC, CBA, ...).
    return [(t, d, r) for r in range(reps) for t in tasks for d in (drivers if r % 2 == 0 else drivers[::-1])]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", metavar="OUT.json")
    parser.add_argument("inputs", nargs="*", help="JSONL files for --summary")
    parser.add_argument("--out")
    parser.add_argument("--scratch")
    parser.add_argument("--tasks", default=",".join(t["id"] for t in CONFIG["tasks"]))
    parser.add_argument("--drivers", default=",".join(DRIVERS), help="mecum, cua, cua-overlay (selftest: the fake server)")
    parser.add_argument("--reps", type=int, default=3)
    parser.add_argument("--max-minutes", type=float, default=60)
    parser.add_argument("--dry-run", action="store_true", help="print the plan and estimate only")
    parser.add_argument("--fake-server", action="store_true", help=argparse.SUPPRESS)
    options = parser.parse_args()
    if options.fake_server:
        return fake_server()
    if options.summary:
        return summarize(options.inputs, options.summary)
    catalog = {t["id"]: t for t in CONFIG["tasks"]}
    catalog["selftest"] = dict(id="selftest", process="python", est_s=15, timeout_s=90,
                               prompt="Call the say tool with the word {word}, then reply with that word only.")
    tasks, drivers = [catalog[t] for t in options.tasks.split(",")], options.drivers.split(",")
    runs = plan(tasks, drivers, options.reps)
    estimate = sum(t["est_s"] + 20 for t, _, _ in runs) / 60
    print(f"{len(runs)} runs ({len(tasks)} tasks x {len(drivers)} drivers x {options.reps} reps), estimate {estimate:.0f} min "
          f"(cap {options.max_minutes:.0f} min: later reps are dropped when it is reached)", flush=True)
    if options.dry_run:
        return
    if not (options.out and options.scratch):
        parser.error("--out and --scratch are required")
    os.makedirs(options.scratch, exist_ok=True)
    out = open(options.out, "a")
    server = serve_forms() if any(t["id"].endswith("-form") for t in tasks) else None
    started = time.time()
    for task, driver, rep in runs:
        if (time.time() - started) / 60 > options.max_minutes:
            print("time cap reached, stopping", flush=True)
            break
        run_one(task, driver, rep, options.scratch, out, server)


if __name__ == "__main__":
    main()
