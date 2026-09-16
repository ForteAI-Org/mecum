#!/usr/bin/env python3
#
#  compat-report.py
#  AgentSeatKit
#
#  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
#
"""Assembles the compatibility report for the macOS build this Mac is running.

It runs nothing. The evidence comes from the tiers `make compat-report` has
already run: the tier logs `run-tier.sh` left behind and the benchmark JSON.
This script reads them, writes `Documentation/Driver/compatibility/Build<build>.md` for a person and
`Documentation/Driver/compatibility/Build<build>.json` as a draft ledger entry, and never touches
`validated-builds.json`: promotion is a separate, human act.

The draft's `state` per primitive is `verified` only when every step that
applies to it passed on this machine. A step whose suite did not run leaves the
row `untested`, which is what stops `promote-build` from copying it in.
"""

import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]  # Tools/Driver/Scripts -> repository root
LEDGER = ROOT / "Sources/Driver/PrivateSymbols/Ledger/validated-builds.json"

# Which Facility each primitive of the ledger belongs to, for the derived
# verdict. A name that is not listed belongs to no Facility and is reported on
# its own line: the verdicts must not silently ignore a row.
FACILITIES = {
    "display": [
        "objc_msgSend", "CGVirtualDisplay", "CGVirtualDisplayDescriptor",
        "CGVirtualDisplayMode", "CGVirtualDisplaySettings",
        "CGVirtualDisplay.initWithDescriptor:", "CGVirtualDisplay.applySettings:",
        "CGVirtualDisplayMode.initWithWidth:height:refreshRate:",
        "_AXUIElementGetWindow", "CGDisplayIsOnline.removedDisplayReturns0xFFFFFFFF",
        "CGVirtualDisplay.releaseRemovesDisplay",
        "NSWindow.globalFrameOnOtherScreenLandsOnMain",
        "StageManager.stashesInactiveWindowsToThumbnail",
        "AXRaiseAction.stagesWithoutActivating",
    ],
    "input": [
        "SLSMainConnectionID", "SLSGetWindowOwner", "SLSGetConnectionPSN",
        "SLEventRecordPointer", "SLPSPostEventRecordTo", "CGEventSetWindowLocation",
        "CGEvent.integerValueField.51", "CGEvent.integerValueField.52",
        "SLPSPostEventRecordTo.activationRecord", "SLPSPostEventRecordTo.keyWindowRecord",
    ],
    "fence": [],
    "capture": [
        "CALayer.contentsAcceptsIOSurface",
        "SCStreamConfiguration.defaultsDifferFromDocumentation",
    ],
}

# The steps of spec section 6, what each proves, the suites that are its oracle,
# and the tier logs whose verdict decides it. The tier is what is read and not
# the suite, because the tier's own count assertion is what proves the suite ran
# at all: a green exit status on this package does not.
STEPS = [
    ("resolution", "every symbol, class and selector resolves at runtime",
     "SystemGateHostTests", ["host-display-suites"]),
    ("abi shape", "the record's declared length and its allocated size",
     "SystemGateHostTests", ["host-display-suites"]),
    ("cross validation", "fields 51 and 52 against 0x3C and 0x40, "
     "CGEventSetWindowLocation against 0x20 and 0x28, SLSGetWindowOwner on our own window",
     "SystemGateHostTests", ["host-display-suites"]),
    ("effect", "display created and removed, tap installed, the input matrix on both "
     "target families, a stream frame marked complete, a Still",
     "VirtualDisplayHostTests, CursorFenceHostTests, CaptureHostTests, SeatHostTests, "
     "LiveTests",
     ["host-seat-cycle", "host-display-suites", "live"]),
]


def sysctl(name):
    return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()


def toolchain():
    out = subprocess.run(["xcrun", "swift", "--version"], capture_output=True, text=True)
    return " ".join(out.stdout.split("\n")[0].split())


def read_logs(directory):
    """Every tier log, by label, as text."""
    logs = {}
    for path in sorted(pathlib.Path(directory).glob("agentseat-tier-*.log")):
        label = path.name[len("agentseat-tier-"):-len(".log")]
        logs[label] = path.read_text(errors="replace")
    return logs


def tier_result(logs, label):
    """Read the wrapper's validated counts, including its runner exit check."""
    lines = [line for line in logs.get(label, "").splitlines()
             if line.startswith("TIER_RESULT ")]
    if len(lines) != 1:
        return None
    try:
        result = json.loads(lines[0][len("TIER_RESULT "):])
        if any(type(result.get(key)) is not int or result[key] < 0
               for key in ("reported", "executed", "skipped")):
            return None
        if result["executed"] + result["skipped"] != result["reported"]:
            return None
        if result.get("status") not in ("passed", "failed"):
            return None
        return result
    except (ValueError, TypeError):
        return None


