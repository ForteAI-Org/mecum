# T13 qualification campaign, macOS 27.0 build 26A428

Written by hand from the tiers and the live runs of 20/09/2026, not by
`make compat-report`. It writes nothing into the ledger and proposes no
promotion: promotion is a human act, `make promote-build`, and the one row this
campaign could argue for is stated at the end as a proposal and left unapplied.

The audit baseline quoted in `MecumFixTasks.md` is **not** reproduced here as
validation. Every number below was measured in this campaign, and a proof that
was not run says so.

## Provenance

| Field | Value |
|---|---|
| `kern.osversion` | 26A428 |
| `kern.osproductversion` | 27.0 |
| `hw.model` | Mac16,1 |
| `machdep.cpu.brand_string` | Apple M4 |
| `hw.ncpu` | 10 |
| `hw.memsize` | 17179869184 |
| toolchain | Apple Swift 6.4 (swiftlang-6.4.0.30.4 clang-2100.3.30.1) |
| date | 2026-09-20T20:38Z |
| ledger entry for this build | **none**: the ledger describes 26A5425a only |
| working tree under test | 76 tracked files changed, 9247 insertions, 707 deletions, 31 untracked, 0 stashes, unchanged by this campaign |

### Applications and backends

| Target | Version | Backend | Used |
|---|---|---|---|
| AgentSeatFixture | rebuilt release from sources of 15/09/2026 | AppKit | yes, Live tier |
| Google Chrome | 153.0.8010.36 | Chromium | launched by the Live tier, every row blocked |
| Slack | 4.51.180 (451000180) | Electron | yes, three openings, no panel appeared |
| TextEdit | 1.21 | AppKit + out of process panel service | yes, four openings |
| Avid Link | 26.4.0.4668 | Qt | present and running, **not driven** |

### What was available, and what was blocked

- `AGENTSEAT_FIXTURE_APP` was unset, as it normally is. The consumer's package
  was found at `/Users/mac/Forte_Projects/AgentSeatFixture`, rebuilt with
  `swift build -c release`, and the variable pointed at
  `.build/release/AgentSeatFixture` for every Live invocation. The Live tier
  was therefore **not** blocked by the fixture.
- Screen Recording, Accessibility and Post Event all preflight `true` for this
  shell, so the Host tier was not refused.
- The physical display went to sleep during the first two Live attempts and
  every row failed with `.noPhysicalDisplays`, which is the condition the
  Makefile help warns about. A display assertion was held for the third
  attempt and released afterwards; only the third attempt is reported.
- **Stage Manager is on** (`com.apple.WindowManager GloballyEnabled = 1`,
  `AppWindowGroupingBehavior = 1`) and it stashed every third-party window into
  the strip for the whole campaign. This blocked more rows than anything else
  and is the first finding below.
- Vision text models do not load on this Mac, so no row uses OCR. Every oracle
  here is an accessibility value, a window server reading, or a reading taken
  by a separate process.

### The independent observer

Focus, cursor and modifiers were read by
`scratchpad/ws-observer.py`, a separate program that `dlopen`s SkyLight itself
and shares no code with the kit: `_SLPSGetFrontProcess` plus `GetProcessPID`
for the front process, `SLSGetWindowOwner` and `SLSGetWindowBounds` for a
surface, `CGEventSourceFlagsState(.hidSystemState)` for the person's own
modifiers, and `time.monotonic_ns` for every timestamp. Timings inside the
driver harness come from `DispatchTime.now().uptimeNanoseconds`. No percentile
stands in for a declared per-call maximum anywhere in this report.

## Targeted tests of the fixes

One invocation, `swift test --no-parallel` filtered to the suites the twelve
tickets added or rewrote. **189 tests in 18 suites, 0 failures.**

| Bundle | Suites | Tests | Result |
|---|---|---:|---|
| WindowPlacementTests | The unlisted window reading; The relocator's window element cache proves every hit; The owner connection memo | 20 | passed, 0.002 s |
| SeatSessionTests | The accessibility Window ID cache; Giving the assigned application back; Releasing a whole assignment; The capture source and the reading it is published with; Closure geometry effect; Closure transition; The dialog endpoint discovery; Routing a gesture to its endpoint; Routing keys to their endpoint; The nested modal stack; Operational geometry; Obligations of a held record; Window recovery plan | 138 | passed, 30.682 s |
| SeatCoreTests | Coordinating the containment of an assigned application | 28 | passed, 0.002 s |
| SeatCaptureTests | When a running capture should be reshaped, and to what | 3 | passed, 0.001 s |

Log: `scratchpad/targeted.log`.

## Suites

