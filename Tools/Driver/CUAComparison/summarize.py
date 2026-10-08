"""Tables and a machine-readable summary from the JSONL rows compare.py writes.

    python3 summarize.py results.jsonl [more.jsonl ...] > tables.md
    python3 summarize.py results.jsonl --json summary.json

It also reads the 6 October 2026 `all.jsonl` (older rows lack fields; those aggregates are null).
Rows of a `--phases` run never enter the timing aggregates; they are only counted.

summary.json: {"meta": [meta rows], "baseline": {...}, "drivers": {driver: {"footprint_mb": {...},
"apps": {app: {"framework", "ops": {op: {...}}, "steps": {op: {...}}, "reads": {...}, "idle": {...},
"intrusion": {...}, "chain": {...}, "soak": {...}, "aborted": [...]}}}}}
"""
import argparse, json, math, statistics, sys
from collections import Counter

TEXT_CHARS_PER_TOKEN = 4  # a rough English/JSON average; images use Anthropic's w*h/750
DRIVERS = ["mecum", "cua", "cua-overlay", "cua-legacy", "cua-fast"]
NOT_ACTIONS = {"observe", "observe_unchanged", "observe_after", "list_windows", "open_session", "close_session",
               "idle", "baseline", "startup", "soak_mem", "chain_step", "block_aborted", "target"}
BAD_STATUS = {"error", "refused", "failed", "honest_miss", "ambiguous"}
OPS_ORDER = ["list_windows", "open_session", "observe", "observe_unchanged", "click", "click_back", "type", "undo",
             "key", "key_close", "hotkey", "scroll_down", "scroll_up", "menu", "menu_back", "new_doc",
             "new_doc_confirm", "menu_rotate", "menu_rotate_back", "close_doc", "dont_save", "close_session"]


def order(op):
    return OPS_ORDER.index(op) if op in OPS_ORDER else 99


def rows(paths):
    for path in paths:
        for line in open(path):
            if line.strip():
                yield json.loads(line)


def pct(values, q):
    values = sorted(v for v in values if v is not None and v == v)
    if not values:
        return None
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def med(values):
    return pct(values, .5)


def stats(values):
    """Latency-style statistics of the finite values, all null when there are none."""
    values = [v for v in values if v is not None and v == v]
    if not values:
        return dict(n=0, p50=None, p90=None, p99=None, mean=None, stdev=None, min=None, max=None)
    return dict(n=len(values), p50=pct(values, .5), p90=pct(values, .9), p99=pct(values, .99),
                mean=statistics.fmean(values), stdev=statistics.stdev(values) if len(values) > 1 else 0.0,
                min=min(values), max=max(values))


def wilson(successes, n, z=1.96):
    """Wilson score interval of a proportion, [low, high]; None when n is 0."""
    if not n:
        return None
    p = successes / n
    centre = (p + z * z / (2 * n)) / (1 + z * z / n)
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / (1 + z * z / n)
    return [max(0.0, centre - half), min(1.0, centre + half)]


def slope(points):
    """Least-squares slope of (x, y) points, y per unit x; None with fewer than two distinct x."""
    points = [(x, y) for x, y in points if y is not None]
    if len({x for x, _ in points}) < 2:
        return None
    mx, my = statistics.fmean(x for x, _ in points), statistics.fmean(y for _, y in points)
    return sum((x - mx) * (y - my) for x, y in points) / sum((x - mx) ** 2 for x, _ in points)


def tokens(row):
    return (row.get("text_chars") or 0) / TEXT_CHARS_PER_TOKEN + (row.get("image_tokens") or 0)


def per_second(row, key):
    return row[key] / (row["ms"] / 1000) if row.get(key) is not None and row.get("ms") else None


def reported_ok(row):
    """The call succeeded and did not say honest_miss, ambiguous or refused (also in old rows)."""
    return bool(row.get("ok")) and row.get("self_verdict") not in BAD_STATUS


def success_of(row):
    """True / False / None (unverified): an action whose effect the independent probe confirmed."""
    if "success" in row:
        return row["success"]
    return False if not reported_ok(row) else None


