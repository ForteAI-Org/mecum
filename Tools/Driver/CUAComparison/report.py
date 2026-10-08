"""Two Markdown reports from the summaries of a benchmark run.

    python3 report.py --summary summary.json [--tasks tasks-summary.json] [--baseline base.json]
                      [--run run.json] [--out-dir ~/Downloads] [--date YYYYMMDD]

Writes MecumVsCua-Team-<date>.md (Italian, short, one conclusion per table) and
MecumVsCua-Report-<date>.md (English, full technical). Inputs: `summarize.py --json` of the run, `tasks.py
--summary`, support.json, the 6 October summary (default: computed from ~/Forte_Projects/_bench/results-20261006/
all.jsonl) and tickets.json. A section with no data says so in one line; every number comes from the inputs.
"""
import argparse, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from summarize import med, order, summarize, wilson  # noqa: E402

DRV = ["mecum", "cua", "cua-overlay"]
LABEL = {"mecum": "Mecum", "cua": "Cua", "cua-overlay": "Cua overlay"}
BASELINE_ROWS = os.path.expanduser("~/Forte_Projects/_bench/results-20261006/all.jsonl")
IDLE_TARGET = 1.5  # ms/s with an open session, from the idle-CPU ticket
CAP_OPS = {"observe": ["observe"], "click": ["click", "click_back"], "type": ["type"], "key": ["key", "key_close"],
           "hotkey": ["hotkey"], "scroll": ["scroll_down", "scroll_up"], "menu": ["menu", "menu_back"]}
CLAIM_CODE = {"supported": "S", "partial": "P", "not supported": "N", "foreground only": "F", "not mentioned": "?"}


# ------------------------------------------------------------------ small helpers

def g(d, *keys, default=None):
    for k in keys:
        if isinstance(d, dict):
            d = d.get(k)
        elif isinstance(d, list) and isinstance(k, int) and -len(d) <= k < len(d):
            d = d[k]
        else:
            return default
        if d is None:
            return default
    return d


def num(v, digits=0):
    return "n/d" if v is None else f"{v:,.{digits}f}"


def pct_text(v):
    return "n/d" if v is None else f"{v * 100:.0f}%"


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    return "\n".join(out + ["| " + " | ".join(str(c) for c in r) + " |" for r in rows])


def wmed(pairs):
    """Weighted (lower) median of (value, weight) pairs; None when empty."""
    pairs = sorted((v, w) for v, w in pairs if v is not None and w and w > 0)
    total, acc = sum(w for _, w in pairs), 0
    for v, w in pairs:
        acc += w
        if acc >= total / 2:
            return v
    return None


def overlap(a, b):
    return bool(a and b and a[0] <= b[1] and b[0] <= a[1])


def verdict(m, o, low=True, ci_m=None, ci_o=None):
    """Mecum value m against another driver's o: 🟢 better, 🔴 worse, ⚪ even (within 10% or intervals overlap)."""
    if m is None or o is None:
        return ""
    if overlap(ci_m, ci_o) or abs(m - o) <= 0.10 * max(abs(m), abs(o)):
        return "⚪"
    return "🟢" if (m < o) == low else "🔴"


def rate_verdict(k1, n1, k2, n2, low=False):
    if not n1 or not n2:
        return ""
    return verdict(k1 / n1, k2 / n2, low, wilson(k1, n1), wilson(k2, n2))


def change(cur, base):
    return None if cur is None or base in (None, 0) else (cur - base) / abs(base)


def arrow(cur, base, low=True):
    """Mecum against its own 6 October value: ▲ better, ▼ worse, = within 5%."""
    ch = change(cur, base)
    if ch is None:
        return "n/d"
    if abs(ch) <= 0.05:
        return f"= {ch * 100:+.0f}%"
    return f"{'▲' if (ch < 0) == low else '▼'} {ch * 100:+.0f}%"


def tally(marks):
    return f"🟢 {marks.count('🟢')}, 🔴 {marks.count('🔴')}, ⚪ {marks.count('⚪')}"


def last_window(idle):
    keys = sorted(idle or {}, key=lambda k: int(k.split("_")[1]))
    return idle[keys[-1]] if keys else None


# ------------------------------------------------------------------ the inputs, with the accessors every table uses

class Ctx:
    def __init__(self, S, B, T, SUP, TICKETS, RUN):
        self.S, self.B, self.T, self.SUP, self.TICKETS, self.RUN = S, B, T, SUP, TICKETS, RUN
        self.drivers = [d for d in DRV if d in S.get("drivers", {})]
        self.marks, self.losses = [], []
        meta = (S.get("meta") or [{}])[0]
        self.meta = meta
        cur = g(meta, "drivers", "cua", "commit") or g(SUP, "cua", "short") or ""
        base = g(SUP, "cua", "compared_against_short") or ""
        self.cua_changed = bool(cur and base and not (cur.startswith(base) or base.startswith(cur)))
        self.frameworks = {f["app"]: f["framework"] for f in SUP.get("frameworks", [])}
        self.when = (RUN.get("started") or meta.get("run") or time.strftime("%Y-%m-%d"))[:10]

    def app(self, S, d, a):
        return g(S, "drivers", d, "apps", a, default={})

    def apps(self):
        return sorted({a for d in self.S["drivers"].values() for a in d["apps"]})

    def fw(self, a):
        return self.frameworks.get(a) or next((g(d, "apps", a, "framework") for d in self.S["drivers"].values()
                                               if g(d, "apps", a, "framework")), "")

    def across(self, S, getter, drivers=None):
        """({driver: median over the apps every driver with data has}, apps used)."""
        drivers = drivers or self.drivers
        per = {d: {a: getter(app) for a, app in g(S, "drivers", d, "apps", default={}).items()} for d in drivers}
        per = {d: {a: v for a, v in vs.items() if v is not None} for d, vs in per.items()}
        live = [d for d in drivers if per[d]]
        used = sorted(set.intersection(*(set(per[d]) for d in live))) if live else []
        return {d: (med([per[d][a] for a in used]) if d in live and used else None) for d in drivers}, used

    def own(self, getter, driver="mecum"):
        """(current, baseline) medians of the apps both runs have for one driver."""
        cur = {a: getter(x) for a, x in g(self.S, "drivers", driver, "apps", default={}).items()}
        base = {a: getter(x) for a, x in g(self.B, "drivers", driver, "apps", default={}).items()}
        used = [a for a in cur if cur[a] is not None and base.get(a) is not None]
        return (med([cur[a] for a in used]), med([base[a] for a in used])) if used else (None, None)

    # steps pooled over a set of matched operations
    def matched_ops(self, S, app, drivers):
        sets = []
        for d in drivers:
            steps = g(S, "drivers", d, "apps", app, "steps", default={})
            ops = {o for o, s in steps.items() if g(s, "n_ok", default=0) and g(s, "latency_ms", "p50") is not None}
            if ops:
                sets.append(ops)
        return set.intersection(*sets) if sets else set()

    def pooled_step(self, S, d, ops_by_app):
        pairs, calls = [], 0
        for a, ops in ops_by_app.items():
            for o in ops:
                s = g(S, "drivers", d, "apps", a, "steps", o)
                if s and s.get("n_ok") and g(s, "latency_ms", "p50") is not None:
                    pairs.append((s["latency_ms"]["p50"], s["n_ok"]))
                    calls += s["n_ok"]
        return wmed(pairs), calls

    def step_sets(self):
        """{app: ops present for every driver that has step data in this run}."""
        return {a: self.matched_ops(self.S, a, self.drivers) for a in self.apps()}

    def own_ops(self, app, driver="mecum"):
        a = self.matched_ops(self.S, app, [driver])
        b = self.matched_ops(self.B, app, [driver])
        return a & b

    # measured values of a capability for support rows
    def measured(self, d, app, cap):
        a = self.app(self.S, d, app)
        if cap in CAP_OPS:
            ops = [a["ops"][o] for o in CAP_OPS[cap] if o in g(a, "ops", default={})]
            return dict(n=sum(o["n"] for o in ops), ok=sum(o["n_ok"] for o in ops),
                        conf=sum(o["n_confirmed"] for o in ops), chk=sum(o["n_checkable"] for o in ops))
        i = a.get("intrusion") or {}
        bad = i.get("frontmost_changed") if cap == "background_no_activation" else i.get("cursor_moved_during_call")
        n = i.get("calls", 0)
        return dict(n=n, ok=n - (bad or 0), conf=0, chk=0)

    def session_refused(self, d, app):
        o = g(self.app(self.S, d, app), "ops", "open_session")
        return bool(o and o["n"] and not o["n_ok"])


def works(m):
    if not m or not m["n"]:
        return None
    return (m["conf"] / m["chk"] if m["chk"] else m["ok"] / m["n"]) >= 0.5


# ------------------------------------------------------------------ one table in the Team format

class Team:
    def __init__(self, c):
        self.c, self.out = c, []

    def section(self, title, intro, header, rows, conclusion, empty="nessun dato in questa corsa"):
        text = f"### {title}\n\n"
        if not rows:
            self.out.append(text + f"Nessun dato: {empty}.\n")
            return
        self.out.append(text + "\n".join(intro) + "\n\n" + table(header, rows) + f"\n\n**Conclusione:** {conclusion}\n")

    def metric(self, rows, area, label, vals, fmt, low=True, own=None, cua_base=None, with_cua=False, ci=None, loss=True):
        """One row: Mecum, Cua, Cua overlay (marker = Mecum against that variant), own change, optional Cua note."""
        c, ci = self.c, ci or {}
        m = vals.get("mecum")
        cells = [fmt(m) if m is not None else "n/d"]
        for d in ("cua", "cua-overlay"):
            v = vals.get(d)
            if d not in c.drivers or v is None:
                cells.append("n/d")
                continue
            mark = verdict(m, v, low, ci.get("mecum"), ci.get(d))
            c.marks.append(mark)
            if mark == "🔴" and loss:
                c.losses.append(dict(area=area, metric=label, mecum=fmt(m), other=fmt(v), against=LABEL[d],
                                     delta=change(m, v) if m > 0 and v > 0 else None))
            cells.append(f"{fmt(v)} {mark}")
        row = [label] + cells + [arrow(*own, low) if own else "n/d"]
        if with_cua:
            ch = change(*cua_base) if cua_base else None
            if ch is None:
                row.append("n/d")
            elif c.cua_changed:
                row.append(f"Cua cambiato versione ({ch * 100:+.0f}%)")
            else:
                row.append(arrow(*cua_base, low))
        rows.append(row)


