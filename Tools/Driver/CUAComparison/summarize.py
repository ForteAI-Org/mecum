"""Markdown tables from the JSONL rows compare.py writes.

    python3 summarize.py results.jsonl [more.jsonl ...] > tables.md
"""
import json, statistics, sys
from collections import defaultdict

DRIVERS = ["mecum", "cua", "cua-overlay"]
TEXT_CHARS_PER_TOKEN = 4  # a rough English/JSON average; images use Anthropic's w*h/750


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


def fmt(value, digits=0):
    return "—" if value is None else f"{value:,.{digits}f}"


def tokens(row):
    return (row.get("text_chars") or 0) / TEXT_CHARS_PER_TOKEN + (row.get("image_tokens") or 0)


def table(header, lines):
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c) for c in line) + " |" for line in lines]
    return "\n".join(out)


def main(paths):
    data = [r for r in rows(paths) if r.get("rep", 1) != 0 or r.get("op") in ("open_session", "close_session", "list_windows", "idle", "baseline", "startup")]
    by = defaultdict(list)
    for r in data:
        by[(r.get("app"), r.get("framework"), r.get("op"), r.get("driver"))].append(r)
    apps = sorted({(r["app"], r["framework"]) for r in data if r.get("app")}, key=lambda a: a[1])
    ops_order = ["list_windows", "open_session", "observe", "observe_unchanged", "click", "click_back", "type", "key", "key_close", "hotkey",
                 "scroll_down", "scroll_up", "menu", "menu_back", "close_session"]

    print("## Latency per operation (ms, median / p95, successes / attempts)\n")
    for app, framework in apps:
        lines = []
        for op in ops_order:
            cells = []
            seen = False
            for driver in DRIVERS:
                rs = by.get((app, framework, op, driver), [])
                if op == "observe_unchanged" and driver != "mecum":
                    rs = []
                if not rs:
                    cells.append("—")
                    continue
                seen = True
                good = [r["ms"] for r in rs if r["ok"]]
                cells.append(f"{fmt(pct(good, .5))} / {fmt(pct(good, .95))} ({len(good)}/{len(rs)})")
            if seen:
                lines.append([op] + cells)
        print(f"### {app} ({framework})\n")
        print(table(["operation"] + DRIVERS, lines) + "\n")

    print("## Agent step: action plus the observation an agent needs after it (ms, median)\n")
    print("Mecum's act and input tools return the scene after acting; Cua's actions do not, so a Cua step "
          "is the action plus the get_window_state that follows it.\n")
    lines = []
    for app, framework in apps:
        for op in ["click", "click_back", "type", "key", "key_close", "hotkey", "scroll_down", "menu"]:
            m = [r["ms"] for r in by.get((app, framework, op, "mecum"), []) if r["ok"]]
            cells = [fmt(pct(m, .5))]
            for driver in DRIVERS[1:]:
                a = [r["ms"] for r in by.get((app, framework, op, driver), []) if r["ok"]]
                o = [r["ms"] for r in by.get((app, framework, "observe_after", driver), []) if r["ok"]]
                cells.append(fmt(pct(a, .5) + pct(o, .5)) if a and o else "—")
            if any(c != "—" for c in cells):
                lines.append([f"{app} · {op}"] + cells)
    print(table(["step", "mecum"] + [f"{d} (+observe)" for d in DRIVERS[1:]], lines) + "\n")

    print("## What one observation costs the model\n")
    lines = []
    for app, framework in apps:
        for driver, op in [("mecum", "observe"), ("mecum", "observe_unchanged")] + [(d, "observe") for d in DRIVERS[1:]]:
            rs = by.get((app, framework, op, driver), [])
            if not rs:
                continue
            lines.append([app, f"{driver} {op}", fmt(pct([r["reply_bytes"] for r in rs], .5)),
                          fmt(pct([r.get("text_chars") for r in rs], .5)),
                          fmt(pct([r.get("images") for r in rs], .5)),
                          "×".join(map(str, rs[-1].get("image_px", [[None]])[0])) if rs[-1].get("image_px") else "—",
                          fmt(pct([r.get("structured_bytes") for r in rs], .5)),
                          fmt(pct([tokens(r) for r in rs], .5))])
    print(table(["app", "call", "reply bytes", "text chars", "images", "image px", "structuredContent bytes",
                 "≈ model tokens"], lines) + "\n")

    print("## Resources per call (median): driver CPU, target application CPU, energy\n")
    lines = []
    for app, framework in apps:
        for op in ["observe", "click", "type", "key", "scroll_down", "menu"]:
            for driver in DRIVERS:
                rs = by.get((app, framework, op, driver), [])
                if not rs:
                    continue
                lines.append([f"{app} · {op}", driver, fmt(pct([r.get("driver_cpu_ms") for r in rs], .5), 1),
                              fmt(pct([r.get("driver_instructions") for r in rs], .5) / 1e6 if pct([r.get("driver_instructions") for r in rs], .5) else None, 1),
                              fmt(pct([r.get("driver_energy_mj") for r in rs], .5), 1),
                              fmt(pct([r.get("app_cpu_ms") for r in rs], .5), 1),
                              fmt(pct([r.get("app_energy_mj") for r in rs], .5), 1)])
    print(table(["call", "driver", "driver CPU ms", "driver Minstr", "driver mJ", "app CPU ms", "app mJ"], lines) + "\n")

    print("## Memory and idle cost\n")
    lines = []
    baseline = [r["windowserver_cpu_ms"] for r in data if r.get("op") == "baseline"]
    for driver in DRIVERS:
        rs = [r for r in data if r.get("driver") == driver]
        idle = [r for r in rs if r.get("op") == "idle"]
        startup = [r["ms"] for r in rs if r.get("op") == "startup"]
        if not rs:
            continue
        lines.append([driver, fmt(pct(startup, .5)),
                      fmt(pct([r.get("driver_footprint_mb") for r in rs if r.get("op") != "idle"], .5), 1),
                      fmt(max((r.get("driver_peak_mb") or 0) for r in rs), 1),
                      fmt(pct([r["driver_cpu_ms"] / (r["ms"] / 1000) for r in idle], .5), 2),
                      fmt(pct([r.get("driver_wakeups", 0) / (r["ms"] / 1000) for r in idle], .5), 1),
                      fmt(pct([(r["windowserver_cpu_ms"] - pct(baseline, .5)) / (r["ms"] / 1000) for r in idle], .5) if baseline else None, 0)])
    print(table(["driver", "startup ms", "footprint MB (median)", "peak MB", "idle CPU ms/s",
                 "idle wakeups/s", "WindowServer idle ms/s over baseline"], lines) + "\n")
    if baseline:
        print(f"WindowServer baseline without any driver: {fmt(pct(baseline, .5) / 10, 0)} ms of CPU per second.\n")

    print("## Side effects seen by the independent probe\n")
    lines = []
    for driver in DRIVERS:
        rs = [r for r in data if r.get("driver") == driver and r.get("op") not in ("idle", "baseline", "startup")]
        if not rs:
            continue
        steals = [r for r in rs if r.get("frontmost_after") == r.get("target_pid") and r.get("frontmost_before") != r.get("target_pid")]
        moved = [r for r in rs if r.get("cursor_moved")]
        actions = [r for r in rs if r.get("op") not in ("observe", "observe_after", "observe_unchanged", "list_windows")]
        effects = [r for r in actions if r.get("effect_seen")]
        lines.append([driver, len(rs), len(steals), len(moved), f"{len(effects)}/{len(actions)}",
                      f"{sum(1 for r in rs if r['ok'])}/{len(rs)}"])
    print(table(["driver", "calls", "target became frontmost", "physical cursor moved", "action changed AX values",
                 "calls reported ok"], lines) + "\n")

    print("## Failures\n")
    for r in data:
        if not r.get("ok") and r.get("error"):
            print(f"- {r['driver']} · {r.get('app')} · {r['op']} r{r.get('rep')}: {r['error'][:200]}")


if __name__ == "__main__":
    main(sys.argv[1:])