| Tier | Command | Result |
|---|---|---|
| unit | `make test` | **OK unit: 1203 executed, 52 skipped, 1255 reported in 11 run(s)**, 0 failures, exit 0. The three pre-check scripts ran 15, 64 and 4 tests, all `OK`, and the SeatBench contract reported `identity allocation assessment: 10 checks passed`. |
| Lab | `xcrun swift build` then `xcrun swift test --no-parallel --filter AgentEnvironmentKitTests` in `AgentEnviromentLab/Core` | build succeeded; **137 tests in 3 named suites passed in 0.095 s**, 0 failures |
| host, command 1 | `make host-tests` first half | **refused**: `FAIL host-seat-cycle: 0 executed, 0 skipped, 0 reported`, problems "no summary line, so completion is unproven" and "0 tests reported, 1 expected". The cycle's own line did print: `seat cycle: removal 477 ms, topology notNeeded, 0 events`. |
| host, command 1, retried alone | `AGENTSEAT_HOST_TESTS=1 run-tier.sh host-seat-cycle 1 swift test --filter theSeatCycle` | **OK: 1 executed, 1 reported**, `removal 110 ms` |
| host, command 2 | `AGENTSEAT_HOST_TESTS=1 run-tier.sh host-display-suites 29 swift test --filter HostTests --skip theSeatCycle` | **OK: 29 executed, 0 skipped, 29 reported** |
| live | `AGENTSEAT_FIXTURE_APP=… make live-tests` | **FAIL live: 72 executed, 10 skipped, 82 reported in 1 run(s)** |

The host tier's first refusal is the defect its own Makefile header and
`Documentation/Driver/SpiLedger.md` describe: a live HID fence across repeated
virtual display creation ends the process with exit status 0 and no summary.
The tier assertion caught it, which is what it is for. It is **not** a pass and
it is not attributable to T01–T12; the retry in its own invocation passed.

Logs: `scratchpad/make-test.log`, `scratchpad/lab-core-tests.log`,
`scratchpad/host-tests.log`, `scratchpad/host-rest.log`,
`scratchpad/host-cycle-retry.log`, `scratchpad/live-tests3.log`.

### The Live tier's three problems

1. `82 tests reported, 25 expected`. `LIVE_TESTS := 25` in the Makefile is
   stale and none of T01–T12 touched it: the Live bundle now also holds the
   pure unit suites of the window inventory probe (`ProbeCleanupSweepTests`,
   `WindowInventoryProbeGateTests`, `WindowInventoryProbeReportTests`,
   `WindowInventoryProbeRunTests`, `WindowInventoryRowParserTests`), which the
   committed ticket 0379aca added. The tier can therefore never report `OK`.
2. Seven tests failed, listed under **Defects** below.
3. Ten tests were skipped, all behind their own opt-in switches:
   `AGENTSEAT_FULLSCREEN_PROBE` (2), `AGENTSEAT_MANUAL_TESTS` (2),
   `AGENTSEAT_FOLLOW_APP` (1), `AGENTSEAT_STASHED_ADOPTION` (1),
   `AGENTSEAT_TEXT_DELIVERY` (2), `AGENTSEAT_TYPING_SWEEP` (1),
   `AGENTSEAT_WINDOW_INVENTORY_PROBE` (1).

### The Live input matrix

`fence: 0 HID events observed, 0 clamped, 0 disables`. The cursor reading was
identical before, during and after **every** fixture row
(`624.5703125, 981.98046875`), and the front process stayed `Claude` throughout:
no physical cursor was moved and no application was activated.

| Target | Action | Effect | Seat | Verdict |
|---|---|---|---|---|
| AppKit fixture | keyboard | keys 0 → 1 | OK | PASS |
| AppKit fixture | insertText | field 46 → 118 | OK | PASS |
| AppKit fixture | wordRight | shortcutEffects 0 → 1 | OK | PASS |
| AppKit fixture | cancel | shortcutEffects 1 → 2 | OK | PASS |
| AppKit fixture | click | clicks 0 → 1 | OK | PASS |
| AppKit fixture | scroll | wheel 0 → 60 | OK | PASS |
| AppKit fixture | drag | drag 0 → 219.4 | OK | PASS |
| AppKit fixture | copy, paste, selectAll, undo, redo | shortcutEffects 0 → 0 | OK | FAIL, the documented ADR 0011 rows |
| AppKit fixture | save | visible windows 1 → 1 | OK | FAIL |
| Chrome page | all thirteen | not sent | OK | FAIL, `suspended([noEligibleTarget])` |

Twelve of the matrix's issues are recorded as known issues; the remainder are
the Chromium rows and `save`.