HEAD = ["Metrica", "Mecum", "Cua", "Cua overlay", "Mecum vs 6/10"]
HEAD_CUA = HEAD + ["Cua vs 6/10"]
ms = lambda v: f"{v:,.0f} ms"  # noqa: E731
rate = lambda v: f"{v:.2f} ms/s" if abs(v) < 10 else f"{v:.1f} ms/s"  # noqa: E731
tok = lambda v: f"{v:,.0f}"  # noqa: E731
mb = lambda v: f"{v:,.1f} MB"  # noqa: E731


def idle_total(a, first=False):
    keys = sorted(a.get("idle") or {}, key=lambda k: int(k.split("_")[1]))
    w = (a["idle"][keys[0]] if first else a["idle"][keys[-1]]) if keys else None
    if not w or w.get("driver_ms_per_s") is None:
        return None
    return w["driver_ms_per_s"] + (w.get("proxy_ms_per_s") or 0)


def action_cpu(a, key="driver_ms"):
    v = g(a, "actions", "cpu", key)
    if key == "driver_ms" and v is not None:
        v += g(a, "actions", "cpu", "proxy_ms") or 0
    return v


# ------------------------------------------------------------------ Team tables

def t_headline(t):
    c, rows = t.c, []
    sets = {a: o for a, o in c.step_sets().items() if o}
    vals = {}
    for d in c.drivers:
        vals[d], _ = c.pooled_step(c.S, d, sets)
    own_sets = {a: c.own_ops(a) for a in c.apps()}
    cur_own, _ = c.pooled_step(c.S, "mecum", own_sets)
    base_own, _ = c.pooled_step(c.B, "mecum", own_sets)
    cur_cua, _ = c.pooled_step(c.S, "cua", {a: c.own_ops(a, "cua") for a in c.apps()})
    base_cua, _ = c.pooled_step(c.B, "cua", {a: c.own_ops(a, "cua") for a in c.apps()})
    t.metric(rows, "Passo", "Passo equivalente, mediana su operazioni appaiate", vals, ms, True,
             (cur_own, base_own) if own_sets else None, (cur_cua, base_cua), True, loss=False)
    for label, getter, fmt, low, area in [
            ("Token per lettura piena (mediana tra app)", lambda a: g(a, "reads", "full", "tokens", "total"), tok, True, "Token"),
            ("Token per lettura invariata o diff (mediana tra app)", lambda a: g(a, "reads", "unchanged", "tokens", "total"), tok, True, "Token"),
            ("CPU del driver a riposo, ultima finestra", idle_total, rate, True, "CPU"),
            ("CPU del driver durante le azioni", lambda a: g(a, "actions", "cpu", "driver_ms_per_s"), rate, True, "CPU")]:
        v, _ = c.across(c.S, getter)
        base_cua = c.own(getter, "cua")
        t.metric(rows, area, label, v, fmt, low, c.own(getter), base_cua, True, loss=False)
    for key, label in (("median", "RAM del driver, mediana"), ("peak", "RAM del driver, picco")):
        v = {d: g(c.S, "drivers", d, "footprint_mb", key) for d in c.drivers}
        own = (v.get("mecum"), g(c.B, "drivers", "mecum", "footprint_mb", key))
        t.metric(rows, "RAM", label, v, mb, True, own, (v.get("cua"), g(c.B, "drivers", "cua", "footprint_mb", key)), True, loss=False)
    # success and intrusions pooled over the apps every driver has actions for
    used = [a for a in c.apps() if all(g(c.app(c.S, d, a), "actions", "n", default=0) for d in c.drivers)]
    for label, num_key, den_key, low, area in [("Successo dichiarato (ok / chiamate)", "n_ok", "n", False, "Robustezza"),
                                              ("Successo confermato dalla sonda", "n_confirmed", "n_checkable", False, "Robustezza")]:
        cnt = {d: (sum(g(c.app(c.S, d, a), "actions", num_key, default=0) for a in used),
                   sum(g(c.app(c.S, d, a), "actions", den_key, default=0) for a in used)) for d in c.drivers}
        if not used or not all(n for _, n in cnt.values()):
            continue
        row = [label]
        for d in c.drivers:
            k, n = cnt[d]
            mark = "" if d == "mecum" else rate_verdict(*cnt["mecum"], k, n, low)
            if d != "mecum":
                c.marks.append(mark)
            row.append(f"{k}/{n} ({pct_text(k / n)}) {mark}".strip())
        row += ["n/d"] * (4 - len(row)) + [arrow(*c.own(lambda a, k=num_key, n=den_key: (g(a, "actions", k) / g(a, "actions", n)) if g(a, "actions", n) else None), False), "n/d"]
        rows.append(row)
    for label, key in (("Primo piano cambiato (azioni)", "frontmost_changed"), ("Cursore spostato durante la chiamata", "cursor_moved_during_call"),
                       ("Finestra sul display della persona", "window_on_user_display")):
        cnt = {d: (sum(g(c.app(c.S, d, a), "intrusion", key, default=0) for a in c.apps()),
                   sum(g(c.app(c.S, d, a), "intrusion", "calls", default=0) for a in c.apps())) for d in c.drivers}
        if not all(n for _, n in cnt.values()):
            continue
        row = [label]
        for d in c.drivers:
            k, n = cnt[d]
            mark = "" if d == "mecum" else rate_verdict(*cnt["mecum"], k, n, True)
            if d != "mecum":
                c.marks.append(mark)
                if mark == "🔴":
                    c.losses.append(dict(area="Intrusione", metric=label, mecum=f"{cnt['mecum'][0]}/{cnt['mecum'][1]}",
                                         other=f"{k}/{n}", against=LABEL[d], delta=None))
            row.append(f"{k}/{n} {mark}".strip())
        rows.append(row + ["n/d", "n/d"])
    marks = [m for m in c.marks if m]
    t.section("Sintesi", ["Le metriche principali, ognuna sulle app dove tutti i driver hanno dati.",
                          "Il marcatore accanto al valore di Cua dice come sta Mecum rispetto a quella variante.",
                          "Passo equivalente: l'azione con la scena che la segue (Mecum una chiamata, Cua `run_actions` con `observe`)."],
              HEAD_CUA, rows, f"sul totale dei confronti {tally(marks)}; i dettagli sono nelle tabelle sotto.")


def t_steps(t):
    c, rows, marks, reds = t.c, [], [], {}
    for a in c.apps():
        ops = c.matched_ops(c.S, a, c.drivers)
        if not ops:
            continue
        vals = {d: c.pooled_step(c.S, d, {a: ops})[0] for d in c.drivers}
        n_ops = len(ops)
        own_ops = c.own_ops(a)
        own = (c.pooled_step(c.S, "mecum", {a: own_ops})[0], c.pooled_step(c.B, "mecum", {a: own_ops})[0]) if own_ops else None
        before = len(t.c.marks)
        t.metric(rows, "Passo", f"{a} ({c.fw(a)}), {n_ops} op.", vals, ms, True, own, loss=False)
        marks += t.c.marks[before:]
        for d in ("cua", "cua-overlay"):
            if d in c.drivers and verdict(vals.get("mecum"), vals.get(d)) == "🔴":
                reds.setdefault(d, {})[a] = ops
    for d, apps in reds.items():
        m, k = c.pooled_step(c.S, "mecum", apps)[0], c.pooled_step(c.S, d, apps)[0]
        c.losses.append(dict(area="Passo", metric=f"Passo equivalente, app più lente ({', '.join(apps)})", mecum=ms(m), other=ms(k),
                             against=LABEL[d], delta=change(m, k)))
    wins = sum(1 for r in rows if r[2].endswith("🟢"))
    both = sum(1 for r in rows if r[1] != "n/d")
    t.section("Tempo del passo per app", [
        "Mediana del passo equivalente su operazioni che tutti i driver hanno completato (stesso mix di operazioni).",
        "Così un'operazione rifiutata da un solo driver non sposta la media. Il numero di operazioni appaiate è nella prima colonna."],
              HEAD, rows, f"su {both} app con dati di Mecum e di Cua, Mecum è più veloce di Cua in {wins}; sui confronti con le due varianti {tally(marks)}.",
              "nessuna operazione completata da tutti i driver")


def t_chain(t):
    c, rows, marks = t.c, [], []
    pauses = sorted({p for d in c.drivers for a in c.apps() for p in g(c.app(c.S, d, a), "chain", default={}) if p != "wake"}, key=float)
    for p in pauses:
        for label, key in (("passo", "step_ms"), ("primo passo dopo il riposo", "first_step_ms")):
            vals = {}
            for d in c.drivers:
                pairs = []
                for a in c.apps():
                    x = g(c.app(c.S, d, a), "chain", p)
                    v = g(x, "step_ms", "p50") if key == "step_ms" else g(x, key)
                    pairs.append((v, g(x, "n", default=0)))
                vals[d] = wmed(pairs)
            before = len(c.marks)
            t.metric(rows, "Pausa", f"pausa {float(p):g} s, {label}", vals, ms, True)
            marks += c.marks[before:]
    wake = wmed([(g(c.app(c.S, "mecum", a), "chain", "wake", "wake_cost_ms"), g(c.app(c.S, "mecum", a), "chain", "wake", "resting_steps", default=0))
                 for a in c.apps()])
    if rows and wake is not None:
        rows.append(["Costo del risveglio dello stream (Mecum, dedotto dal gap)", ms(wake), "-", "-", "n/d"])
    t.section("Ritardo tra i passi", [
        "Mediana del tempo di un passo in una catena di 10 passi, con una pausa fissa tra l'uno e l'altro (0, 1, 3, 5 s).",
        "Dopo 2,5 s di quiete lo stream di Mecum scende a riposo (ADR 0036): il primo passo dopo una pausa lunga ne paga il risveglio.",
        "Il 6/10 la catena non fu misurata: la colonna con il confronto è n/d."],
              HEAD, rows, f"nessun valore del 6/10 per confrontare; sui confronti con Cua {tally(marks)}.", "nessuna catena misurata (modalità chain non eseguita)")