def f(value, digits=0):
    return "-" if value is None else f"{value:,.{digits}f}"


def table(header, lines):
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    return "\n".join(out + ["| " + " | ".join(str(c) for c in line) + " |" for line in lines])


def build_steps(data):
    """One record per agent step: the action row with the observation that follows it, in file order.
    Mecum's action reply already has the scene and Cua's run_actions reply has its diff; a menu or a
    cua-legacy action adds its observe_after row."""
    last, steps = {}, []
    for r in data:
        key = (r.get("driver"), r.get("app"))
        if r.get("op") == "observe_after" and key in last and r.get("after_op", last[key]["op"]) == last[key]["op"]:
            s = last[key]
            s["ms"] = s["ms"] + r["ms"] if s["ms"] is not None and r.get("ms") is not None else None
            s["ok"] = s["ok"] and bool(r.get("ok"))
            s["text"] += (r.get("text_chars") or 0) / TEXT_CHARS_PER_TOKEN
            s["image"] += r.get("image_tokens") or 0
            s["driver_cpu_ms"] = (s["driver_cpu_ms"] or 0) + (r.get("driver_cpu_ms") or 0)
        elif r.get("op") not in NOT_ACTIONS and r.get("app"):
            s = dict(driver=r["driver"], app=r["app"], op=r["op"], rep=r.get("rep"), ms=r.get("ms"),
                     ok=reported_ok(r), series=r.get("series", "step"),
                     text=(r.get("text_chars") or 0) / TEXT_CHARS_PER_TOKEN, image=r.get("image_tokens") or 0,
                     driver_cpu_ms=r.get("driver_cpu_ms"))
            last[key] = s
            steps.append(s)
    return steps


def op_summary(rs):
    """Everything per (driver, app, op): latency, robustness, tokens, CPU."""
    ok = [r for r in rs if reported_ok(r)]
    verdicts = [success_of(r) for r in rs]
    checkable = [v for v in verdicts if v is not None]
    wins = sum(1 for v in checkable if v)
    return dict(
        n=len(rs), n_ok=len(ok), ok_rate=len(ok) / len(rs) if rs else None, ok_wilson95=wilson(len(ok), len(rs)),
        n_checkable=len(checkable), n_confirmed=wins, n_unverified=len(verdicts) - len(checkable),
        success_rate=wins / len(checkable) if checkable else None, success_wilson95=wilson(wins, len(checkable)),
        latency_ms=stats([r.get("ms") for r in ok]),
        tokens=dict(text=med([(r.get("text_chars") or 0) / TEXT_CHARS_PER_TOKEN for r in rs]),
                    image=med([r.get("image_tokens") or 0 for r in rs]), total=med([tokens(r) for r in rs])),
        cpu=dict(driver_ms=med([r.get("driver_cpu_ms") for r in rs]),
                 driver_ms_per_s=med([per_second(r, "driver_cpu_ms") for r in rs]),
                 proxy_ms=med([r.get("proxy_cpu_ms") for r in rs]),
                 app_ms=med([r.get("app_cpu_ms") for r in rs]),
                 app_ms_per_s=med([per_second(r, "app_cpu_ms") for r in rs]),
                 windowserver_ms=med([r.get("windowserver_cpu_ms") for r in rs])),
        energy_mj=dict(driver=med([r.get("driver_energy_mj") for r in rs]), app=med([r.get("app_energy_mj") for r in rs])),
        failures=dict(Counter((r.get("error") or r.get("self_verdict") or "unconfirmed")[:100]
                              for r in rs if not reported_ok(r) or success_of(r) is False).most_common(3)))


def step_summary(steps):
    good = [s for s in steps if s["ok"]]
    return dict(n=len(steps), n_ok=len(good),
                series=Counter(s["series"] for s in steps).most_common(1)[0][0] if steps else None,
                latency_ms=stats([s["ms"] for s in good]),
                tokens=dict(text=med([s["text"] for s in good]), image=med([s["image"] for s in good]),
                            total=med([s["text"] + s["image"] for s in good])),
                driver_cpu_ms=med([s["driver_cpu_ms"] for s in good]))