## The live campaign

Everything below was driven by a harness written for this campaign at
`/Users/mac/Forte_Projects/mecum/.scratch/t13-live` (gitignored, outside both
source trees). It brings up the kit's own `SeatHost` and `AgentSeat`, sends
every command through `AgentSeat.send`, and judges each one with accessibility
and the window server. No message was sent, no file was uploaded, no dialog was
confirmed: the only closures attempted were Cancel and Escape, and the only
text was `mecum` typed into a file panel's own search field.

### Slack, two runs of three independent openings

Logs: `scratchpad/slack-campaign2.log` (the host driven with the AppKit recipe)
and `scratchpad/slack-campaign3.log` (with the Chromium recipe, which is the
right family for an Electron host).

| Field | AppKit run | Chromium run |
|---|---|---|
| Target | Slack 4.51.180, pid 2954, window 49790 | same |
| Window as the window server reported it | 106 × 127 pt at 16,780, a Stage Manager strip thumbnail | same |
| Window as accessibility reported it | 668 × 400 pt at 15,582 | same |
| Adoption | `expectedEffectVerified` ×3, 217–229 ms | `expectedEffectVerified` ×3, 220–247 ms |
| Window server frame after staging | `(2458, 1502, 668, 400)` | `(2458, 1502, 668, 400)` |
| `⌘O` | `posted` ×3, receipt returned, 0 events window-routed to window 49790 connection 5238867 (keys carry no window route), 422–662 ms | `posted` ×3: opening 1 routed as above in 557 ms; openings 2 and 3 **never reached the driver**, see below |
| Panel | **none** in any of the six openings | **none** |
| Detection wait | timed out at 4.0 s each time | timed out at 4.0 s each time |
| Front process before and after, independent reading | `Claude[85451]` both times, every opening | same |
| Cursor before and after | `624,982` → `624,982`, unchanged | unchanged |
| Modifiers | none before, none after | none |
| Seat state | `ready` throughout, no input pause reasons | `ready` as the seat reported it, while the observation was refused |
| Release | `returned` every opening | `returned` every opening |

In the Chromium run the second and third `⌘O` returned in 1.7 ms and 5.1 ms
because the observation was refused before anything was sent:

```
observation refused: suspended([containmentNotVerified(blocks: [
  "surfaceAbsent(windowNumber: 51425)",
  "surfaceDeadlineExpired(windowNumber: 51425, elapsedNanoseconds: 272761500)"])])

observation refused: suspended([containmentNotVerified(blocks: [
  "surfaceAbsent(windowNumber: 51425)",
  "surfaceDeadlineExpired(windowNumber: 51425, elapsedNanoseconds: 6336230375)",
  "handoverDeadlineExpired(elapsedNanoseconds: 7002108167)"])])
```

A Slack surface numbered 51425 appeared during the first opening, went absent,
and blocked containment for the rest of the session. It did not happen in the
AppKit run. This is finding 6.

The `openAndSavePanelService` windows present on the machine were four stale
ones belonging to other processes, none of them Slack's.

**This does not reproduce the 19/09 evidence and it does not refute it.** The
Slack window available during this campaign is a 668 × 400 conversation window,
not the workspace window the research drove, and in this window `⌘O` opened
nothing at all. Both the Chromium recipe and the AppKit recipe were tried. The
row is *not run*, not *failed*: no Electron remote panel existed to drive.

### TextEdit and its out of process panel, four openings

Logs: `scratchpad/textedit-campaign.log` (three openings, the second hung, see
below) and `scratchpad/textedit-route.log` (one opening with the route
recorded). TextEdit was launched by this campaign and quit at the end.

The panel here is a standalone `AXWindow/AXStandardWindow` titled "Open", not a
sheet, because TextEdit had no document behind it. Its content is still served
out of process, which is what T01 is about.

#### What was verified

| Reading | Value |
|---|---|
| Host panel window | 51436, owner connection **5402747**, in the public list |
| Content window, reached through the AX subtree | 51437 |
| `AXUIElementGetPid` on the content node | **62978, the host's own pid** |
| `SLSGetWindowOwner(51437)`, read by the separate process | rc 0, owner **595363** |
| `SLSGetWindowBounds(51437)`, read by the separate process | rc 0, frame `(310, 159, 891, 448)` |
| `WindowServerProbe.geometry(of: 51437)` (the ordinary reader) | **refused** |
| `RemoteWindowProbe.observation(of: 51437, containedIn: (2346,1478,891,448))` | **frame `(2346, 1478, 891, 448)`, scale 1.0** |
| `CGWindowListCopyWindowInfo(.optionAll)` contains 51437 | **true** |