def t_cpu(t):
    c, rows, marks = t.c, [], []
    spec = [("Driver per azione (ms di CPU)", lambda a: action_cpu(a), ms, "CPU azione"),
            ("Driver durante l'azione (ms/s)", lambda a: g(a, "actions", "cpu", "driver_ms_per_s"), rate, "CPU azione"),
            ("App bersaglio per azione (ms di CPU)", lambda a: g(a, "actions", "cpu", "app_ms"), ms, "CPU app"),
            ("WindowServer per azione (ms, ticks da 10 ms)", lambda a: g(a, "actions", "cpu", "windowserver_ms"), ms, "WindowServer"),
            ("Driver per lettura piena (ms di CPU)", lambda a: g(a, "reads", "full", "cpu", "driver_ms"), ms, "CPU lettura"),
            ("Driver a riposo, prima finestra (ms/s)", lambda a: idle_total(a, True), rate, "CPU riposo"),
            ("Driver a riposo, ultima finestra (ms/s)", idle_total, rate, "CPU riposo"),
            ("App bersaglio a riposo (ms/s)", lambda a: g(last_window(a.get("idle")), "app_ms_per_s"), rate, "CPU app a riposo"),
            ("WindowServer sopra la baseline, a riposo (ms/s)", lambda a: g(last_window(a.get("idle")), "windowserver_over_baseline_ms_per_s"), rate, "WindowServer")]
    for label, getter, fmt, area in spec:
        v, _ = c.across(c.S, getter)
        before = len(c.marks)
        t.metric(rows, area, label, v, fmt, True, c.own(getter), loss=not (label.startswith("Driver a riposo, prima") or label.startswith("WindowServer sopra")))
        marks += c.marks[before:]
    base = g(c.S, "baseline", "windowserver_ms_per_s")
    t.section("CPU", [
        "Costo in CPU del driver e del bersaglio, per azione e a riposo (mediana tra le app con dati per tutti).",
        "A riposo: finestre consecutive dopo l'ultima chiamata con una sessione aperta. Per `cua-overlay` il driver è il daemon più il proxy.",
        f"WindowServer senza driver: {num(base)} ms/s; sopra la baseline si legge solo uno scarto, non un costo isolato."],
              HEAD, rows, f"su {len(marks)} confronti {tally(marks)}; dove Mecum è sopra Cua pesano le percezioni attorno all'azione e lo stream.",
              "nessuna chiamata con CPU registrata")


def t_ram(t):
    c, rows, marks = t.c, [], []
    for key, label in (("median", "Footprint mediano"), ("peak", "Picco")):
        v = {d: g(c.S, "drivers", d, "footprint_mb", key) for d in c.drivers}
        before = len(c.marks)
        t.metric(rows, "RAM", label, v, mb, True, (v.get("mecum"), g(c.B, "drivers", "mecum", "footprint_mb", key)))
        marks += c.marks[before:]
    v = {d: g(c.S, "drivers", d, "startup_ms") for d in c.drivers}
    t.metric(rows, "Avvio", "Avvio del server MCP", v, ms, True, (v.get("mecum"), g(c.B, "drivers", "mecum", "startup_ms")))
    soak = lambda a: g(a, "soak", "driver_footprint_mb", "slope_mb_per_100_steps")  # noqa: E731
    sv, used = c.across(c.S, soak)
    if used:
        t.metric(rows, "RAM", f"Pendenza del driver nel soak (MB per 100 passi, {', '.join(used)})", sv, lambda x: f"{x:+.2f}", True)
        for label, getter, fmt in [("Errori nel soak", lambda a: g(a, "soak", "errors"), lambda x: f"{x:.0f}"),
                                   ("Stalli nel soak", lambda a: g(a, "soak", "stalls"), lambda x: f"{x:.0f}"),
                                   ("Deriva di latenza nel soak (ms, ultimi 50 contro primi 50)", lambda a: g(a, "soak", "latency_drift_ms"), ms)]:
            t.metric(rows, "Soak", label, c.across(c.S, getter)[0], fmt, True)
    t.section("RAM e soak", [
        "Memoria fisica del processo del driver durante la corsa (footprint) e andamento su una sequenza lunga di passi neutri.",
        "La pendenza è la regressione lineare del footprint sui passi: un valore vicino a 0 non mostra perdite nell'orizzonte misurato."],
              HEAD, rows, f"footprint Mecum {num(g(c.S, 'drivers', 'mecum', 'footprint_mb', 'median'), 0)} MB contro Cua {num(g(c.S, 'drivers', 'cua', 'footprint_mb', 'median'), 0)} MB; "
              f"{'soak misurato' if used else 'soak non eseguito'}; {tally(marks)}.", "nessun dato di memoria")


def t_tokens(t):
    c, rows, marks = t.c, [], []

    def split(a, kind):
        x = g(a, "reads", kind, "tokens")
        return None if not x or x.get("total") is None else x["total"]

    for a in c.apps():
        for kind, label in (("full", "lettura piena"), ("unchanged", "lettura invariata/diff")):
            vals = {d: split(c.app(c.S, d, a), kind) for d in c.drivers}
            if not any(v is not None for v in vals.values()):
                continue
            own = (vals.get("mecum"), split(c.app(c.B, "mecum", a), kind))
            base_cua = (vals.get("cua"), split(c.app(c.B, "cua", a), kind))
            before = len(c.marks)
            t.metric(rows, "Token", f"{a}, {label}", vals, tok, True, own, base_cua, True)
            marks += c.marks[before:]
    rows_split = []
    for d in c.drivers:
        tx, im = c.across(c.S, lambda a, d=d: g(a, "reads", "full", "tokens", "text"), [d])[0][d], c.across(c.S, lambda a, d=d: g(a, "reads", "full", "tokens", "image"), [d])[0][d]
        rows_split.append(f"{LABEL[d]} {num(tx)} testo + {num(im)} immagine")
    t.section("Token", [
        "Token stimati di una lettura della finestra: testo a 4 caratteri per token, immagini come larghezza per altezza diviso 750.",
        "Mecum risponde con la scena in testo; Cua con l'albero in Markdown e uno screenshot (dal c1c2b5f albero ridotto a 250 nodi).",
        "Mediana tra le app, lettura piena: " + "; ".join(rows_split) + "."],
              HEAD_CUA, rows, f"su {len(marks)} confronti {tally(marks)}; i valori di Cua non sono confrontabili con il 6/10 perché ha cambiato versione.",
              "nessuna lettura registrata")


def t_robust(t):
    c, rows, marks = t.c, [], []
    for a in c.apps():
        acts = {d: g(c.app(c.S, d, a), "actions", default={}) for d in c.drivers}
        refused = {d: c.session_refused(d, a) for d in c.drivers}
        if not any(x.get("n") for x in acts.values()) and not any(refused.values()):
            continue
        row, m = [f"{a} ({c.fw(a)})"], acts.get("mecum", {})
        for d in DRV:
            x = acts.get(d)
            if x is None:
                row.append("n/d")
            elif not x.get("n"):
                row.append("sessione rifiutata" if refused[d] else "n/d")
                if d == "mecum" and refused[d]:
                    c.losses.append(dict(area="Robustezza", metric=f"{a}: apertura della sessione", mecum="rifiutata", other="ok", against="Cua", delta=None))
            else:
                w = x["ok_wilson95"]
                s = f"{x['n_ok']}/{x['n']} [{w[0]:.2f}-{w[1]:.2f}]" + (f"; conf. {x['n_confirmed']}/{x['n_checkable']}" if x.get("n_checkable") else "")
                mark = ""
                if d != "mecum" and m.get("n"):
                    mark = verdict(m["ok_rate"], x["ok_rate"], False, m["ok_wilson95"], w)
                    marks.append(mark)
                    c.marks.append(mark)
                    if mark == "🔴":
                        c.losses.append(dict(area="Robustezza", metric=f"{a}: azioni riuscite", mecum=f"{m['n_ok']}/{m['n']}", other=f"{x['n_ok']}/{x['n']}",
                                             against=LABEL[d], delta=None))
                row.append(f"{s} {mark}".strip())
        row.append(arrow(m.get("ok_rate"), (c.app(c.B, "mecum", a).get("actions") or {}).get("ok_rate"), False))
        rows.append(row)
    t.section("Robustezza", [
        "Azioni riuscite su azioni tentate, con l'intervallo di Wilson al 95%; \"conf.\" sono quelle verificate dalla sonda indipendente.",
        "Un'azione conta come riuscita se il driver non dichiara errore, rifiuto o miss; la conferma c'è solo dove la sonda legge un effetto.",
        "Le operazioni senza oracolo (scroll, menu, pixel di kitty o Obsidian) restano non confermate."],
              ["App", "Mecum", "Cua", "Cua overlay", "Mecum vs 6/10"], rows,
              f"{tally(marks)}; dove Mecum rifiuta (menu in background, sessione su Stocks) il marcatore è rosso.", "nessuna azione registrata")


def support_rows(c):
    """Per framework: claims and measurement of both drivers, with the contradictions."""
    cells = {}
    for x in c.SUP.get("cells", []):
        cells.setdefault((x["framework"], x["driver"]), {})[x["capability"]] = x
    out = []
    for f in c.SUP.get("frameworks", []):
        a = f["app"]
        info = {}
        for d in ("mecum", "cua"):
            claims, flags, ok, n, conf, chk = {}, [], 0, 0, 0, 0
            for cap, cell in cells.get((f["id"], d), {}).items():
                claims[cap] = cell["claim"]
                m = c.measured(d, a, cap)
                w = works(m)
                if cap in CAP_OPS and m["n"]:
                    ok, n, conf, chk = ok + m["ok"], n + m["n"], conf + m["conf"], chk + m["chk"]
                if c.session_refused(d, a) and cell["claim"] == "supported":
                    flags.append(f"{cap}: dichiarato supportato ma fallisce (sessione rifiutata)")
                elif cell["claim"] in ("not supported", "foreground only") and w:
                    flags.append(f"{cap}: dichiarato non supportato ma funziona" + ("" if m["chk"] else " (verdetto del driver)"))
                elif cell["claim"] == "supported" and w is False:
                    flags.append(f"{cap}: dichiarato supportato ma fallisce")
            info[d] = dict(claims=claims, flags=flags, ok=ok, n=n, conf=conf, chk=chk, app=c.app(c.S, d, a))
        out.append((f, info))
    return out