def tier_verdict(logs, label):
    """A skipped required test leaves the evidence incomplete.

    Live's explicitly optional and manual experiments are outside the unattended
    acceptance run. Their omissions stay in the report; required tests may not
    be skipped because a fixture, browser or permission is missing.
    """
    result = tier_result(logs, label)
    if result is None:
        return "not run"
    if result["status"] == "failed":
        return "failed"
    if result["executed"] == 0:
        return "not run"
    if result["skipped"]:
        skips = result.get("skip_details", [])
        optional = label == "live" and len(skips) == result["skipped"] and all(
            (any(f"{flag}=1 is required: this optional calibration is disabled by default."
                 in line for flag in ("AGENTSEAT_TEXT_DELIVERY", "AGENTSEAT_TYPING_SWEEP",
                                     "AGENTSEAT_STASHED_ADOPTION"))
             or ('skipped: "needs AGENTSEAT_MANUAL_TESTS=1 and a person at the keyboard"' in line
                 and any(f'Test "{name}"' in line for name in (
                     "the person's own held modifier stays out of the kit's events",
                     "a transition the kit never released is cleared by the person's own key",
                 ))))
            for line in skips
        )
        if not optional:
            return "incomplete"
    return "passed"


def worst(verdicts):
    if "failed" in verdicts:
        return "failed"
    if "not run" in verdicts:
        return "not run"
    return "incomplete" if "incomplete" in verdicts else "passed"


def matrix_rows(logs):
    rows = []
    for text in [logs.get("live", "")]:
        block = False
        for line in text.splitlines():
            if line.startswith("| target"):
                block = True
            if block and line.startswith("|"):
                rows.append(line.rstrip())
            elif block and not line.startswith(("|", " ")):
                block = False
    return rows