T01's central claim is therefore **verified live on this build**: the
accessibility PID is the host's while the window server's owner connection is
the service's, and the geometry of that window is readable only through the new
reader. One detail differs from the 19/09 note: with `.optionAll` the content
window **is** enumerated on this build in this topology, so "absent from the CG
list" is a property of the reading options and the topology, not a constant.

#### The proof rows

Every row: front process `Claude[85451]` before and after, no modifiers, seat
`ready`, no input pause reasons.

| Proof | Outcome | Oracle | Route the receipt recorded |
|---|---|---|---|
| adopt the stashed panel | `expectedEffectVerified`, 229 ms | window server frame `(2346,1478,891,448)`, full size on the virtual display | — |
| remote endpoint | `expectedEffectVerified` | the table above | — |
| Cancel click | **`posted`** | the panel was still there after 4.07 s; `SLSGetWindowOwner(51437)` still rc 0 owner 595363 | 2 events, **2 routed to window 51436 connection 5402747**, poster `publicProcess`, preparation **`none`**, settle **0 ms** |
| type `mecum` into the search field | **`posted`** | AX value `""` → `""` after 2.00 s | 10 events, 0 routed, preparation `none`, settle 0 ms |
| `⌘A` in the field | **`posted`** | AX selected text `""` → `""` | 2 events, preparation `none`, settle 0 ms |
| Backspace | reported `expectedEffectVerified` — **vacuous**, the field was already empty and the predicate held at 0.12 ms | — | 2 events, preparation `none` |
| Tab | **`posted`** | focused element unchanged: `AXList/AXCollectionList "icon view" w51437` before and after | 2 events, preparation `none` |
| Shift-Tab | **`posted`** | focused element unchanged | 2 events, preparation `none` |
| Arrow down | **`posted`** | selection unchanged | 2 events, preparation `none` |
| `⌘⇧G` | **`posted`** | no nested dialog appeared after 4.14 s; AX window set `[51436]` → `[51436]` | 2 events, preparation `none` |
| Escape on the panel | **`posted`** | panel still present after 4.07 s | 2 events, preparation `none` |
| host after the closure | `expectedEffectVerified` | host window 51436 still attested | — |

Cursor readings were `1159,555` before and after every keyboard row. The Cancel
row read `1186,629` before and `900,612` after; that is two samples around a
580 ms call and not a continuous watch, so it is recorded as an unexplained
reading and not as a cursor the driver moved. Nothing else in the campaign
showed any cursor movement at all.

#### What the route says

Every command, the Cancel click included, was posted to **window 51436 on
connection 5402747**, which is the panel's host window, with preparation `none`
and settle 0 ms. The remote endpoint the kit had just attested, window 51437 on
connection 595363, received nothing, and `RemoteKeyboardPlatform`'s activation
record, key-window pair and 50 ms settle were never applied.

**Attribution matters here and the campaign cannot settle it.** This harness
adopted the **panel window itself** as the seat's target, because that was the
only window TextEdit had. In that topology there is no attested
host → sheet → content relation for `DialogEndpointResolver` to work from, and
routing to the adopted window may be exactly right. The ticket's topology — an
assigned host window with the panel as its sheet — did not occur even once
during this campaign, on either application. So the endpoint routing of T03 and
the keyboard recipe of T04 are **not qualified live, in either direction**.

### Capture coherence

The geometry half is verified: the Cancel button's accessibility centre,
`3050,1881`, was accepted by `InputLocation(screenPoint:observedIn:)` against
the window geometry observation taken from the adopted window in the same pass,
and `RemoteWindowProbe` answered the same rectangle for the content window as
the observation carried for the host surface, scale 1.0, with no padding
anywhere in the transform.

The pixel and landmark half of T06's acceptance — the same control compared
through the still planner, through the preview, and against the corresponding
region of a whole-display capture — was **not run**.

## Teardown

| Check | Result |
|---|---|
| virtual display left online | none. `CGGetOnlineDisplayList` reports one display, id 1, vendor 1552, bounds `(0,0,1512,982)` |
| main display | restored, `CGMainDisplayID() == 1` |
| fence | released; every harness run reported `fence released true`, and the Live tier reported `0 HID events observed, 0 clamped, 0 disables` |
| topology | `notNeeded` on every run: the display set never changed |
| windows owed back | Slack window 49790 is back on the physical display in the Stage Manager strip at `15,764`; the seat reported `returned` for every release |
| applications | TextEdit was launched by this campaign and quit; no document was created or saved; no browser and no fixture process was left running |
| files | the three `/tmp/agentseat-fixture-501-*.json.writing` partials these runs left were removed |
| display assertion | the `caffeinate` assertion held for the Live tier was released |
| repository | unchanged: 76 tracked files, 9247 insertions, 707 deletions, 31 untracked, 0 stashes, no commit, no stage, no stash, no checkout |