def t_support(t):
    c, rows, marks = t.c, [], []
    for f, info in support_rows(c):
        if not any(i["app"] for i in info.values()):
            continue
        cells = [f"{f['framework']} ({f['app']})"]
        for d in ("mecum", "cua"):
            i = info[d]
            counts = {}
            for cl in i["claims"].values():
                counts[cl] = counts.get(cl, 0) + 1
            declared = ", ".join(f"{k} {v}" for k, v in sorted(counts.items(), key=lambda x: -x[1])) or "n/d"
            measured = f"{i['ok']}/{i['n']}" + (f", conf. {i['conf']}/{i['chk']}" if i["chk"] else "") if i["n"] else "n/d"
            cells += [declared, measured]
        flags = [f"{LABEL[d]} {x}" for d in ("mecum", "cua") for x in info[d]["flags"]]
        mi, ci_ = info["mecum"], info["cua"]
        mark = rate_verdict(mi["ok"], mi["n"], ci_["ok"], ci_["n"]) if mi["n"] and ci_["n"] else ""
        marks.append(mark)
        cells.append(mark)
        cells.append("; ".join(flags) or "-")
        rows.append(cells)
    flagged = sum(1 for r in rows if r[-1] != "-")
    t.section("Supporto per framework", [
        "Cosa dichiara ciascun driver nella propria documentazione (a c1c2b5f per Cua) e cosa si è misurato in questa corsa, sulle capacità misurate.",
        "Dichiarato: conteggio delle capacità per tipo; misurato: azioni ok su tentate (e confermate dalla sonda). Il marcatore confronta Mecum con Cua.",
        "Segnalazioni: dichiarato non supportato ma funziona, dichiarato supportato ma fallisce (per Cua la variante senza overlay)."],
              ["Framework (app)", "Mecum dichiarato", "Mecum misurato", "Cua dichiarato", "Cua misurato", "Mecum vs Cua", "Segnalazioni"],
              rows, f"{flagged} framework su {len(rows)} con almeno una incoerenza tra dichiarato e misurato; {tally(marks)}.",
              "support.json assente o nessuna app misurata")


def task_cells(cell):
    s = cell["success"]
    return (f"{s['count']}/{s['of']} · {num(g(cell, 'wall_s', 'median'))} s · {num(g(cell, 'billed_tokens', 'median'))} tok · "
            f"${num(g(cell, 'cost_usd', 'median'), 2)} · {num(g(cell, 'tool_calls', 'median'))} chiam. · "
            f"pensiero {num((g(cell, 'think_ms', 'median') or 0) / 1000 if g(cell, 'think_ms', 'median') is not None else None, 1)} s")


def t_tasks(t):
    c, rows, marks = t.c, [], []
    T = c.T or {}
    if not T:
        return t.section("Compiti con un modello reale", [], [], [], "", "fase compiti non eseguita")
    drivers = [d for d in DRV if d in T]
    tasks = sorted({k for d in drivers for k in T[d]["tasks"]})
    for k in tasks + ["ALL(supported)"]:
        row = [k]
        cm = g(T, "mecum", "tasks", k) if k != "ALL(supported)" else g(T, "mecum", "within_declared_support")
        for d in DRV:
            cell = (T.get(d) or {}).get("tasks", {}).get(k) if k != "ALL(supported)" else (T.get(d) or {}).get("within_declared_support")
            if not cell or not cell["runs"]:
                row.append("n/d")
                continue
            s = task_cells(cell) + (" (fuori dal supporto dichiarato)" if cell.get("outside_declared_support") and k != "ALL(supported)" else "")
            mark = ""
            if d != "mecum" and cm and cm["runs"]:
                a, b = cm["success"], cell["success"]
                mark = rate_verdict(a["count"], a["of"], b["count"], b["of"]) if a["of"] and b["of"] else ""
                if mark == "⚪":
                    mark = verdict(g(cm, "wall_s", "median"), g(cell, "wall_s", "median"))
                marks.append(mark)
                if mark == "🔴" and k != "ALL(supported)":
                    c.losses.append(dict(area="Compiti", metric=f"compito {k}", mecum=task_cells(cm), other=task_cells(cell), against=LABEL[d], delta=None))
            row.append(f"{s} {mark}".strip())
        rows.append(row)
    model = ""
    if T:
        cfg = load(os.path.join(HERE, "tasks.json"), {})
        model = f" Modello {cfg.get('model', 'n/d')}, sforzo {cfg.get('effort', 'n/d')}."
    t.section("Compiti con un modello reale", [
        "Lo stesso compito, lo stesso prompt e lo stesso modello, guidati da Claude Code attraverso il server MCP di ciascun driver.",
        "Cella: riuscite/decise · tempo · token fatturati · costo · chiamate · tempo di pensiero medio per chiamata; successo deciso da un controllo indipendente."
        + model,
        "Il marcatore confronta il successo e, a parità, il tempo. `ALL(supported)` esclude i compiti fuori dal supporto dichiarato di Cua."],
              ["Compito"] + [LABEL[d] for d in DRV], rows,
              f"{tally([m for m in marks if m])} sui confronti; poche ripetizioni per compito: gli intervalli sono larghi.", "fase compiti non eseguita")


# ------------------------------------------------------------------ tickets

def fail_hits(c, driver, app, ops, pattern):
    import re
    hits = []
    for op, o in g(c.app(c.S, driver, app), "ops", default={}).items():
        if ops and op not in ops:
            continue
        for err, n in (o.get("failures") or {}).items():
            if re.search(pattern, err, re.I):
                hits.append(f"{op} x{n}")
    return hits


def detect(c, name):
    S = c.S
    if name == "catalyst_session_refused":
        if c.session_refused("mecum", "Stocks") or g(c.app(S, "mecum", "Stocks"), "aborted"):
            return "Stocks: open_session rifiutata" + (f" ({'; '.join(fail_hits(c, 'mecum', 'Stocks', ['open_session'], '.'))})" if fail_hits(c, 'mecum', 'Stocks', ['open_session'], '.') else "")
    elif name == "terminal_ctrl_keys":
        o = g(c.app(S, "mecum", "kitty"), "ops", "hotkey")
        if o and o["n"] and (o["n_checkable"] == 0 or o["n_confirmed"] < o["n_ok"] / 2):
            return f"kitty hotkey: {o['n_ok']}/{o['n']} ok, confermate {o['n_confirmed']}/{o['n_checkable']} (effetto non provato)"
    elif name == "safari_keys":
        hits = fail_hits(c, "mecum", "Safari", ["type", "key", "hotkey"], "subtreeUnreadable|delivery failed")
        bad = [f"{op} {o['n_ok']}/{o['n']}" for op, o in g(c.app(S, "mecum", "Safari"), "ops", default={}).items()
               if op in ("type", "key", "hotkey") and o["n"] and o["n_ok"] < o["n"]]
        if hits or bad:
            return "Safari: " + "; ".join(hits or bad)
    elif name == "scene_labels":
        hits = [f"{a} {h}" for a in c.apps() for h in fail_hits(c, "mecum", a, ["click", "click_back", "type", "menu"], "honest_miss|ambiguous|no element|not found")]
        if hits:
            return "bersaglio non risolto: " + "; ".join(hits[:6])
    elif name == "photoshop_start_bar":
        hits = fail_hits(c, "mecum", "Photoshop", None, "moveRefused|placementNotConfirmed")
        if hits or g(c.app(S, "mecum", "Photoshop"), "aborted"):
            return "Photoshop: " + "; ".join(hits or ["blocco interrotto"])
    elif name == "file_panel":
        hits = fail_hits(c, "mecum", "Photoshop", None, "surfaceOutsideSeat|seatNotReady|targetActivated")
        if hits:
            return "Photoshop: " + "; ".join(hits)
    elif name == "resolve_escape":
        hits = fail_hits(c, "mecum", "DaVinci Resolve", None, "ambiguousEffect|quit|exited")
        if hits or g(c.app(S, "mecum", "DaVinci Resolve"), "aborted"):
            return "Resolve: " + "; ".join(hits or ["blocco interrotto"])
    elif name == "idle_cpu":
        v, used = c.across(S, idle_total, ["mecum"])
        if v["mecum"] is not None and v["mecum"] > IDLE_TARGET:
            return f"CPU a riposo {v['mecum']:.1f} ms/s con sessione aperta (mediana su {len(used)} app), obiettivo {IDLE_TARGET} ms/s"
    elif name == "background_menus":
        hits = [f"{a} {h}" for a in c.apps() for h in fail_hits(c, "mecum", a, ["menu", "menu_back"], "disabled right now")]
        if hits:
            return "menu rifiutati come disabilitati: " + "; ".join(hits)
    elif name == "step_time":
        slow = []
        for a, ops in c.step_sets().items():
            if ops and "cua" in c.drivers:
                m, k = c.pooled_step(S, "mecum", {a: ops})[0], c.pooled_step(S, "cua", {a: ops})[0]
                if verdict(m, k) == "🔴":
                    slow.append(f"{a} {m:,.0f} contro {k:,.0f} ms")
        if slow:
            return "passo più lento di Cua: " + "; ".join(slow)
    elif name == "footprint":
        m, k = g(S, "drivers", "mecum", "footprint_mb", "median"), g(S, "drivers", "cua", "footprint_mb", "median")
        if verdict(m, k) == "🔴":
            return f"RAM mediana {m:.0f} MB contro {k:.0f} MB di Cua"
    elif name == "action_cpu":
        v, used = c.across(S, action_cpu, ["mecum", "cua"])
        if verdict(v["mecum"], v["cua"]) == "🔴":
            return f"CPU del driver per azione {v['mecum']:.0f} ms contro {v['cua']:.0f} ms di Cua"
    return None


def ticket_rows(c):
    rows = []
    for tk in c.TICKETS.get("tickets", []):
        ev = detect(c, tk["detect"])
        if ev:
            rows.append([tk["weakness"], ev, tk["ticket"] + ("" if tk["status"] == "-" else f" ({tk['status']})"), tk["expected"]])
    return rows


def t_tickets(t):
    rows = ticket_rows(t.c)
    t.section("Prossimi ticket", [
        "Ogni debolezza che questa corsa mostra, con il ticket che la riguarda secondo l'elenco del 7/10 e l'effetto atteso dal suo criterio di accettazione.",
        "Le debolezze senza dati in questa corsa non sono elencate; \"nessun ticket\" significa che l'elenco non ne nomina uno."],
              ["Debolezza", "Evidenza in questa corsa", "Ticket (stato)", "Effetto atteso"], rows,
              f"{len(rows)} debolezze misurate; {sum(1 for r in rows if r[2].startswith('nessun ticket'))} senza ticket.", "nessuna debolezza nota riscontrata")