def intrusion(rs):
    probed = [r for r in rs if r.get("frontmost_changed") is not None]
    count = lambda key: sum(1 for r in probed if r.get(key))
    return dict(calls=len(probed), frontmost_changed=count("frontmost_changed"), cursor_moved=count("cursor_moved"),
                cursor_moved_during_call=sum(1 for r in rs if r.get("cursor_moved_call")),
                window_on_user_display=count("window_on_user_display"))


def idle_summary(rs, baseline_per_s):
    out = {}
    for window in sorted({r.get("window", 1) for r in rs}):
        w = [r for r in rs if r.get("window", 1) == window]
        ws = med([per_second(r, "windowserver_cpu_ms") for r in w])
        out[f"window_{window}"] = dict(
            n=len(w), t_since_last_call_s=med([r.get("since_last_call_s") for r in w]),
            driver_ms_per_s=med([per_second(r, "driver_cpu_ms") for r in w]),
            proxy_ms_per_s=med([per_second(r, "proxy_cpu_ms") for r in w]),
            app_ms_per_s=med([per_second(r, "app_cpu_ms") for r in w]),
            windowserver_ms_per_s=ws,
            windowserver_over_baseline_ms_per_s=None if ws is None or baseline_per_s is None else ws - baseline_per_s,
            wakeups_per_s=med([per_second(r, "driver_wakeups") for r in w]))
    return out


def chain_summary(rs):
    out = {}
    for pause in sorted({r["pause_s"] for r in rs}):
        g = [r for r in rs if r["pause_s"] == pause and r.get("ok")]
        by_index = {i: med([r["ms"] for r in g if r["chain_step"] == i]) for i in sorted({r["chain_step"] for r in g})}
        out[str(pause)] = dict(n=len(g), step_ms=stats([r["ms"] for r in g]), step_ms_by_index=by_index,
                               gap_s_median=med([r.get("gap_s") for r in g]), first_step_ms=by_index.get(1),
                               later_steps_ms=med([r["ms"] for r in g if r["chain_step"] > 1]))
    resting = [r["ms"] for r in rs if r.get("ok") and r.get("stream_resting") is True]
    warm = [r["ms"] for r in rs if r.get("ok") and r.get("stream_resting") is False]
    out["wake"] = dict(resting_steps=len(resting), warm_steps=len(warm), resting_p50_ms=med(resting), warm_p50_ms=med(warm),
                       wake_cost_ms=med(resting) - med(warm) if resting and warm else None,
                       basis="stream resting inferred from the gap since the last call (> 2.5 s, ADR 0036); mecum only")
    return out


def soak_summary(mem, calls):
    mem = sorted(mem, key=lambda r: r["soak_step"])
    per_100 = lambda key: (lambda s: None if s is None else s * 100)(slope([(r["soak_step"], r.get(key)) for r in mem]))
    lat = [r["ms"] for r in sorted(calls, key=lambda r: r.get("soak_step", 0)) if r.get("ok") and r.get("ms") is not None]
    mid = med(lat)
    return dict(steps=max((r["soak_step"] for r in mem), default=0), samples=len(mem),
                driver_footprint_mb=dict(first=mem[0].get("driver_footprint_mb"), last=mem[-1].get("driver_footprint_mb"),
                                         slope_mb_per_100_steps=per_100("driver_footprint_mb")),
                app_footprint_mb=dict(slope_mb_per_100_steps=per_100("app_footprint_mb")),
                errors=sum(1 for r in calls if not r.get("ok")),
                stalls=sum(1 for r in calls if str(r.get("error", "")).startswith("stall")
                           or (mid and r.get("ms") and r["ms"] > max(10 * mid, 10_000))),
                latency_ms=stats(lat), latency_drift_ms=med(lat[-50:]) - med(lat[:50]) if len(lat) >= 20 else None)