One obligation to describe precisely: the second opening of the TextEdit run
hung inside the harness after a successful adoption and was ended with SIGINT.
The process exit removed its virtual display — a later reading confirmed one
display online — but it left the panel window at `(2346, 1478)`, coordinates
belonging to the display that had just gone. The window came back to the
physical display by itself and the following run adopted and returned it
normally, and quitting TextEdit closed it. **Nothing is outstanding**, but the
window was briefly off the visible desktop and that is worth knowing: a harness
that dies mid-adoption does not owe a window back through any code path.

## Per ticket

`verified live` means an oracle outside the driver saw the effect in this
campaign. `code and tests` means the path and its unit coverage were exercised
and passed here, with no live oracle. `to qualify` means neither.

### T01 — remote endpoint discovery and attestation

- **Verified live**: AX pid equal to the host while the owner connection is the
  service's; the ordinary probe refusing the content window while
  `RemoteWindowProbe` attests its frame and scale. Evidence:
  `scratchpad/textedit-route.log`, row `remote endpoint`.
- **Code and tests**: reused Window ID, replaced helper, two panels of one
  service, incomplete AX subtree, and the refusal to let an incoherent
  window/connection/PID triple reach a post — `DialogEndpointResolverTests`,
  `RemoteWindowProbeTests`, `GestureEndpointRoutingTests` (20 + 138 tests,
  passed here).
- **To qualify**: the 19/09 claim that the content window is absent from the CG
  list. With `.optionAll` on this build, in the standalone-panel topology, it is
  present. The absent case was not reproduced.

### T02 — nested modal stack and reconciliation during a pause

- **Verified live**: nothing. `⌘⇧G` produced no nested dialog on either
  application, so neither the child nor the parent transition was observed.
- **Measured negative**: the ticket's own problem statement reappeared in a live
  session. A Slack surface, window 51425, went absent and left the seat unable
  to observe anything for the rest of the run, with `surfaceAbsent` and both
  deadlines expired, while the seat still read `ready`. Finding 5. The third
  acceptance item — "a window that really disappeared must leave every register
  and block neither the recovery nor the release" — is therefore **not**
  satisfied for this surface, though the surface's provenance is unknown and it
  may be a case the relation was never attested for.
- **Code and tests**: all four acceptance items — `NestedModalStackTests`,
  `CrossCheckedSurfaceReaderTests`, the `destroyed` / `withdrawn` /
  `obscuredByChild` / `temporarilyUnreadable` / `unrelated` separation.
- **To qualify**: the whole acceptance sequence, Open → Go to folder → Escape →
  Escape; and the live behaviour above.

### T03 — mouse routing and per-surface classification

- **Verified live**: no physical cursor movement and no event to a foreign
  process — the Live matrix's fence snapshot and identical cursor readings on
  thirteen fixture rows; click, scroll and drag each landing on the fixture's
  own control with its own counter as the oracle.
- **Code and tests**: the endpoint resolution, the drag that never changes
  process mid-gesture, the click outside a modal sheet that is not forwarded —
  `GestureEndpointRoutingTests`.
- **To qualify**: "Cancel really closes three fresh panels". One fresh panel was
  driven four times and Cancel closed none of them; the click was routed to the
  host window, not the attested remote endpoint, in a topology where that may be
  correct. This is the campaign's largest open question.

### T04 — keys, text and shortcuts

Of the eight mandatory proofs in the ticket's table, **none is verified live**.

| Mandatory proof | Result here |
|---|---|
| click the search field, then short text | `posted`, AX value unchanged |
| Tab / Shift-Tab | `posted`, focused element unchanged in both directions |
| arrows / Backspace | `posted`; the Backspace row's pass is vacuous |
| `⌘A` in the field | `posted`, selection unchanged |
| `⌘⇧G` | `posted`, no Go to folder surface |
| Escape on the nested dialog | not reached, there was no nested dialog |
| Escape on the panel | `posted`, panel still present |
| a shortcut that creates or closes a window | not run |

What the fixture rows do show is that the keyboard path itself works on this
build against an ordinary AppKit window: `keyboard` and `insertText` both PASS
with the target's own counters as the oracle. The failures above are specific to
a remote panel's content, and the route shows why: preparation `none`, settle
0 ms, events to the host window. Whether the qualified recipe would have been
selected in the ticket's own topology is untested.

