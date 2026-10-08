"""One row per framework: success, agent-step latency, observation tokens, driver CPU.

    python3 headline.py results.jsonl [more.jsonl ...]
"""
import json, statistics, sys
from collections import defaultdict
from summarize import rows, pct, tokens

ACTIONS = {"click", "click_back", "type", "key", "key_close", "hotkey", "scroll_down", "scroll_up", "menu", "menu_back"}


def main(paths):
    data = [r for r in rows(paths) if r.get("app") and (r.get("rep", 1) != 0 or r.get("op") == "open_session")]
    by = defaultdict(list)
    for r in data:
        by[(r["app"], r["driver"], r["op"])].append(r)
    apps = sorted({(r["app"], r["framework"]) for r in data}, key=lambda a: a[1])
    print("| framework (app) | Mecum ok | cua ok | step ms Mecum | step ms cua "
          "| tokens/observe Mecum (unchanged) | tokens/observe cua | driver CPU ms/action Mecum | cua |")
    print("|" + "---|" * 9)
    for app, framework in apps:
        cells = [f"{framework} ({app})"]
        for driver in ("mecum", "cua"):
            acts = [r for (a, d, op), rs in by.items() if a == app and d == driver and op in ACTIONS for r in rs]
            opened = [r for r in by.get((app, driver, "open_session"), [])]
            if driver == "mecum" and opened and not any(r["ok"] for r in opened):
                cells.append("session refused")
            else:
                cells.append(f"{sum(r['ok'] for r in acts)}/{len(acts)}" if acts else "—")
        for driver in ("mecum", "cua"):
            per_op = []
            for op in ACTIONS:
                good = [r["ms"] for r in by.get((app, driver, op), []) if r["ok"]]
                if not good:
                    continue
                step = pct(good, .5)
                if driver != "mecum":
                    after = [r["ms"] for r in by.get((app, driver, "observe_after"), []) if r["ok"]]
                    if not after:
                        continue
                    step += pct(after, .5)
                per_op.append(step)
            cells.append(f"{statistics.median(per_op):,.0f}" if per_op else "—")
        full = [tokens(r) for r in by.get((app, "mecum", "observe"), [])]
        same = [tokens(r) for r in by.get((app, "mecum", "observe_unchanged"), [])]
        cua = [tokens(r) for r in by.get((app, "cua", "observe"), [])]
        cells.append(f"{pct(full, .5):,.0f} ({pct(same, .5):,.0f})" if full else "—")
        cells.append(f"{pct(cua, .5):,.0f}" if cua else "—")
        for driver in ("mecum", "cua"):
            cpu = [r["driver_cpu_ms"] for (a, d, op), rs in by.items() if a == app and d == driver and op in ACTIONS
                   for r in rs if r.get("driver_cpu_ms") is not None]
            cells.append(f"{pct(cpu, .5):,.0f}" if cpu else "—")
        print("| " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main(sys.argv[1:])