def summarize(paths):
    all_rows = list(rows(paths))
    meta = [r for r in all_rows if r.get("kind") == "meta"]
    data = [r for r in all_rows if r.get("kind") != "meta"]
    phases = [r for r in data if r.get("phases")]
    data = [r for r in data if not r.get("phases")]
    base = [r for r in data if r.get("op") == "baseline" and r.get("windowserver_cpu_ms") is not None]
    baseline_per_s = med([r["windowserver_cpu_ms"] / (r["ms"] / 1000) for r in base])
    ops_rows = [r for r in data if r.get("mode", "ops") == "ops"]
    kept = ("open_session", "close_session", "list_windows", "idle", "baseline", "startup")
    measured = [r for r in ops_rows if r.get("rep", 1) != 0 or r.get("op") in kept]
    drivers = sorted({r["driver"] for r in data if r.get("driver") not in (None, "none")},
                     key=lambda d: DRIVERS.index(d) if d in DRIVERS else 99)
    result = dict(meta=meta, baseline=dict(windowserver_ms_per_s=baseline_per_s, samples=len(base),
                                          windows_with_cursor_move=sum(1 for r in base if r.get("cursor_moved_call"))),
                  phases_rows_excluded=len(phases), drivers={})
    steps = [s for s in build_steps(ops_rows) if s["rep"] != 0]
    for driver in drivers:
        mine = [r for r in data if r.get("driver") == driver]
        footprints = [r.get("driver_footprint_mb") for r in mine if r.get("op") != "idle"]
        peaks = [x for x in [r.get("driver_peak_mb") for r in mine] + footprints if x is not None]
        entry = dict(footprint_mb=dict(median=med(footprints), peak=max(peaks, default=None)),
                     startup_ms=med([r["ms"] for r in mine if r.get("op") == "startup"]),
                     launch=next((r.get("launch") for r in mine if r.get("op") == "startup" and r.get("launch")), None),
                     apps={})
        for app in sorted({r["app"] for r in mine if r.get("app")}):
            a = [r for r in mine if r.get("app") == app]
            app_ops = [r for r in measured if r.get("driver") == driver and r.get("app") == app]
            names = sorted({r["op"] for r in app_ops} - {"idle", "baseline", "startup"}, key=order)
            app_steps = [s for s in steps if s["driver"] == driver and s["app"] == app]
            actions = [r for r in app_ops if r["op"] not in NOT_ACTIONS]
            chain = [r for r in a if r.get("op") == "chain_step"]
            soak_mem = [r for r in a if r.get("op") == "soak_mem"]
            ops = {op: op_summary([r for r in app_ops if r["op"] == op]) for op in names}
            entry["apps"][app] = dict(
                framework=next((r.get("framework") for r in a if r.get("framework")), None), ops=ops,
                steps={op: step_summary([s for s in app_steps if s["op"] == op]) for op in sorted({s["op"] for s in app_steps}, key=order)},
                reads=dict(full=ops.get("observe"), unchanged=ops.get("observe_unchanged")),
                idle=idle_summary([r for r in a if r.get("op") == "idle" and r.get("mode", "ops") == "ops"], baseline_per_s),
                intrusion=intrusion([r for r in a if r.get("op") not in ("idle", "baseline", "startup")
                                     and r.get("mode", "ops") == "ops"]),
                actions=op_summary(actions), chain=chain_summary(chain) if chain else None,
                soak=soak_summary(soak_mem, [r for r in a if r.get("mode") == "soak" and r.get("op") not in NOT_ACTIONS])
                if soak_mem else None,
                aborted=[r.get("error") for r in a if r.get("op") == "block_aborted"])
        result["drivers"][driver] = entry
    return result