- **Code and tests**: the recipe's shape, the 50 ms settle as a per-recipe
  property, the ambiguity refusals, the empty Unicode payload of a shortcut, and
  the `KeyHold` ledger — `KeyboardEndpointRoutingTests`, `InputPlatformTests`.

### T05 — fast focus recovery and completing the closure

- **Verified live**: nothing was stolen, so nothing was recovered. Every row of
  every run read the same front process before and after, independently. That
  is the "closure with the focus unchanged" half of the first acceptance item,
  but it is trivially satisfied when no closure happened.
- **Code and tests**: the whole acceptance list — closure transition, two
  requests, derived deadline, duplicate versus distinct activation, expired
  preparation, `preparationAttempts` separated from `restoreRequests`,
  reconciliation before validating the new set, the bounded renewal that never
  learns a new destination, the one-time impossibility, panic closing the gate
  first — `ClosureTransitionTests`, `UserFocusRecoveryTests`,
  `FocusRecoverySnapshotTests`, all passed here.
- **To qualify**: the three budgets the ticket says stay "to qualify" — 8 ms per
  call, 250 ms verification, 1 s preparation lifetime. The only Live row that
  measures them, `UserFocusRecoveryLiveTests.printRestoresUserFocus`, needs
  Chrome and did not run: it failed on the sleeping display in two attempts and
  was not reached in the third. **The 11 ms of the audit is still not a pass and
  no new measurement replaces it.**

### T06 — coherent capture

- **Verified live**: the geometry transform, as described under *Capture
  coherence*.
- **Code and tests**: source, buffer size, `contentRect`, scale and generation
  resolved together; the full-display capture proven never to be an observation
  — `CaptureSourceCoherenceTests`.
- **To qualify**: the pixel and landmark comparison, still planner and preview,
  against the corresponding region of a whole-display capture. Not run.

### T07 — preserving the record's obligations

- **Code and tests**: both acceptance items, `RecordObligationTests`, passed.
- **Verified live**: nothing, and nothing needs it: the ticket is about a value
  surviving a rebuild, which a unit test is the right oracle for.

### T08 — resize, adaptation and Stage Manager

- **Verified live, and this campaign is the first to do it**: a window Stage
  Manager had stashed to a 106 × 127 pt strip thumbnail was adopted from its
  accessibility frame and came up full size, 668 × 400, on the virtual display,
  three times on Slack and four times on TextEdit, with the front process
  unchanged. That is the ticket's "vera thumbnail Stage Manager" case and the
  `AXRaiseAction.stagesWithoutActivating` primitive behind it.
- **Measured negative, by this campaign's own first attempt**: adopting the same
  window from the **window server's** thumbnail frame fails with
  `placementNotConfirmed(windowNumber: 49790, lastFrame: (2724, 1608, 1298, 949))`
  — the move un-stashes the window and the confirmation is still holding the
  thumbnail size. The kit's own `StashedAdoptionLiveTests` says the supported
  input is the accessibility reference, so this is a caller contract and not a
  defect; it is recorded because it is easy to get wrong and the refusal names
  neither Stage Manager nor the right reference.
- **Code and tests**: `operationalSize` kept apart from the frame owed back,
  generation bump, oversized adaptation, the app that refuses the smaller size,
  and the closure geometry classification — `OperationalGeometryTests`,
  `WindowRecoveryPlanTests`, `ClosureGeometryEffectTests`.
- **To qualify**: scale change; and the `48084` auxiliary reconciliation of the
  ticket's "ulteriore caso live", which needs a closure that actually happens.

### T09 — releasing a whole assignment

- **Verified live**: every release in every run reported `returned`, and the
  target window was back on the physical display afterwards, Slack's included.
  No ghost residue and no obligation was reported.
- **Code and tests**: the whole acceptance list including double teardown and
  the half-failed adoption — `AssignmentReleaseTests`,
  `AssignedApplicationHandbackTests`, and the Lab's `SeatReleaseSetTests`.
- **To qualify**: "Slack with a panel and transient overlays → close → a second
  application without recreating the host". No panel ever existed on an assigned
  host, and no second application was assigned in the same session.

### T10 — monotone budgets and per-surface pauses

- **Code and tests**: all four acceptance items — `ContainmentCoordinatorTests`
  (28 tests, including the ten second outage before a dialog's birth and the
  outage during its life), `WindowRecoveryPlanTests`.
- **Verified live**: the serialized unit tier ran clean, 1203 executed with zero
  failures, where the audit baseline had one test with four failed expectations.
  `destroyedTargetHandsOver` passed inside the full tier.