def t_losses(t):
    merged = {}
    for x in t.c.losses:
        dl = x["delta"]
        d = "" if dl is None else f", x{1 + dl:.1f}" if dl >= 1 else f", {dl * 100:+.0f}%"
        e = merged.setdefault((x["area"], x["metric"]), [x["mecum"], []])
        e[1].append(f"{x['other']} ({x['against']}{d})")
    rows = [[area, metric, e[0], "; ".join(e[1])] for (area, metric), e in merged.items()]
    t.section("Dove perdiamo", [
        "Le metriche delle tabelle sotto in cui Mecum è peggio di una variante di Cua oltre la soglia (più del 10% e intervalli distinti).",
        "Elenco completo, senza selezione favorevole; tra parentesi la variante di Cua e la differenza relativa."],
              ["Area", "Metrica", "Mecum", "Cua"], rows,
              f"{len(rows)} voci in cui Mecum è peggio di almeno una variante.", "nessuna metrica in cui Mecum sia peggio")
    if not rows:
        t.out[-1] = "### Dove perdiamo\n\nNessuna metrica misurata in cui Mecum risulti peggio di Cua oltre la soglia.\n"


# ------------------------------------------------------------------ the Team document

def specs(c):
    m, r = c.meta, c.RUN
    mach, power = m.get("machine") or {}, m.get("power") or {}
    disp = ", ".join(f"{x.get('w')}x{x.get('h')}{' integrato' if x.get('builtin') else ''}{' (seat)' if x.get('seat') else ''}"
                     for x in mach.get("displays") or []) or "n/d"
    lines = [f"- Mac: {mach.get('model') or 'n/d'}, {mach.get('chip') or 'n/d'}, {mach.get('cores') or 'n/d'} core, {num(mach.get('ram_gb'), 0)} GB",
             f"- macOS {mach.get('macos') or 'n/d'}, build {mach.get('build') or 'n/d'}",
             f"- Alimentazione: {power.get('source') or 'n/d'}" + (f", batteria {power['battery_percent']}%" if power.get('battery_percent') is not None else "")
             + f"; modalità a basso consumo: {'sì' if mach.get('low_power_mode') else 'no'}; stato termico: {mach.get('thermal_state') or 'n/d'}",
             f"- Display: {disp}; Stage Manager GloballyEnabled = {m.get('stage_manager')}"]
    dv = m.get("drivers") or {}
    mecum, cua = dv.get("mecum") or {}, dv.get("cua") or {}
    lines += [f"- Mecum: commit {mecum.get('commit') or 'n/d'}, {mecum.get('dirty_files', 'n/d')} file modificati nel working tree, binario del {mecum.get('binary_built') or 'n/d'}",
              f"- Cua: versione {cua.get('version') or 'n/d'}, commit {cua.get('commit') or g(c.SUP, 'cua', 'short') or 'n/d'}, binario del {cua.get('binary_built') or 'n/d'}; "
              f"overlay lanciato come {g(c.S, 'drivers', 'cua-overlay', 'launch') or 'n/d'}",
              f"- Corsa: inizio {r.get('started') or m.get('run') or 'n/d'}, fine {r.get('finished') or 'n/d'}"
              + (f", durata {r['elapsed_s'] / 60:.0f} min" if r.get("elapsed_s") else "")]
    return lines


def caveats(c):
    m, S = c.meta, c.S
    mach = m.get("machine") or {}
    bullets = [f"Una sola macchina ({mach.get('model') or 'n/d'}, {mach.get('chip') or 'n/d'}) e un solo giorno: nessuna variazione tra macchine o tra giorni."]
    if m.get("reps"):
        bullets.append(f"{m['reps']} ripetizioni misurate per operazione: gli intervalli di Wilson sono larghi e le differenze piccole non sono distinguibili.")
    if m.get("stage_manager") is not None:
        bullets.append(f"Stage Manager = {m['stage_manager']} (0 = spento): acceso, la finestra bersaglio viene riposta come miniatura e nessun driver può adottarla.")
    for w in (m.get("warnings") or []) + (m.get("blockers") or []):
        bullets.append(f"Avviso del preflight: {w}.")
    blind = [(a, o) for a in c.apps() for o in g(c.app(S, "mecum", a), "ops", default={})
             if o not in ("open_session", "close_session", "list_windows", "observe", "observe_unchanged")
             and all(g(c.app(S, d, a), "ops", o, "n_checkable", default=0) == 0 for d in c.drivers if o in g(c.app(S, d, a), "ops", default={}))]
    total = sum(1 for a in c.apps() for o in g(c.app(S, "mecum", a), "ops", default={})
                if o not in ("open_session", "close_session", "list_windows", "observe", "observe_unchanged"))
    if total:
        bullets.append(f"Punti ciechi della sonda: {len(blind)} delle {total} operazioni di Mecum non hanno un effetto leggibile via AX "
                       f"(scroll, menu, pixel di kitty, Obsidian, Photoshop): per esse conta solo il verdetto del driver.")
    moves = g(S, "baseline", "windows_with_cursor_move")
    if moves is not None:
        bullets.append(f"La persona usa il Mac: {moves} finestre di baseline su {g(S, 'baseline', 'samples', default=0)} con il cursore mosso; "
                       "i movimenti del cursore nelle azioni non sono tutti del driver.")
    bullets.append("Lo stream a riposo di Mecum è dedotto dal gap (> 2,5 s, ADR 0036), non osservato; la fase `--phases` mostra gli eventi veri se è stata eseguita.")
    bullets.append("I token sono stimati (testo a 4 caratteri per token, immagini w x h / 750); la fase compiti dà i token fatturati dal modello.")
    if c.cua_changed:
        bullets.append(f"Cua è cambiato rispetto al 6/10 ({g(c.SUP, 'cua', 'compared_against_short')} a {g(c.SUP, 'cua', 'short')}): "
                       "letture ridotte e nuovo ciclo di passo, quindi i suoi confronti con il 6/10 non misurano un nostro guadagno.")
    if g(S, "drivers", "cua-overlay", "launch") == "embedded-daemon":
        bullets.append("`cua-overlay` gira con un daemon incorporato lanciato dall'harness, non con CuaDriver.app: il percorso con l'app installata non è stato misurato.")
    aborted = [f"{d} {a}" for d in c.drivers for a, x in g(S, "drivers", d, "apps", default={}).items() if x.get("aborted")]
    if aborted:
        bullets.append("Blocchi interrotti: " + ", ".join(aborted) + ".")
    if c.T:
        bullets.append("Fase compiti: poche ripetizioni per compito, un solo modello e un solo livello di sforzo.")
    return ["- " + b for b in bullets]


def team(c):
    t = Team(c)
    t_headline(t)
    head = t.out.pop()          # computed first so the losses table sees every marker
    t_steps(t), t_chain(t), t_cpu(t), t_ram(t), t_tokens(t), t_robust(t), t_support(t), t_tasks(t)
    body = t.out
    t.out = []
    t_losses(t)
    losses = t.out
    t.out = []
    t_tickets(t)
    tickets = t.out
    date = time.strftime("%d/%m/%Y", time.strptime(c.when, "%Y-%m-%d"))
    legend = ("**Legenda.** 🟢 Mecum meglio, 🔴 Mecum peggio, ⚪ pari (differenza entro ±10% oppure intervalli al 95% sovrapposti). "
              "Il marcatore sta accanto al valore di Cua e dice come sta Mecum rispetto a quella variante. "
              "Colonna `vs 6/10`: variazione di Mecum rispetto alla propria corsa del 6 ottobre (▲ meglio, ▼ peggio, = entro ±5%). "
              "Cua è cambiato versione dal 6/10: le sue variazioni non sono un nostro guadagno. "
              "`Cua` è la variante senza overlay, `Cua overlay` quella con l'overlay del cursore.")
    parts = [f"# Mecum contro Cua Driver: confronto del {date}\n", legend + "\n"] + losses + [head] + body
    parts += ["### Mac e versioni\n", "\n".join(specs(c)) + "\n", "### Punti da tenere in considerazione\n", "\n".join(caveats(c)) + "\n"] + tickets
    return "\n".join(parts)


# ------------------------------------------------------------------ the technical report (English)

def lat(o):
    l = g(o, "latency_ms")
    if not l or l.get("p50") is None:
        return "-"
    ci = 1.96 * l["stdev"] / l["n"] ** 0.5 if l.get("n", 0) > 1 and l.get("stdev") is not None else None
    return f"{l['p50']:,.0f} / {l['p90']:,.0f} / {l['p99']:,.0f}" + (f", mean {l['mean']:,.0f} ±{ci:,.0f}" if ci is not None else "")


def okcell(o):
    if not o or not o.get("n"):
        return ""
    w = o.get("success_wilson95")
    s = f"ok {o['n_ok']}/{o['n']}"
    if o.get("n_checkable"):
        s += f"; confirmed {o['n_confirmed']}/{o['n_checkable']}" + (f" [{w[0]:.2f}-{w[1]:.2f}]" if w else "")
    else:
        s += "; unverified"
    return s


def nodata(why):
    return f"No data: {why}.\n"


def md_link(src):
    label = src["path"] + (f"#{src['anchor']}" if src.get("anchor") else "")
    return f"[{label}]({src['url']})" if src.get("url") else f"`{label}`"


def per_app_table(c, title, fn, header_extra=None, empty="nothing recorded"):
    rows = []
    for a in c.apps():
        row = [f"{a} ({c.fw(a)})"]
        cells = [fn(a, d) for d in c.drivers]
        if any(x not in (None, "") for x in cells):
            rows.append(row + [x if x not in (None, "") else "-" for x in cells])
    if not rows:
        return nodata(empty)
    return table(["Application"] + [LABEL[d] for d in c.drivers], rows) + "\n"