def bench_rows(directory):
    rows = []
    for path in sorted(pathlib.Path(directory).glob("*.json")):
        try:
            report = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        for result in report.get("results", []):
            budget = result.get("budget") or {}
            status = result.get("status", "")
            if status != "measured":
                met = "-"
            elif budget.get("passed") is None:
                met = "-"
            else:
                met = "pass" if budget["passed"] else "FAIL"
            rows.append((
                result.get("name", path.stem),
                result.get("unit", ""),
                result.get("p50", ""),
                result.get("p95", ""),
                budget.get("limit", ""),
                status,
                met,
            ))
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--logs", default=os.environ.get("TMPDIR", "/tmp"))
    parser.add_argument("--bench", default=str(ROOT / ".build/bench"))
    parser.add_argument("--out", default=str(ROOT / "Documentation/Driver/compatibility"))
    options = parser.parse_args()

    build = sysctl("kern.osversion")
    product = sysctl("kern.osproductversion")
    model = sysctl("hw.model")
    if not build or not model:
        print("compat-report: sysctl gave no build identity", file=sys.stderr)
        return 2

    ledger = json.loads(LEDGER.read_text())
    entries = ledger["builds"]
    template_build = build if build in entries else sorted(entries)[-1]
    template = entries[template_build]

    logs = read_logs(options.logs)
    step_state = {
        name: worst([tier_verdict(logs, tier) for tier in tiers])
        for name, _, _, tiers in STEPS
    }
    all_passed = all(state == "passed" for state in step_state.values())
    verified = "verified" if all_passed else "untested"

    # The draft. Same rows as the template, because the template is the shape of
    # what has to be true; the state is this machine's answer.
    draft = {
        "productVersion": product,
        "hardware": sorted(set(template["hardware"] + [model])) if build == template_build else [model],
        "validatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "validatedBy": "compat-suite + " + (subprocess.run(
            ["id", "-F"], capture_output=True, text=True).stdout.strip() or os.environ.get("USER", "")),
        "primitives": {},
    }
    for name, row in template["primitives"].items():
        copied = dict(row)
        copied["state"] = verified if row.get("state") == "verified" else row.get("state", "untested")
        draft["primitives"][name] = copied

    out = pathlib.Path(options.out)
    out.mkdir(parents=True, exist_ok=True)
    output_stem = f"Build{build}"
    (out / f"{output_stem}.json").write_text(json.dumps({build: draft}, indent=2) + "\n")

    def verdict(facility):
        names = FACILITIES[facility]
        states = [draft["primitives"].get(name, {}).get("state", "untested") for name in names]
        if not all_passed or "untested" in states:
            return "unvalidated"
        return "limited" if "limited" in states else "validated"

    ungrouped = sorted(set(draft["primitives"]) - {n for names in FACILITIES.values() for n in names})

    lines = [
        f"# Compatibility report, macOS {product} build {build}",
        "",
        "Generated by `make compat-report`, which runs the tiers and then assembles this",
        "from their logs. It writes nothing into the ledger: promotion is a human act,",
        f"`make promote-build BUILD={build}`, and it refuses a draft with an untested row.",
        "",
        "## Provenance",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| `kern.osversion` | {build} |",
        f"| `kern.osproductversion` | {product} |",
        f"| `hw.model` | {model} |",
        f"| `machdep.cpu.brand_string` | {sysctl('machdep.cpu.brand_string')} |",
        f"| `hw.ncpu` | {sysctl('hw.ncpu')} |",
        f"| `hw.memsize` | {sysctl('hw.memsize')} |",
        f"| load average when this was written | {sysctl('vm.loadavg')} |",
        f"| toolchain | {toolchain()} |",
        f"| date | {draft['validatedAt']} |",
        f"| by | {draft['validatedBy']} |",
        f"| template entry | {template_build} |",
        "",
        "## The steps of spec section 6",
        "",
        "| Step | What it proves | Oracle | Tier | Result |",
        "|---|---|---|---|---|",
    ]
    for name, what, oracle, tiers in STEPS:
        lines.append(
            f"| {name} | {what} | `{oracle}` | {', '.join(tiers)} | **{step_state[name]}** |"
        )

    lines += ["", "## Tests executed and skipped", "",
              "| Tier | Executed | Skipped | Reported | Verdict |",
              "|---|---|---|---|---|"]
    skip_lines = []
    for label in ("unit", "host-seat-cycle", "host-display-suites", "live"):
        result = tier_result(logs, label)
        counts = [result[key] if result else "unverified"
                  for key in ("executed", "skipped", "reported")]
        lines.append(f"| {label} | {counts[0]} | {counts[1]} | {counts[2]} | "
                     f"{tier_verdict(logs, label)} |")
        for detail in (result or {}).get("skip_details", []):
            skip_lines.append(f"- `{label}`: {detail}")
    lines += [""] + skip_lines

    lines += [
        "",
        "## Verdict per Facility, derived",
        "",
        "| Facility | Verdict |",
        "|---|---|",
    ]
    for facility in ("display", "input", "fence", "capture"):
        lines.append(f"| {facility} | **{verdict(facility)}** |")
    lines += [
        "",
        "The fence has no private primitive of its own: `CGEventTapCreate` is public, so its",
        "verdict is the effect step and nothing else.",
        "",
        "## Primitives on this build",
        "",
        "| Primitive | Kind | Image | State | Checks |",
        "|---|---|---|---|---|",
    ]
    for name, row in sorted(draft["primitives"].items()):
        checks = row.get("checks") or {}
        summary = ", ".join(
            f"{key} {value}" for key, value in checks.items() if key != "offsets"
        )
        if checks.get("offsets"):
            summary += ", offsets " + " ".join(
                f"{offset}{'(round trip)' if detail.get('roundTrip') else ''}"
                for offset, detail in checks["offsets"].items()
            )
        lines.append(
            f"| `{name}` | {row.get('kind','')} | {row.get('image') or '-'} | "
            f"{row.get('state','')} | {summary or '-'} |"
        )

    if ungrouped:
        lines += ["", "Rows that belong to no Facility, reported so the verdicts hide nothing: "
                  + ", ".join(f"`{name}`" for name in ungrouped) + "."]

    rows = matrix_rows(logs)
    lines += ["", "## The input matrix, Live tier", ""]
    lines += ["```"] + (rows or ["not run: AGENTSEAT_FIXTURE_APP was not set"]) + ["```"]

    bench = bench_rows(options.bench)
    lines += ["", "## Benchmarks and their budgets", ""]
    if bench:
        lines += [
            "`Budget met` is the driver's own verdict and it is the only column that",
            "decides anything: several budgets are checked against a value derived from",
            "these numbers, the attributable p95 of a send or the median of a CPU series,",
            "and the driver's log prints that value next to its limit.",
            "",
            "| Measurement | Unit | p50 | p95 | Budget | Status | Budget met |",
            "|---|---|---|---|---|---|---|",
        ]
        for name, unit, p50, p95, limit, status, met in bench:
            lines.append(f"| {name} | {unit} | {p50} | {p95} | {limit} | {status} | {met} |")
    else:
        lines.append("No benchmark JSON found under `" + options.bench + "`.")

    lines += ["", f"## Differences from the previous entry, {template_build}", ""]
    if build == template_build:
        lines.append("The template uses the same build. Primitive states above are derived from this")
        lines.append("run; copied per-primitive checks remain historical template data.")
    else:
        previous = set(template["primitives"])
        current = set(draft["primitives"])
        appeared = sorted(current - previous)
        vanished = sorted(previous - current)
        changed = sorted(
            name for name in current & previous
            if template["primitives"][name].get("checks") != draft["primitives"][name].get("checks")
        )
        lines.append(f"- appeared: {', '.join(appeared) or 'none'}")
        lines.append(f"- gone: {', '.join(vanished) or 'none'}")
        lines.append(f"- checks changed: {', '.join(changed) or 'none'}")

    lines += [
        "",
        "## What this report does not say",
        "",
        "It does not say the build is validated. That is the ledger's word, and it takes",
        f"`make promote-build BUILD={build}` after somebody has read the rows above.",
        "",
    ]

    (out / f"{output_stem}.md").write_text("\n".join(lines))
    print(f"compat-report: wrote {out}/{output_stem}.md and {out}/{output_stem}.json")
    print(f"compat-report: steps {step_state}, draft state {verified}")
    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