- **To qualify**: nothing that needs a live oracle.

### T11 — recoverable preview

- **Code and tests**: all four acceptance items, Lab-side
  `PreviewStreamControllerTests` plus the kit's `CaptureShapeStabilisationTests`
  (3 tests), all passed here.
- **Verified live**: nothing. The preview was not exercised by this harness.
- **To qualify**: a transient preview failure and a one-pixel oscillation
  against a real stream.

### T12 — verified effect and true state in the Lab

- **Code and tests**: the full acceptance list, `OutcomeVerificationTests`,
  `SeatActivityTests`, `FocusRecoveryWaitTests`, inside the Lab's 137 passing
  tests.
- **Verified live**: indirectly and importantly. Every ineffective command in
  this campaign came back `posted` and not `sceneChanged` or verified, because
  the oracle was an accessibility value or a window identity and not a pixel
  difference. A verifier that trusted the scene would have called the Cancel
  click a success: the panel's contents repaint constantly. No command was ever
  repeated after an uncertain effect.
- **To qualify**: the Lab's own UI showing `recovering` / `waitingForUser` /
  `suspended` / `ready`, which needs the application and was not run;
  `runs.jsonl` was not written, because the recorder only writes from
  `AgentSession.run(goal:model:)` and this campaign drove the kit directly.

## Defects and findings

### 1. Stage Manager stashes every target, and the Chromium half of the Live tier dies on it

**Evidence.** `com.apple.WindowManager GloballyEnabled = 1`. At rest, every
third-party window on this Mac is a strip thumbnail: Slack 136 × 189 at 15,747,
ChatGPT 141 × 186 at 15,79, GitHub Desktop 136 × 163 at 15,263, kitty
136 × 155 at 15,447, each paired with a WindowManager "Gesture Blocking Overlay"
at the same rectangle. The Live tier's own freshly launched browser came up the
same way: `chrome window 50369 … frame (18.0, 576.0, 129.0, 161.0)`, three
separate runs, each with a fresh `--user-data-dir`. Every Chrome row then failed
with `suspended([noEligibleTarget])`, which is `TargetSelectionCore` finding no
eligible candidate, and the suites that discover the probe page by size failed
with "the probe page never appeared among the windows of the browser this suite
launched".

**Scope.** Not T01–T12. It is an environment condition, and the kit refusing a
thumbnail as a target is correct. But the ledger's own note records that on
09/09/2026, with the same two defaults set, *nothing* was stashed during the
Live matrix; today everything is. Something changed, and until the cause is
known no Chromium row on this machine means anything.

**What it costs.** The whole Chromium family of the Live matrix, the context
menu row, the multi-window row, the new-window row, the key isolation row, and
`UserFocusRecoveryLiveTests`, which is the only measurement of the T05 budgets.

### 2. No command reached a remote panel's content

**Evidence.** `scratchpad/textedit-route.log`. Cancel, text, `⌘A`, Backspace,
Tab, Shift-Tab, arrow, `⌘⇧G` and Escape all posted to window 51436 on
connection 5402747 with preparation `none` and settle 0 ms, while the attested
content endpoint was window 51437 on connection 595363. No oracle moved.

**Scope.** T03 owns the gesture endpoint, T04 the keyboard context. **The
attribution is not established**: the adopted target was the panel window
itself, not a host carrying it as a sheet, so the resolver may have had no
relation to work from. Reproducing the ticket's topology is the next step, and
it needs an application that presents a file panel as a sheet of a window the
seat has adopted.

### 3. `LIVE_TESTS := 25` is stale, so the Live tier cannot pass

**Evidence.** `82 tests reported, 25 expected`. `git diff Makefile` shows the
tickets did not touch the constant; the Live bundle gained five pure unit suites
in commit 0379aca.

**Scope.** The Makefile. One line. It was **not** changed here: the brief limits
edits to one-line fixes in files a previous ticket touched, and no ticket
touched this constant, so it is reported rather than applied.

### 4. Four Live failures that are probably Stage Manager and are not proven to be

| Test | Error |
|---|---|
| `KeyIsolationLiveTests` | `.keysStillHeld(count: 1)` |
| `MultiWindowLiveTests` | `SeatInterruption(issues: [geometryChanged])` |
| `NewWindowLiveTests` | `coordinateIdentityChanged(expected … windowNumber: 50670 …, observed … windowNumber: 50612 …)` |
| `ContextMenuLiveTests` | `Expectation failed: effectArrived` |