EN = [("Passo equivalente, mediana su operazioni appaiate", "Equivalent step, median over matched operations"), ("Metrica", "Metric"),
      ("Mecum vs 6/10", "Mecum vs 6 Oct"), ("Cua vs 6/10", "Cua vs 6 Oct"), ("Cua cambiato versione", "Cua changed version"),
      ("Token per lettura piena (mediana tra app)", "Tokens per full read (median over apps)"),
      ("Token per lettura invariata o diff (mediana tra app)", "Tokens per unchanged / diff read (median over apps)"),
      ("CPU del driver a riposo, ultima finestra", "Driver CPU at rest, last window"), ("CPU del driver durante le azioni", "Driver CPU during actions"),
      ("RAM del driver, mediana", "Driver RAM, median"), ("RAM del driver, picco", "Driver RAM, peak"),
      ("Successo dichiarato (ok / chiamate)", "Reported success (ok / calls)"), ("Successo confermato dalla sonda", "Probe-confirmed success"),
      ("Primo piano cambiato (azioni)", "Frontmost app changed (actions)"), ("Cursore spostato durante la chiamata", "Cursor moved during the call"),
      ("Finestra sul display della persona", "Window on the person's display")]


def r_headline(c):
    t = Team(c)
    t_headline(t)
    if not t.out or "|" not in t.out[0]:
        return nodata("no comparable metrics")
    text = t.out[0].split("\n\n", 2)[2].rsplit("\n\n**Conclusione:**", 1)[0] + "\n"
    for it, en in EN:
        text = text.replace(it, en)
    return text


def r_step(c):
    rows = []
    for a in c.apps():
        ops = c.matched_ops(c.S, a, c.drivers)
        if not ops:
            continue
        row = [f"{a} ({c.fw(a)})", len(ops)]
        for d in c.drivers:
            ps = {q: wmed([(g(c.app(c.S, d, a), "steps", o, "latency_ms", q), g(c.app(c.S, d, a), "steps", o, "n_ok", default=0)) for o in ops])
                  for q in ("p50", "p90", "p99")}
            row.append(f"{num(ps['p50'])} / {num(ps['p90'])} / {num(ps['p99'])}")
        own = c.own_ops(a)
        cur, base = (c.pooled_step(c.S, "mecum", {a: own})[0], c.pooled_step(c.B, "mecum", {a: own})[0]) if own else (None, None)
        row += [f"{num(base)} → {num(cur)} ({arrow(cur, base)})" if own else "n/d"]
        rows.append(row)
    return table(["Application", "Matched ops"] + [f"{LABEL[d]} p50 / p90 / p99 (ms)" for d in c.drivers] + ["Mecum 6 Oct → now (same operations)"], rows) + "\n" if rows else nodata("no operation completed by every driver")


def r_chain(c):
    rows = []
    for a in c.apps():
        for d in c.drivers:
            ch = g(c.app(c.S, d, a), "chain")
            for p, x in (ch or {}).items():
                if p == "wake":
                    continue
                s = x["step_ms"]
                rows.append([a, LABEL[d], f"{float(p):g}", x["n"], num(s["p50"]), num(s["p90"]), num(s["p99"]), num(x["first_step_ms"]),
                             num(x["later_steps_ms"]), num(x["gap_s_median"], 2)])
            w = (ch or {}).get("wake")
            if w and w.get("resting_steps"):
                rows.append([a, LABEL[d], "wake", w["resting_steps"], f"resting {num(w['resting_p50_ms'])}", f"warm {num(w['warm_p50_ms'])}",
                             "", f"cost {num(w['wake_cost_ms'])}", "", ""])
    return (table(["App", "Driver", "Pause s", "n", "p50 ms", "p90", "p99", "First step after rest", "Later steps", "Gap s (median)"], rows)
            + "\n\nThe wake row counts Mecum steps that followed a gap above 2.5 s (ADR 0036); resting is inferred, not observed.\n") if rows else nodata("chain mode was not run")


def r_reads(c):
    rows = []
    for a in c.apps():
        for kind in ("full", "unchanged"):
            for d in c.drivers:
                o = g(c.app(c.S, d, a), "reads", kind)
                if o and o.get("n"):
                    t = o["tokens"]
                    ob = g(c.app(c.B, d, a), "reads", kind)
                    rows.append([a, LABEL[d], kind if d == "mecum" or kind == "full" else "diff (since:latest)", lat(o), num(t["text"]), num(t["image"]), num(t["total"]),
                                 num(g(ob, "tokens", "total")) if ob else "n/d"])
    return table(["App", "Driver", "Read", "ms p50 / p90 / p99", "Text tokens", "Image tokens", "Total", "Total on 6 Oct"], rows) + "\n" if rows else nodata("no read rows")


def r_tokens_step(c):
    rows = []
    for a in c.apps():
        for op in sorted({o for d in c.drivers for o in g(c.app(c.S, d, a), "steps", default={})}):
            cells = []
            for d in c.drivers:
                s = g(c.app(c.S, d, a), "steps", op)
                cells.append("-" if not s or not s.get("n_ok") else f"{num(s['tokens']['text'])} + {num(s['tokens']['image'])} = {num(s['tokens']['total'])}")
            rows.append([a, op] + cells)
    return table(["App", "Step"] + [f"{LABEL[d]} text + image = total" for d in c.drivers], rows) + "\n" if rows else nodata("no steps")


def r_cpu(c):
    rows = []
    for a in c.apps():
        for d in c.drivers:
            x = c.app(c.S, d, a)
            for kind, o in (("action", x.get("actions")), ("full read", g(x, "reads", "full"))):
                if o and o.get("n"):
                    k, e = o["cpu"], o["energy_mj"]
                    rows.append([a, LABEL[d], kind, num(k["driver_ms"], 1), num(k["proxy_ms"], 1), num(k["app_ms"], 1), num(k["windowserver_ms"]),
                                 num(e["driver"]), num(e["app"])])
    return table(["App", "Driver", "Call", "Driver ms", "Proxy ms", "App ms", "WindowServer ms (10 ms ticks)", "Driver mJ", "App mJ"], rows) + "\n" if rows else nodata("no CPU rows")


def r_idle(c):
    rows = []
    for a in c.apps():
        for d in c.drivers:
            for name, w in (g(c.app(c.S, d, a), "idle", default={})).items():
                rows.append([a, LABEL[d], name, num(w["t_since_last_call_s"]), num(w["driver_ms_per_s"], 2), num(w["proxy_ms_per_s"], 2),
                             num(w["app_ms_per_s"], 2), num(w["windowserver_over_baseline_ms_per_s"]), num(w["wakeups_per_s"], 1)])
    return (f"WindowServer baseline without a driver: {num(g(c.S, 'baseline', 'windowserver_ms_per_s'))} ms/s over "
            f"{g(c.S, 'baseline', 'samples', default=0)} samples. Target for an open session at rest: {IDLE_TARGET} ms/s.\n\n"
            + table(["App", "Driver", "Window", "Seconds since last call", "Driver ms/s", "Proxy ms/s", "App ms/s", "WS over baseline", "Wakeups/s"], rows) + "\n") if rows else nodata("no idle windows")


def r_memory(c):
    rows = [[LABEL[d], num(g(c.S, "drivers", d, "startup_ms")), num(g(c.S, "drivers", d, "footprint_mb", "median"), 1), num(g(c.S, "drivers", d, "footprint_mb", "peak"), 1),
             num(g(c.B, "drivers", d, "footprint_mb", "median"), 1) if d in g(c.B, "drivers", default={}) else "n/d"] for d in c.drivers]
    out = table(["Driver", "MCP ready ms", "Footprint median MB", "Peak MB", "Median on 6 Oct"], rows) + "\n"
    soak = []
    for a in c.apps():
        for d in c.drivers:
            k = g(c.app(c.S, d, a), "soak")
            if k:
                soak.append([a, LABEL[d], k["steps"], k["samples"], num(g(k, "driver_footprint_mb", "first"), 1), num(g(k, "driver_footprint_mb", "last"), 1),
                             num(g(k, "driver_footprint_mb", "slope_mb_per_100_steps"), 2), num(g(k, "app_footprint_mb", "slope_mb_per_100_steps"), 2),
                             k["errors"], k["stalls"], lat({"latency_ms": k["latency_ms"]}), num(k["latency_drift_ms"])])
    return out + "\n" + (table(["App", "Driver", "Steps", "Samples", "First MB", "Last MB", "Driver MB/100 steps", "App MB/100 steps", "Errors", "Stalls",
                                "Step ms p50 / p90 / p99", "Drift ms (last 50 vs first 50)"], soak) + "\n" if soak else nodata("soak was not run"))


def r_robust(c):
    rows, fails = [], []
    for a in c.apps():
        for d in c.drivers:
            x = g(c.app(c.S, d, a), "actions")
            if c.session_refused(d, a) and not (x and x.get("n")):
                rows.append([a, LABEL[d], "session refused", "-", "open_session failed; no action block ran"])
            if x and x.get("n"):
                w = x["ok_wilson95"]
                rows.append([a, LABEL[d], f"{x['n_ok']}/{x['n']}", f"{w[0]:.2f}-{w[1]:.2f}", okcell(x).split("; ", 1)[1] if "; " in okcell(x) else "-"])
            for op, o in g(c.app(c.S, d, a), "ops", default={}).items():
                fails += [f"- {LABEL[d]} · {a} · {op} x{n}: {err}" for err, n in (o.get("failures") or {}).items()]
            fails += [f"- {LABEL[d]} · {a} block aborted: {e}" for e in g(c.app(c.S, d, a), "aborted", default=[])]
    out = table(["App", "Driver", "Reported ok / actions", "Wilson 95%", "Probe confirmation"], rows) + "\n" if rows else nodata("no actions")
    return out + ("\n**Failures (most common per operation)**\n\n" + "\n".join(fails) + "\n" if fails else "")


def r_intrusion(c):
    rows = []
    for a in c.apps():
        for d in c.drivers:
            i = g(c.app(c.S, d, a), "intrusion")
            if i and i["calls"]:
                rows.append([a, LABEL[d], i["calls"], i["frontmost_changed"], i["cursor_moved"], i["cursor_moved_during_call"], i["window_on_user_display"]])
    return table(["App", "Driver", "Calls probed", "Frontmost changed", "Cursor moved (probe window)", "Cursor moved (call alone)", "Window on user display"], rows) + "\n" if rows else nodata("no intrusion probe rows")


