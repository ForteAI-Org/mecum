#!/usr/bin/env python3
#
#  promote-build.py
#  AgentSeatKit
#
#  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
#
"""Copies one build's draft entry into the ledger the kit ships.

Promotion is the only thing that ever writes `validated-builds.json`, it is
always asked for by a person on a named build, and it refuses:

- a draft that does not exist, because the report has to have been generated;
- a draft with any row that is not `verified`, because a `untested` row means a
  step of the suite did not pass or did not run;
- a draft whose `productVersion` disagrees with the entry already there, since
  that is a different system wearing the same build string.

The same build on a second Mac adds its `hw.model` to the hardware list and
keeps everything else, which is exactly what the list is for.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]  # Tools/Driver/Scripts -> repository root
LEDGER = ROOT / "Sources/Driver/PrivateSymbols/Ledger/validated-builds.json"
DRAFTS = ROOT / "Documentation/Driver/compatibility"


def main(argv):
    if len(argv) != 2:
        print("usage: promote-build.py <build>, for example 26A5425a", file=sys.stderr)
        return 2
    build = argv[1]

    draft_path = DRAFTS / f"{build}.json"
    if not draft_path.exists():
        print(f"promote-build: no draft at {draft_path}.", file=sys.stderr)
        print("               Run `make compat-report` on the machine running that build.",
              file=sys.stderr)
        return 1

    draft_file = json.loads(draft_path.read_text())
    if build not in draft_file:
        print(f"promote-build: {draft_path} carries no entry for {build}.", file=sys.stderr)
        return 1
    draft = draft_file[build]

    unverified = sorted(
        name for name, row in draft["primitives"].items() if row.get("state") != "verified"
    )
    if unverified:
        print(f"promote-build: {build} has {len(unverified)} row(s) that are not verified, "
              "so it is not promotable:", file=sys.stderr)
        for name in unverified:
            print(f"               {name}: {draft['primitives'][name].get('state')}", file=sys.stderr)
        return 1

    ledger = json.loads(LEDGER.read_text())
    existing = ledger["builds"].get(build)

    if existing and existing["productVersion"] != draft["productVersion"]:
        print(f"promote-build: {build} is recorded as macOS {existing['productVersion']} and the "
              f"draft says {draft['productVersion']}.", file=sys.stderr)
        return 1

    hardware = sorted(set((existing or {}).get("hardware", []) + draft["hardware"]))
    ledger["builds"][build] = {
        "productVersion": draft["productVersion"],
        "hardware": hardware,
        "validatedAt": draft["validatedAt"],
        "validatedBy": draft["validatedBy"],
        "primitives": draft["primitives"],
    }
    LEDGER.write_text(json.dumps(ledger, indent=2) + "\n")

    was = "updated" if existing else "added"
    print(f"promote-build: {build} {was} in {LEDGER.relative_to(ROOT)}")
    print(f"               hardware {', '.join(hardware)}, "
          f"{len(draft['primitives'])} primitives, all verified")
    print(f"               by {draft['validatedBy']} at {draft['validatedAt']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