A strip re-layout changes a window's geometry and swaps which window a
coordinate lands in, which is exactly what the middle two report. `keysStillHeld`
is the one that would matter on its own, because T04 owns the `KeyHold` ledger.
None of the four can be attributed until the tier is re-run without windows
being stashed underneath it.

### 5. A transient Slack surface blocked containment for the rest of the session

**Evidence.** `scratchpad/slack-campaign3.log`, openings 2 and 3:
`surfaceAbsent(windowNumber: 51425)` with `surfaceDeadlineExpired` at 272 ms
and then at 6.34 s, and `handoverDeadlineExpired` at 7.00 s. Window 51425 was
never a window this campaign asked for; it appeared while the seat was
following new windows and then went absent. Every later observation was refused
and no command could be addressed, while `AgentSeat.state` still read `ready`.
It did not reproduce in the AppKit run of the same three openings, so the
Chromium preparation applied to the Electron host is the difference to look at
first.

**Scope.** T02 owns exactly this shape — the ticket's own problem statement is
an inventory refusing a surface with `surfaceAbsent` and expired deadlines — and
T10 owns the deadlines. The unit suites cover the classification and the
budgets; this is the same family surviving into a live session, on a surface
that really did disappear rather than one merely missing from the AX list. It
needs the surface's provenance before it can be called a defect: a window that
genuinely went away should leave every register, which is T02's third acceptance
item.

### 6. The host tier's first command is still flaky

One refusal, one clean retry, in this campaign. Already documented in
`SpiLedger.md`; recorded here because the run happened.

### Nothing was implemented

No defect found was a one-line, clearly-scoped fix in a file a previous ticket
touched, so no source file was changed. The kit and the Lab are exactly as the
campaign found them.

## The proposed ledger row for `SLSGetWindowBounds`

The evidence supports the row. It is written here and **not applied**: this
build has no ledger entry at all, and adding a primitive to a build the ledger
does not describe is a larger decision than one row.

```json
"SLSGetWindowBounds": {
  "kind"  : "symbol",
  "image" : "SkyLight",
  "state" : "verified",
  "checks": {
    "resolves": true,
    "effect"  : "T13 on 26A428: on the content window of an out of process Open panel, window 51437 owned by connection 595363 while the host panel window 51436 was owned by connection 5402747 and AXUIElementGetPid answered the host's pid 62978, the call returned 0 and the frame (310, 159, 891, 448). WindowServerProbe.geometry refused the same window. RemoteWindowProbe.observation answered (2346, 1478, 891, 448) at scale 1.0 for it once the surface was staged, matching the container exactly. Cross read by a separate process that dlopens SkyLight itself and shares no code with the kit."
  },
  "notes": "Read only and scoped to one Window ID. It is the one primitive of Facility.remoteWindowGeometry that windowIdentity does not already carry, which is why that Facility is separate and opt in."
}
```

Two things the row deliberately does not claim. It does not claim the window is
absent from the public list: with `.optionAll` on this build it was present, and
the 19/09 absence was measured in a different topology. And it does not carry a
build entry: **26A428 itself is not in the ledger**, the Lab and every run here
went through `FacilityGate.researchOptInForUnvalidatedBuilds`, and promoting a
primitive into a build that does not exist in the ledger is not a thing this
report proposes.

## What the user has to decide

1. **Stage Manager.** Nothing in the live tier can be trusted while every target
   is a thumbnail. Turning it off is a change to the desktop and was not made.
   Decide whether to re-run the Live tier with it off, or to teach the suites to
   stage a stashed target before discovery.
2. **The topology for T03 and T04.** The ticket's proofs need a file panel
   presented as a sheet of a window the seat has adopted. Slack did not produce
   one from `⌘O` in the window that was available, and TextEdit had no document
   window. Decide which application and which document state the qualification
   run should use, or whether the fixture should grow an `NSOpenPanel` of its own
   — which would make the whole T04 table reproducible without a third party.
3. **`LIVE_TESTS`.** Update the constant, or split the probe's unit suites out of
   the Live bundle. Until then `make live-tests` cannot report `OK`.
4. **The T05 budgets.** 8 ms per call, 250 ms verification, 1 s preparation
   lifetime are all still unmeasured on this build. They need
   `UserFocusRecoveryLiveTests` or `make focus-latency`, and both need a Chrome
   window that is not stashed.
5. **Window 51425.** Whether the surface that blocked containment for two whole
   openings is a case T02 should already handle, or one whose relation the seat
   never attested. It is the only finding here that reproduces the exact shape
   of a ticket's own problem statement, and it needs the surface identified
   before it can be scoped.
6. **The ledger.** Whether to open an entry for 26A428 at all, and only then
   whether `SLSGetWindowBounds` joins it.