def r_support(c):
    out = []
    for f, info in support_rows(c):
        cells = {(x["driver"], x["capability"]): x for x in c.SUP.get("cells", []) if x["framework"] == f["id"]}
        caps = [k for k in c.SUP.get("capabilities", [])]
        rows = []
        for cap in caps:
            for d in ("mecum", "cua"):
                x = cells.get((d, cap))
                if not x:
                    continue
                m = c.measured(d, f["app"], cap)
                w = works(m)
                meas = "not run" if not m["n"] else f"{m['ok']}/{m['n']}" + (f", confirmed {m['conf']}/{m['chk']}" if m["chk"] else ", unverified")
                flag = ""
                if c.session_refused(d, f["app"]) and x["claim"] == "supported":
                    flag = "declared supported but fails (session refused)"
                elif x["claim"] in ("not supported", "foreground only") and w:
                    flag = "declared unsupported but works"
                elif x["claim"] == "supported" and w is False:
                    flag = "declared supported but fails"
                src = "; ".join(md_link(s) for s in x["sources"])
                rows.append([cap, LABEL[d], x["claim"], x["basis"], meas, flag or "-", src])
        out.append(f"<details>\n<summary>{f['framework']} ({f['app']})</summary>\n\n"
                   + table(["Capability", "Driver", "Declared", "Basis", "Measured now", "Flag", "Source"], rows) + "\n\n</details>")
    return "\n".join(out) + "\n" if out else nodata("support.json not available")


def r_tasks(c):
    T, out = c.T or {}, []
    if not T:
        return nodata("the task phase was not run")
    for d in [x for x in DRV if x in T]:
        rows = []
        for k, cell in {**T[d]["tasks"], "ALL (supported)": T[d]["within_declared_support"], "ALL (every run)": T[d]["all_runs"]}.items():
            s = cell["success"]
            w = s["wilson95"]
            rows.append([k, cell["runs"], cell["skipped"], cell["inconclusive"], f"{s['count']}/{s['of']}", f"{w[0]:.2f}-{w[1]:.2f}" if w else "-",
                         f"{num(g(cell, 'wall_s', 'median'))} / {num(g(cell, 'wall_s', 'p90'))}",
                         f"{num(g(cell, 'billed_tokens', 'median'))} / {num(g(cell, 'billed_tokens', 'p90'))}",
                         f"{num(g(cell, 'cost_usd', 'median'), 3)} / {num(g(cell, 'cost_usd', 'p90'), 3)}",
                         f"{num(g(cell, 'tool_calls', 'median'))} / {num(g(cell, 'tool_calls', 'p90'))}",
                         f"{num(g(cell, 'tool_ms', 'median'))} / {num(g(cell, 'tool_ms', 'p90'))}",
                         f"{num(g(cell, 'think_ms', 'median'))} / {num(g(cell, 'think_ms', 'p90'))}", cell["tool_errors"],
                         f"{cell['intrusion']['focus_changes']}/{cell['intrusion']['cursor_moves']}"])
        out.append(f"**{LABEL[d]}**\n\n" + table(["Task", "Runs", "Skipped", "Inconclusive", "Success", "Wilson 95%", "Wall s p50 / p90", "Billed tokens p50 / p90",
                                                  "Cost USD p50 / p90", "Tool calls p50 / p90", "Tool ms p50 / p90", "Think ms p50 / p90", "Tool errors",
                                                  "Focus changes / cursor moves"], rows) + "\n")
    return "\n".join(out)


def r_deltas(c):
    metrics = [("Full read tokens", lambda a: g(a, "reads", "full", "tokens", "total"), tok, True),
               ("Unchanged / diff read tokens", lambda a: g(a, "reads", "unchanged", "tokens", "total"), tok, True),
               ("Driver CPU at rest (last window, ms/s)", idle_total, rate, True),
               ("Driver CPU per action (ms)", lambda a: g(a, "actions", "cpu", "driver_ms"), ms, True),
               ("Full read latency p50 (ms)", lambda a: g(a, "reads", "full", "latency_ms", "p50"), ms, True),
               ("Action success rate (reported ok)", lambda a: g(a, "actions", "ok_rate"), lambda v: f"{v * 100:.0f}%", False)]
    out = []
    for d in ("mecum", "cua"):
        rows = []
        for label, getter, fmt, low in metrics:
            cur, base = c.own(getter, d)
            rows.append([label, fmt(base) if base is not None else "n/d", fmt(cur) if cur is not None else "n/d",
                         arrow(cur, base, low) if d == "mecum" or not c.cua_changed else (f"Cua changed version ({change(cur, base) * 100:+.0f}%)" if change(cur, base) is not None else "n/d")])
        mem_c, mem_b = g(c.S, "drivers", d, "footprint_mb", "median"), g(c.B, "drivers", d, "footprint_mb", "median")
        rows.append(["Footprint median (MB)", num(mem_b, 1), num(mem_c, 1), arrow(mem_c, mem_b) if d == "mecum" or not c.cua_changed else
                     (f"Cua changed version ({change(mem_c, mem_b) * 100:+.0f}%)" if change(mem_c, mem_b) is not None else "n/d")])
        sets = {a: c.own_ops(a, d) for a in c.apps()}
        cur, base = c.pooled_step(c.S, d, sets)[0], c.pooled_step(c.B, d, sets)[0]
        rows.insert(0, ["Equivalent step p50 (ms, same operations)", num(base), num(cur), arrow(cur, base) if d == "mecum" or not c.cua_changed else
                        (f"Cua changed version ({change(cur, base) * 100:+.0f}%)" if change(cur, base) is not None else "n/d")])
        note = ("" if d == "mecum" else (f"\n\nCua moved from {g(c.SUP, 'cua', 'compared_against_short')} to {g(c.SUP, 'cua', 'short')}: its reads were slimmed and its "
                                         "step loop changed (`run_actions` with `observe`), so these differences are not a Mecum gain.\n" if c.cua_changed else ""))
        out.append(f"**{LABEL[d]}**, medians over the apps both runs have, same operations for steps.\n\n"
                   + table(["Metric", "6 Oct", "Now", "Change"], rows) + note)
    ch = c.SUP.get("cua_changes_since_20261006") or []
    if ch:
        out.append("**What changed in Cua between the two commits**\n\n" + "\n".join(
            f"- {x['summary']}" + (f" Frameworks: {', '.join(x['frameworks'])}." if x.get("frameworks") else "") + (f" Commits: {', '.join(x['commits'])}." if x.get("commits") else "")
            for x in ch))
    return "\n\n".join(out) + "\n"


def r_per_op(c):
    out = []
    for a in c.apps():
        names = sorted({o for d in c.drivers for o in g(c.app(c.S, d, a), "ops", default={})}, key=order)
        rows = []
        for o in names:
            rows.append([o] + [(lambda x: f"{lat(x)}; {okcell(x)}" if x else "-")(g(c.app(c.S, d, a), "ops", o)) for d in c.drivers])
        if rows:
            out.append(f"<details>\n<summary>{a} ({c.fw(a)})</summary>\n\nCell: p50 / p90 / p99 ms, mean ±95% CI; reported ok; probe-confirmed with Wilson 95%.\n\n"
                       + table(["Operation"] + [LABEL[d] for d in c.drivers], rows) + "\n\n</details>")
    return "\n".join(out) + "\n" if out else nodata("no operation rows")


PARITY = [
    ("Watcher", "On: the one-a-second focus-recovery heartbeat re-reads the cursor, the event tap and the focus preparation", "Post-action window watch polls every 50 ms for up to 1,000 ms (default kept)"),
    ("Watchdog", "On: the eight seat-invariant checks, run on events and one heartbeat a second", "No equivalent"),
    ("Cursor fence", "On: HID-level event tap that keeps the physical cursor on physical displays", "No; the agent cursor overlay is a separate drawn cursor (variant `cua-overlay` only)"),
    ("Window follower", "On: moves windows the target opens into the seat", "No; the target window stays where it is"),
    ("Window stream", "On: persistent window stream of the attested window (ADR 0034), observation reads from it", "No; a capture per read"),
    ("Stream rest", "On: ADR 0036, the stream drops to 1 fps after 2.5 s unused (offline tests only on 7 Oct)", "Not applicable"),
    ("Telemetry", "Not applicable", "Off (`CUA_DRIVER_RS_TELEMETRY_ENABLED=0`)"),
    ("Defaults", "Release `mecum-mcp-stdio`, research opt-in for an unvalidated macOS build (`MECUM_BENCH_UNVALIDATED=1`)", "Every default kept, including the 1,000 ms post-action window watch; `cua-fast` is never in a report"),
]


def r_parity(c):
    rows = [list(x) for x in PARITY]
    launch = g(c.S, "drivers", "cua-overlay", "launch")
    variants = [["`mecum`", "`.build/release/mecum-mcp-stdio <knowledge dir>`, one Seat session per app block, `MECUM_APP_SUPPORT_DIR` in the run directory"],
                ["`cua`", "`cua-driver mcp --direct`: the MCP process owns the runtime, no agent cursor overlay"],
                ["`cua-overlay`", {"app-daemon": "bare `cua-driver mcp`, proxying to the daemon of `/Applications/CuaDriver.app` (overlay on)",
                                   "embedded-daemon": "the harness spawns `cua-driver serve --embedded --socket <run dir>/cua.sock` as its own child (the documented embedding path, "
                                                      "no CuaDriver.app installed) and speaks MCP to `cua-driver mcp --embedded --socket <same>`; overlay on"}.get(launch, "daemon-backed Cua, overlay on (launch kind not recorded in this run)")]]
    return table(["Component", "Mecum", "Cua"], rows) + "\n\n" + table(["Variant", "Launched as"], variants) + "\n"


def na(x):
    return "n/a" if x in (None, "", []) else x