def report(s):
    out = []
    drivers = list(s["drivers"])
    apps = sorted({(a, d["apps"][a]["framework"]) for d in s["drivers"].values() for a in d["apps"]}, key=lambda x: str(x[1]))
    for m in s["meta"][:1]:
        machine = m.get("machine", {})
        out.append(f"## Run\n\n{machine.get('model')} {machine.get('chip')} · {machine.get('ram_gb')} GB · "
                   f"macOS {machine.get('macos')} ({machine.get('build')}) · drivers {json.dumps(m.get('drivers'))}\n\n"
                   f"blockers: {m.get('blockers')} · warnings: {m.get('warnings')}\n")
    out.append("## Latency per operation (ms: p50 / p90 / p99, stdev; ok/n; confirmed/checkable [Wilson 95%])\n")
    for app, framework in apps:
        lines = []
        names = sorted({o for d in drivers for o in s["drivers"][d]["apps"].get(app, {}).get("ops", {})}, key=order)
        for op in names:
            cells = []
            for d in drivers:
                o = s["drivers"][d]["apps"].get(app, {}).get("ops", {}).get(op)
                if not o:
                    cells.append("-")
                    continue
                l, w = o["latency_ms"], o["success_wilson95"]
                cells.append(f"{f(l['p50'])} / {f(l['p90'])} / {f(l['p99'])}, sd {f(l['stdev'])}; {o['n_ok']}/{o['n']}"
                             + (f"; {o['n_confirmed']}/{o['n_checkable']} [{w[0]:.2f}-{w[1]:.2f}]" if w else "; unverified"))
            lines.append([op] + cells)
        out.append(f"### {app} ({framework})\n\n" + table(["operation"] + drivers, lines) + "\n")
    out.append("## Equivalent step (ms p50 / p90 / p99; tokens text+image=total)\n\n"
               "Mecum: the action reply already has the scene. Cua: run_actions with observe (one call; a menu adds its "
               "diff read). cua-legacy: the action plus a full get_window_state, the series comparable with 6 October.\n")
    lines = []
    for app, _ in apps:
        for op in sorted({o for d in drivers for o in s["drivers"][d]["apps"].get(app, {}).get("steps", {})}, key=order):
            cells = []
            for d in drivers:
                st = s["drivers"][d]["apps"].get(app, {}).get("steps", {}).get(op)
                l = st and st["latency_ms"]
                cells.append("-" if not st else f"{f(l['p50'])} / {f(l['p90'])} / {f(l['p99'])}; "
                             f"{f(st['tokens']['text'])}+{f(st['tokens']['image'])}={f(st['tokens']['total'])}")
            lines.append([f"{app} · {op}"] + cells)
    out.append(table(["step"] + drivers, lines) + "\n")
    out.append("## Reads: full and unchanged (Mecum) or diff (Cua)\n")
    lines = []
    for app, _ in apps:
        for d in drivers:
            for kind, o in s["drivers"][d]["apps"].get(app, {}).get("reads", {}).items():
                if o:
                    t = o["tokens"]
                    lines.append([app, d, kind, f(o["latency_ms"]["p50"]), f(t["text"]), f(t["image"]), f(t["total"])])
    out.append(table(["app", "driver", "read", "ms p50", "text tokens", "image tokens", "total"], lines) + "\n")
    out.append("## CPU per action call (median) and driver memory\n")
    lines = []
    for app, _ in apps:
        for d in drivers:
            a = s["drivers"][d]["apps"].get(app)
            if a and a["actions"]["n"]:
                c = a["actions"]["cpu"]
                lines.append([app, d, f(c["driver_ms"], 1), f(c["driver_ms_per_s"], 0), f(c["app_ms"], 1),
                              f(c["app_ms_per_s"], 0), f(c["windowserver_ms"], 0)])
    out.append(table(["app", "driver", "driver ms", "driver ms/s", "app ms", "app ms/s", "WindowServer ms (10 ms ticks)"], lines) + "\n")
    out.append(table(["driver", "startup ms", "footprint MB median", "peak MB"],
                     [[d, f(e["startup_ms"]), f(e["footprint_mb"]["median"], 1), f(e["footprint_mb"]["peak"], 1)]
                      for d, e in s["drivers"].items()]) + "\n")
    out.append("## Idle (ms of CPU per second, consecutive windows after the last call)\n\n"
               f"WindowServer baseline without a driver: {f(s['baseline']['windowserver_ms_per_s'], 0)} ms/s.\n")
    lines = []
    for app, _ in apps:
        for d in drivers:
            for name, w in s["drivers"][d]["apps"].get(app, {}).get("idle", {}).items():
                lines.append([app, d, name, f(w["t_since_last_call_s"], 0), f(w["driver_ms_per_s"], 2),
                              f(w["proxy_ms_per_s"], 2), f(w["app_ms_per_s"], 2),
                              f(w["windowserver_over_baseline_ms_per_s"], 0), f(w["wakeups_per_s"], 1)])
    out.append(table(["app", "driver", "window", "t since call s", "driver", "proxy", "app", "WS over baseline", "wakeups/s"], lines) + "\n")
    out.append("## Intrusion seen by the independent probe\n")
    lines = []
    for app, _ in apps:
        for d in drivers:
            i = s["drivers"][d]["apps"].get(app, {}).get("intrusion")
            if i and i["calls"]:
                lines.append([app, d, i["calls"], i["frontmost_changed"], i["cursor_moved"], i["window_on_user_display"]])
    out.append(table(["app", "driver", "calls probed", "frontmost changed", "cursor moved", "window on user display"], lines) + "\n")
    chain_lines, soak_lines = [], []
    for app, _ in apps:
        for d in drivers:
            a = s["drivers"][d]["apps"].get(app, {})
            for pause, c in (a.get("chain") or {}).items():
                if pause != "wake":
                    chain_lines.append([app, d, pause, f(c["step_ms"]["p50"]), f(c["step_ms"]["p90"]),
                                        f(c["first_step_ms"]), f(c["later_steps_ms"])])
            if a.get("chain"):
                w = a["chain"]["wake"]
                chain_lines.append([app, d, "wake", f"resting {f(w['resting_p50_ms'])} ({w['resting_steps']})",
                                    f"warm {f(w['warm_p50_ms'])} ({w['warm_steps']})", "cost " + f(w["wake_cost_ms"]), ""])
            if a.get("soak"):
                k = a["soak"]
                soak_lines.append([app, d, k["steps"], f(k["driver_footprint_mb"]["slope_mb_per_100_steps"], 2),
                                   f(k["app_footprint_mb"]["slope_mb_per_100_steps"], 2), k["errors"], k["stalls"],
                                   f(k["latency_drift_ms"])])
    if chain_lines:
        out.append("## Chain: step ms by pause between steps\n\n" + table(
            ["app", "driver", "pause s", "p50", "p90", "first step", "later steps"], chain_lines) + "\n")
    if soak_lines:
        out.append("## Soak\n\n" + table(["app", "driver", "steps", "driver MB/100 steps", "app MB/100 steps", "errors",
                                          "stalls", "latency drift ms"], soak_lines) + "\n")
    out.append("## Failures (most common per operation)\n")
    for d in drivers:
        for app, a in s["drivers"][d]["apps"].items():
            for op, o in a["ops"].items():
                out += [f"- {d} · {app} · {op} x{count}: {error}" for error, count in o["failures"].items()]
            out += [f"- {d} · {app} block aborted: {e}" for e in a["aborted"]]
    if s["phases_rows_excluded"]:
        out.append(f"\n{s['phases_rows_excluded']} rows of a phases run were left out of every timing aggregate.")
    return "\n".join(out)


def selftest():
    low, high = wilson(8, 8)
    assert abs(low - 0.6756) < 1e-3 and high == 1.0 and wilson(0, 0) is None
    assert abs(slope([(10, 100), (20, 101), (30, 102)]) - 0.1) < 1e-9 and slope([(1, 1)]) is None
    assert stats([1, 2, 3, 4])["p50"] == 2.5 and stats([])["n"] == 0
    steps = build_steps([dict(driver="cua", app="A", op="click", rep=1, ms=10, ok=True),
                         dict(driver="cua", app="A", op="observe_after", rep=1, ms=5, ok=True, after_op="click"),
                         dict(driver="mecum", app="A", op="click", rep=1, ms=7, ok=True, self_verdict="honest_miss")])
    assert [s["ms"] for s in steps] == [15, 7] and [s["ok"] for s in steps] == [True, False]
    print("summarize selftest ok")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="*")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--json", help="write the full summary here")
    options = parser.parse_args()
    if options.selftest or not options.files:
        return selftest()
    summary = summarize(options.files)
    if options.json:
        with open(options.json, "w") as out:
            json.dump(summary, out, indent=1, default=str)
    print(report(summary))


if __name__ == "__main__":
    main()