def methodology(c):
    m, rs = c.meta, c.S.get("meta") or []
    mach, power, dv = m.get("machine") or {}, m.get("power") or {}, m.get("drivers") or {}
    mecum, cua = dv.get("mecum") or {}, dv.get("cua") or {}
    rows = [["Mac", f"{na(mach.get('model'))}; {na(mach.get('chip'))}; {na(mach.get('cores'))} cores; {num(mach.get('ram_gb'), 0).replace('n/d', 'n/a')} GB"],
            ["OS", f"macOS {na(mach.get('macos'))}, build {na(mach.get('build'))}"],
            ["Power / thermal", f"{na(power.get('source'))}; battery {na(power.get('battery_percent'))}%; low power {na(mach.get('low_power_mode'))}; thermal {na(mach.get('thermal_state'))}"],
            ["Displays", ", ".join(f"{x.get('w')}x{x.get('h')}{' built-in' if x.get('builtin') else ''}{' (Seat)' if x.get('seat') else ''}" for x in mach.get("displays") or []) or "n/a"],
            ["Stage Manager", f"GloballyEnabled = {na(m.get('stage_manager'))}"],
            ["Mecum", f"commit {na(mecum.get('commit'))}, {na(mecum.get('dirty_files'))} modified files, binary built {na(mecum.get('binary_built'))}"],
            ["Cua", f"{na(cua.get('version'))}, commit {na(cua.get('commit') or g(c.SUP, 'cua', 'short'))}, binary built {na(cua.get('binary_built'))}; "
                    f"CuaDriver.app installed: {na(cua.get('app_daemon_installed'))}"],
            ["Run", f"started {na(c.RUN.get('started') or m.get('run'))}; finished {na(c.RUN.get('finished'))}"
                    + (f"; {c.RUN['elapsed_s'] / 60:.0f} min" if c.RUN.get("elapsed_s") else "")],
            ["Blockers / warnings", f"{m.get('blockers') or 'none'} / {m.get('warnings') or 'none'}"]]
    modes = [[r.get("mode"), r.get("run"), r.get("reps"), r.get("order"), ", ".join(r.get("apps") or []), r.get("selected") and ", ".join(r["selected"]),
              r.get("cooldown"), r.get("idle"), r.get("pauses") or "-", r.get("soak_steps") or "-", "yes" if r.get("phases") else "no"] for r in rs]
    return (table(["Item", "Configuration"], rows) + "\n\n**Invocations recorded in the data**\n\n"
            + (table(["Mode", "Started", "Reps", "Order", "Apps", "Drivers", "Cooldown s", "Idle windows x s", "Pauses", "Soak steps", "Phases"], modes)
               if modes else "No meta rows in the data.") + "\n")


METHOD_TEXT = """Each driver runs in its own block per application, in ABBA order (mecum, cua, cua-overlay, cua-overlay, cua, mecum) so slow drift
is spread over the drivers. Every block starts a fresh driver process after a cooldown. One warm-up and `--reps` measured repetitions per
operation; the warm-up is excluded. Latency is client wall time from request to reply including JSON and pipe transport. Resource deltas
come from `proc_pid_rusage` around the call (WindowServer through `ps`, 10 ms resolution). An independent probe (AX values, frontmost app,
cursor, windows and their display) runs outside the measured window.

**Success** is an effect the probe confirmed. `honest_miss`, `ambiguous`, `refused`, `error` and an `acted_unverified` that says delivery
failed count as failures; an operation the probe cannot see stays unverified and never counts as a success. The equivalent step is one
`run_actions` call with `observe:true` for Cua and the action call alone for Mecum (its reply already has the scene); a menu adds a diff read
for Cua. The pooled step medians use the operations every driver completed, weighted by their repetitions. **Tokens**: text is characters / 4,
images are width x height / 750 after resizing; they estimate context, not billed tokens (the task phase has billed tokens). **Intervals**:
Wilson 95% for proportions; the mean of a latency has a normal 95% interval from its standard deviation. A marker is "even" when the
difference is within 10% or the intervals overlap."""

LIMITS = """- One machine on one day, a small operation set and few repetitions per operation: small differences are not distinguishable.
- The probe sees AX values, not pixels: kitty, Obsidian and Photoshop pixel effects, scrolls and menu commands stay unverified.
- The person may use the Mac during a run: the cursor and WindowServer observations carry that noise; idle and baseline rows carry the same check.
- Mecum's stream rest is inferred from the gap since the previous call; a `--phases` run shows the real `preview.rest` events.
- `cua-overlay` is measured with an embedded daemon when CuaDriver.app is not installed; the app-daemon path is a different process layout.
- Token counts are estimates. The task phase counts billed tokens for one model at one effort level with few repetitions per task.
- The benchmark server is the CLI path (`AutomationSession`), not the app's `BrokeredAutomationSession`; app-only behaviours are not measured.
- Cua changed version since 6 October: its deltas against that run say nothing about Mecum."""

REPRO = """```sh
cd Tools/Driver/CUAComparison
./bench.sh                     # everything, in order; a time estimate is printed first
./bench.sh --quick             # smoke test: 2 reps, chain 0/3 s, soak 20, one task rep
./bench.sh --apps Calculator,TextEdit --reps 8 --phases
```

`bench.sh` runs the preflight (`prepare.py`), builds both drivers when stale, the per-call run, chain mode, the soak, optionally the phase
breakdown, the model task phase (`tasks.py`), `summarize.py`, and `report.py`. Everything lands in `~/Forte_Projects/_bench/runs/<YYYYMMDD-HHMM>/`
(raw JSONL, summaries, logs); the two reports are written to `~/Downloads/`. Stage Manager must be off and no other Mecum may run."""


def report(c, phases_text=None):
    S = c.S
    mach = c.meta.get("machine") or {}
    sets = {a: o for a, o in c.step_sets().items() if o}
    steps = {d: c.pooled_step(S, d, sets)[0] for d in c.drivers}
    reads, _ = c.across(S, lambda a: g(a, "reads", "full", "tokens", "total"))
    idle, _ = c.across(S, idle_total)
    summary = [f"- Equivalent step, median over matched operations: " + "; ".join(f"{LABEL[d]} {num(steps[d])} ms" for d in c.drivers) + ".",
               f"- Tokens per full read, median over apps: " + "; ".join(f"{LABEL[d]} {num(reads[d])}" for d in c.drivers) + ".",
               f"- Driver CPU at rest, last idle window, median over apps: " + "; ".join(f"{LABEL[d]} {num(idle[d], 2)} ms/s" for d in c.drivers) + ".",
               f"- Driver footprint median: " + "; ".join(f"{LABEL[d]} {num(g(S, 'drivers', d, 'footprint_mb', 'median'), 0)} MB" for d in c.drivers) + "."]
    sec = lambda n, title, body: f"## {n}. {title}\n\n{body}\n"  # noqa: E731
    out = [f"# Mecum vs Cua Driver: macOS benchmark\n",
           f"**{time.strftime('%-d %B %Y', time.strptime(c.when, '%Y-%m-%d'))} · {mach.get('model') or 'n/d'}, {mach.get('chip') or 'n/d'}, {num(mach.get('ram_gb'), 0)} GB · macOS {na(mach.get('macos'))} ({na(mach.get('build'))})**\n",
           "This report compares Mecum (`mecum-mcp-stdio`, full stack) with Cua Driver (variants `cua` and `cua-overlay`) on the same windows. "
           "It extends the 6 October report with per-operation percentiles, intervals, chain timing, resources over time, a support matrix and real-model tasks. "
           "All numbers come from the summaries of this run; the 6 October values are the baseline of the delta tables.\n",
           "**Summary**\n\n" + "\n".join(summary) + "\n",
           sec(1, "Method", methodology(c) + "\n" + METHOD_TEXT),
           sec(2, "Parity of the components", r_parity(c)),
           sec(3, "Headline metrics", "Medians over the apps every driver has data for; the marker beside a Cua value is Mecum against that variant.\n\n" + r_headline(c)),
           sec(4, "Equivalent step per application", "Pooled over the operations every driver completed (weighted median of the per-operation percentiles).\n\n" + r_step(c)),
           sec(5, "Delay between steps", r_chain(c)),
           sec(6, "Reads", r_reads(c)),
           sec(7, "Tokens per step", r_tokens_step(c)),
           sec(8, "CPU and energy per call", "Medians per call; app CPU and energy belong to the target process.\n\n" + r_cpu(c)),
           sec(9, "Idle CPU", r_idle(c)),
           sec(10, "Memory and soak", r_memory(c)),
           sec(11, "Robustness", r_robust(c)),
           sec(12, "Intrusion seen by the independent probe", r_intrusion(c)),
           sec(13, "Support: declared against measured", "Declared support is each driver's own documentation (Cua at c1c2b5f; Mecum paths are repo-relative, with no public URL). "
               "`cua` is the measured variant. Flags mark a declared refusal that works and a declared support that fails.\n\n" + r_support(c)),
           sec(14, "Tasks with a real model", r_tasks(c)),
           sec(15, "Phase breakdown", ("```\n" + phases_text.strip() + "\n```\n") if phases_text else nodata("`--phases` was not run")),
           sec(16, "Changes since 6 October", r_deltas(c)),
           sec(17, "Limits", LIMITS),
           sec(18, "Reproduction", REPRO),
           sec(19, "Per-operation latency", r_per_op(c))]
    return "\n".join(out).replace("n/d", "n/a")


# ------------------------------------------------------------------ main

def load(path, default=None):
    if path and os.path.exists(os.path.expanduser(path)):
        return json.load(open(os.path.expanduser(path)))
    return default


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--summary", required=True, help="summary.json of the current run (summarize.py --json)")
    p.add_argument("--tasks", help="tasks.py --summary output")
    p.add_argument("--baseline", help="summary.json of 6 October (default: computed from the raw rows)")
    p.add_argument("--support", default=os.path.join(HERE, "support.json"))
    p.add_argument("--tickets", default=os.path.join(HERE, "tickets.json"))
    p.add_argument("--run", help="run.json written by bench.py (start, finish, duration)")
    p.add_argument("--phases-txt", help="phase table text of a --phases run")
    p.add_argument("--out-dir", default="~/Downloads")
    p.add_argument("--date", default=time.strftime("%Y%m%d"))
    o = p.parse_args()
    base = load(o.baseline)
    if base is None and os.path.exists(BASELINE_ROWS):
        base = json.loads(json.dumps(summarize([BASELINE_ROWS]), default=str))
    c = Ctx(load(o.summary), base or {"drivers": {}}, load(o.tasks), load(o.support, {}), load(o.tickets, {}), load(o.run, {}))
    if not c.S:
        sys.exit("empty summary")
    phases = open(o.phases_txt).read() if o.phases_txt and os.path.exists(o.phases_txt) else None
    out = os.path.expanduser(o.out_dir)
    os.makedirs(out, exist_ok=True)
    paths = []
    for name, text in ((f"MecumVsCua-Team-{o.date}.md", team(c)), (f"MecumVsCua-Report-{o.date}.md", report(c, phases))):
        path = os.path.join(out, name)
        open(path, "w").write(text)
        paths.append(path)
    print("\n".join(paths))


if __name__ == "__main__":
    main()
