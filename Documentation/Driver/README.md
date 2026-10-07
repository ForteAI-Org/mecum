# AgentSeatKit

A macOS library that drives a **seat**: a virtual display, one or more target
windows moved onto it, background input delivered to those windows, an HID fence
that keeps the person's cursor out, and capture of what the seat shows. It knows
nothing about who decides: the consumer observes, chooses, and hands the kit
coordinates.

The point of the kit is what it refuses to do. It never posts a global event, it
never falls back onto the person's desktop, it never repeats an action whose
effect it could not confirm, and on a macOS build it has not been validated
against it declines to act rather than guessing.

## Shape

| Module | What it owns |
|---|---|
| `SeatCore` | pure types and contracts: window references, commands, receipts, guard and recovery policy, frame math |
| `PrivateSymbols` | build identity, the private symbol table, record layouts, the compatibility ledger, TCC preflight |
| `VirtualScreens` | the virtual display's own life and the physical topology it attaches to |
| `WindowPlacement` | where a window is, where it sits in the front to back order, and how it is moved and staged |
| `SeatInput` | event construction and delivery to one window, per-platform preparation |
| `CursorGuard` | the HID event tap that confines the physical cursor |
| `SeatCapture` | the display monitor, per-window frames and stills |
| `SeatSession` | `SeatHost` and `AgentSeat`: lifecycle, turns, watchdog, recovery |
| `TargetReader` | reads another application's accessibility tree and returns value types; it never acts, no facility depends on it, and what a reading means is the caller's |

`SeatCapture` and `SeatSession` also depend on `PhaseSignposts`, a leaf module outside the
Driver that is empty unless the measurement condition is set; see
[Measuring the phases](#measuring-the-phases).

The [Chromium qualification guide](platforms/Chromium.md) records the app's renderer
readiness, bounded native composition and eight owned-browser rows in
`make chromium-live-tests`, including known menu-equivalent effect failures.

The [Qt driver guide](platforms/Qt.md) records the command policy and the live
qualification of DaVinci Resolve's Project Manager, including the commands
whose target-side effect still needs a witness.

The [Mecum application flow checks](reports/ApplicationFlowChecks.md) record effects,
failures and corrections from the full app path across AppKit, UXP, Qt,
Chromium, Electron and an unqualified hybrid CEF candidate.

There is no umbrella module: every consumer writes the imports it uses, so the
boundaries are visible at the top of the file rather than hidden behind one
name. Link the `MecumDriver` library product to use these modules, including
`TargetReader`. A local consumer adds `.package(path: "../mecum")` to its
package dependencies and `.product(name: "MecumDriver", package: "mecum")` to
the targets that use the driver. Adjust the relative path to the checkout;
sources and the resource ledger are compiled directly from Mecum.

## Using it

```swift
let host = SeatHost(configuration: .default)
try await host.start()                                  // virtual display + fence, atomic

let seat = try host.makeSeat()
let turn = try await seat.acquire()                     // exclusive between safe points
let window = try await seat.adopt(reference, platform: .universal)

// A Command is addressed by the observation it was decided on, never by a
// window. `observe()` answers the Frame and the reference that binds it, or an
// unavailability with its reason; it never answers older pixels.
switch await seat.observe() {
    case .failure(let reason):
        // Waiting, a cause of the gate, or a native ability with no evidence.
        print("nothing to act on: \(reason)")
    case .success(let delivery):
        // The consumer decides on `delivery.frame`, asynchronously if it likes,
        // and hands the same reference back with the Command.
        let receipt = try await seat.send(
            .click(location),
            observation: delivery.reference,
            turn       : turn
        )
        // the consumer verifies the effect however it likes, then says so:
        try seat.confirm(receipt, .observed)
}

try await seat.release(window, .returnToUserSeat)
try seat.release(turn)
await host.stop()
```

A complete Command consumes its observation: the next one needs a new
`observe()`, and so does every invalidation. Sequences and multi-chunk text are
the consumer's to orchestrate — `AgentSeat.textCommands(of:mode:limits:)` cuts a
string and sends nothing — while a single `insertText` stays one atomic Command.
A contextual menu is a scoped asynchronous interaction:
`withContextMenu(openedAt:observation:turn:appearingWithin:body:)` hands the body
a `SeatMenuInteraction` that is revoked the moment the interaction ends, and the
kit closes the menu on every path out.

`SeatHost.events` and `AgentSeat.events` carry state transitions, issues and
recovery progress, and `AgentSeat.coherentState` plus `subscribeToState()` carry
one versioned reading of the selected and operational target, the causes of the
gate, the observation, the Monitor's own health and any restitution still owed.
Reading that state is not authority: the reference and the gate are verified
again where input is admitted. Every action returns an observation of the User
Seat so the consumer can tell a person's own activity from an anomaly; the kit
reports, it does not attribute. That diagnostic is not the Observation Reference
and the two are never interchanged.

Assignment release accepts a hidden window's `returnsWhenShown` outcome only
after `HiddenWindowReturns` takes its original destination and identity. That
shared ledger outlives the assignment and restores the window when it is shown;
the release does not claim a physical return or a destroyed window. Without a
deferred-return ledger, the window return is refused. Ordered-out held members leave the
assignment inventory with explicit WindowServer ordering-out evidence, while
their deferred restoration remains owed by the shared ledger.

### What the code cutover is, and what it is not

The public contract above is implemented and the internal callers are migrated.
The offline suites prove the joins and refusal rules; they do not replace the
final native Live matrix.

The content clock and the ordinary application-window inventory now have
production adapters. The inventory is accepted only when `AXWindows` and an
identity-attested WindowServer reading of the requested IDs agree on every AX-scoped
application window. Additional same-process WindowServer surfaces remain outside
that positive scope; a missing AX counterpart still leaves containment
unverified. The final cross-application Live matrix is intentionally deferred to
the Lab delivery pass.

| Capability | State | What it stops |
|---|---|---|
| `contentClock` | qualified in `SeatHost` | frame age is measured from `SCStreamFrameInfo.displayTime`; a missing, malformed or future timestamp refuses that observation |
| `menuSurfaceStill` | not qualified | `SeatMenuInteraction.observe()` refuses, so no item inside a contextual menu can be chosen |
| qualified surface enumeration | implemented, Live matrix pending | AX scopes application windows and WindowServer independently attests each one; missing counterparts or duplicates keep containment unverified |
| role, modality and visibility | implemented, Live matrix pending | AX facts are bound to the matching WindowServer lifetime; unreadable modality or off-screen ambiguity suspends input |
| multi-window selection and parentage | implemented, Live matrix pending | a unique AX focused/main window selects the current target; sheets and drawers carry an attested parent and window-scoped modality |

There is no public switch that bypasses a refusal, and there is no constructor
that lets a consumer declare evidence qualified or assemble an Observation
Reference. The remaining menu Still needs its own oracle. Multi-window selection
fails closed to an explicit target choice only when AX reports no unique focused
or main window, or reports contradictory current-window state. The Live campaign
has not yet been run.

The bounded native composition contract is [ADR 0018](adr/Adr0018BoundNativeTextInputPreparation.md).
Qt reads its return geometry at adoption, as recorded in
[ADR 0019](adr/Adr0019QtAdoptionGeometry.md).
`AgentSeat.withNativeTextInput` preserves a fresh observation and confirmation
for each physical key while its Qt recipient owns one preparation. It restores
on completion, deadline and cancellation; it does not provide document rollback.

## Unqualified builds and Adobe UXP checks

Build and hardware coverage in the Ledger describe evidence. They no longer
block use after runtime self checks and permission preflights pass. Receipts keep
`unvalidatedBuild: true`; a successful run does not promote a Ledger entry.
Debug and release apply the same checks. Legacy `allowUnvalidatedBuild` options
remain accepted. See [ADR 0015](adr/Adr0015UnqualifiedBuildsRemainUsable.md) and
the [Adobe UXP qualification guide](platforms/UXP.md) for exact coverage and limitations.

A selected UXP dialog with stale global focus, or a selected document behind a
positively empty focus proxy, can qualify its own complete subtree as a
recipient to make key. Only that window's key pair and settle are applied,
without application activation. The proof repeats before the first post, and
incompatible caller overrides refuse. See
[ADR 0016](adr/Adr0016UXPModalKeysWithStaleFocus.md).

A click or a remembered field's text on an out of process file panel's content
is actuated through accessibility and posts no event; see
[ADR 0031](adr/Adr0031ActuateRemotePanelContentThroughAccessibility.md).

`make uxp-live-tests` runs eight dedicated Photoshop modal, document and editing
rows with `UXPPlatform`. Leave Photoshop in the background with only one
disposable RGB PNG open in Pro Editor mode, on an approved desktop in exclusive use, and name
its absolute path:

```sh
AGENTSEAT_UXP_DOCUMENT=/absolute/path/to/disposable.png make uxp-live-tests SWIFT=swift
```

The rows require automatic adoption, exact recipient selection, virtual
containment, fresh capture and independently observed effects. AX menu setup
can use the bounded refresh in ADR 0013 only with verified foreground handback.
A scoped JSX fixture independently attests document IDs, active tab, complete
count and seed URL; its bounded activation must hand foreground back.
Typed absence of all AX main/focus attributes on the sole PNG fixture can use
an identity-bound native make-key refresh before input qualification. Failed
Seat cleanup retains an independent native activation and exact document guards.
Cleanup touches the row's own dialogs and newly created Untitled tab; the named
PNG is never closed or saved. Reported counts, idle physical modifiers/buttons,
physical input, foreground, cursor and complete Host teardown gate the run.

`AGENTSEAT_UXP_CYCLES=1..20` controls repetitions;
`AGENTSEAT_UXP_ARTIFACTS=/existing/temporary/directory` retains PNGs for inspection;
`AGENTSEAT_UXP_SETTLE_MS=0..1000` calibrates the default 300 ms modal priming wait.
The [UXP guide](platforms/UXP.md) records each operation and environment actually verified,
including control and drag limits. Timing includes setup and polling, not a
subtracted microbenchmark.

## The fence is alive only while somebody holds it

The HID fence is reference counted in the process: the first acquisition
installs the tap, the last release removes it. A `SeatHost` holds it from
`start()` to `stop()`, so while the host is up the person's cursor cannot reach
the virtual display, and a diagnostic run with a hand on the mouse confirmed it:
186 events corrected out of 210 observed, zero disables of the tap, the cursor
stopped at the corner of the physical display and never entered the virtual one.

**Outside that window, with the virtual display still present, the cursor can
enter it.** That is the contract and not a defect. A tap at the head of the HID
stream is not something a library leaves installed after the work is over, and
the consumer that wants confinement outside an operation holds the fence itself:
`SeatHost.fence` is the same shared instance, and `CursorFence.acquire` from the
consumer's own code keeps it up for as long as the consumer needs.

The corollary is the reason the watchdog exists at all. "The pointer entered the
virtual display" is a check the fence cannot make, because the fence knows the
person's displays and deliberately knows nothing about the virtual one; only the
watchdog can combine the fence's latched signals with the display's geometry.

## Selection while containing preexisting windows

Returning to the consumer uses its exact visible AppKit window in ordinary
recovery and primed handback. A missing or non-keyable local destination
refuses without another activation route. External processes retain their
existing restoration policy. See
[ADR 0028](adr/Adr0028RestoreConsumerThroughAppKit.md).

When adoption begins from an attested thumbnail, or confirmation needs
staging, two agreeing full-size readings must also reach the requested
position. Stage Manager can otherwise pause at an intermediate position and
move again after adoption. The existing deadline and rollback apply; ordinary
full-size and in-place windows retain their confirmation rules. See
[ADR 0025](adr/Adr0025ConfirmStashedPlacementPosition.md).

A window of the application the seat cannot take in is named beside the
observation of the target instead of suspending it, and a withdrawn target
with nothing to take over is kept. See [ADR 0032](adr/Adr0032ObserveTheTargetBesideWindowsElsewhere.md).

A command pressed inside a brief activation keeps a short record of its own
(Command Provenance). An activation of the target, and a modal window of it
first seen, inside the record's margin are the command's effect: no `waiting`,
the window is taken in even while the seat waits, and one extra handback gives
the front back. See [ADR 0033](adr/Adr0033ExplainWhatAPressedCommandCauses.md).

Moving another already-open window into the seat can change the application's
front order. The identity currently placed by an adoption transaction is
excluded from application recency, while its geometry, visibility and modal
claims remain authoritative. Later qualified application recency for an owned
document updates both the selected capture and the registered current target.
Auxiliary eligibility alone does not grant that target change.

After moving preexisting siblings, the observation path stages the original
selected standalone window if it is still the selection. This keeps the native
application-wide AX hit test from naming a sibling above the captured window.
It does not reselect an old window after the selection changes. A staging
failure refuses the observation; all existing endpoint identity and modal
checks still apply. See [stabilization evidence](reports/StabilizationRounds.md).

The consumer's clean worker lease completion retires its display while keeping
the queue's AgentSession reusable. A finish warning or outstanding restitution
retains the host, including refused returns from earlier assignments on that
host. Handover within a lease keeps its existing lifecycle.
See [ADR0030](adr/Adr0030RetireCleanWorkerDisplays.md) for the cost and limits.

## Testing it

Everything goes through the `Makefile`; `make help` lists it.

```
make test           unit tier: pure, serialized, no permission needed
make host-tests     host tier: TCC and a real display, two commands, counts asserted
make live-tests     live tier: real windows and a real browser
make bench          the measurements of spec section 8, each one a gate
make compat-report  runs the tiers and writes compatibility/Build<build>.{md,json}
make promote-build BUILD=26A5425a
```

Three tiers. Unit is pure and serialized: adoption waits pump the main queue,
so parallel suites starve recovery instead of exercising independent work.
Host needs TCC and a real display. Live
drives real windows and a real browser, and it needs the person's Mac to itself:
a running consumer holds the virtual display's identity, and a second display
with the same identity is refused.

**A real display means an awake one.** `CGGetActiveDisplayList` is empty on a Mac
whose screen has gone to sleep, so there is no physical topology to attach a
virtual display to and the seat cycle fails with `.noPhysicalDisplays`. The Live
tier asks for one thing more: that nobody is driving the machine while it runs.
A person's own application switches cannot be told apart from an anomaly of the
target, so a row taken with a hand on the mouse comes back `INCO`, and an
inconclusive row is never a pass. Both are preconditions of measuring, not
defects to work around.

**A green exit status from a tier is not evidence that the tier ran.** Native
capture could return through Swift async main and exit before the test's
completion summary. Both Host processes and each Adobe UXP row use a synchronous native runner
around the same built Swift Testing bundle. The pure SeatSession unit bundle
uses it too: its AppKit RunLoop pumping can terminate the async runner before
completion. Other unit targets remain in SwiftPM, including their XCTest
tests. The unit tier requires 25 Swift Testing summaries there and one from
SeatSession; filtering omits the two empty Swift Testing companions of the
XCTest-only targets. The Host tier still
keeps the seat cycle apart from the display suites; UXP keeps each row in its
own process. Every tier asserts its reported count. An incomplete run therefore
fails even if the process exited zero.

The Live tier runs `--no-parallel` for a second reason: its two suites drive the
same browser, and in parallel one of them quits the window the other adopted.

The Live tier also needs a cooperative target to drive, and **the kit ships no
application**: test applications belong to the consumer. Point
`AGENTSEAT_FIXTURE_APP` at a binary that

- comes up as that target when launched with `--session <token>`, and
- publishes its state as JSON at `/tmp/agentseat-fixture-<uid>-<token>.json`,
  once or twice a second, with the fields `FixtureReport` declares (extra keys
  are ignored, so a consumer's own state object can be a superset).

Without the variable those rows are skipped, with the reason, and `make bench`
skips `stage`, which needs a second process because Stage Manager groups windows
by application. `/tmp` and not `TMPDIR` because `TMPDIR` is per process on
macOS, so two processes never agree on it.

```
AGENTSEAT_FIXTURE_APP=/path/to/target make live-tests
```

## Validating a macOS build

`make compat-report` runs the tiers and assembles `compatibility/Build<build>.md`
for a person to read, plus `compatibility/Build<build>.json`, a draft ledger
entry. It writes nothing into the ledger.

`make promote-build BUILD=<build>` is the only thing in the repository that
writes `Sources/PrivateSymbols/Ledger/validated-builds.json`, it takes the
build on the command line because it is a decision and not a step, and it
refuses a draft with any row that is not `verified`. The same build validated on
a second Mac adds that `hw.model` to the entry's hardware list.

A benchmark is a gate: it exits non zero on a violated budget. Two things are
reported and not gated, both for the same reason, which is that they measure the
machine and not the kit: a maximum above the absolute ceiling on a tight loop is
the scheduler taking the CPU away, and a regression against the saved baseline
on a run started above half the cores of load average is `INCONCLUSIVE`. An
inconclusive run is not a pass either. A baseline row is regenerated by deleting
it from `Tests/Benchmarks/Baselines/<build>-<model>.json` and running the driver;
a run that happens to be fast never saves its own numbers over one.

## Measuring the phases

A measurement build splits the time of one tool call into phases with `os_signpost`
intervals. Everything is behind the compilation condition `MECUM_PHASES`, which no default
configuration sets: a normal build contains no signpost, no helper type and no phase name, and
the target `PhaseSignposts` that holds the helper is empty without it. A measurement build must
also be optimized, since Swift in Debug is slower and would skew every number.

```
swift build -c release --product mecum -Xswiftc -DMECUM_PHASES
xcodebuild -workspace AgentEnvironment.xcworkspace -scheme Mecum \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath <dir> build-for-testing \
    OTHER_SWIFT_FLAGS='$(inherited) -DMECUM_PHASES' SWIFT_OPTIMIZATION_LEVEL=-O
```

The flags are passed on the command line and are never committed into the project. To see
the table, record while the measured build works, then stop with Ctrl-C:

```
python3 Tools/Driver/Phases/phase-table.py record [--process Mecum] [out.ndjson]
python3 Tools/Driver/Phases/phase-table.py table out.ndjson
```

`record` runs `log stream --signpost` for the subsystem `dev.forte.Mecum.phases` (no sudo)
and prints the count, median, p95 and maximum in milliseconds of every phase. An interval whose
operation threw is never ended and is left out. The phases, outermost first:

| Phase | Where it runs |
| --- | --- |
| `tool:<name>` | One MCP tool call (`AutomationTools.call`). |
| `perception` | One scene (`SeatSceneProvider.currentScene`). |
| `perception.reused` | A scene answered again because the window Still is byte-identical to the one the last scene was read from, timed from the start of `perception`; it is ended only then, so its count is the number of reuses ([ADR 0034](adr/Adr0034ObserveFromTheRunningWindowStream.md)). |
| `capture.windowStill` | The window Still of a scene, which is `SeatTarget.observe()`. |
| `target.observe`, `target.verify` | `SeatTarget.observe()` as a whole, and its window check before the seat is asked. |
| `seat.observe` | One attempt of `AgentSeat.observe()`, inside `SeatTarget`'s retry loop. |
| `seat.preCapture`, `seat.foldReading` | The seat's identity and containment work before it captures, and every window reading it folds. |
| `seat.captureLoop`, `seat.captureSource`, `seat.stillCurrent` | The capture loop, the call into the capture source, and the check that the situation is the same after it. |
| `capture.oneShotStill`, `capture.streamStill` | The one-shot Still, and the stream Still that replaces it. |
| `capture.liveFrame` | The wait for a frame of the running window stream, with its hand-over checks ([ADR 0034](adr/Adr0034ObserveFromTheRunningWindowStream.md)). An event `capture.liveFallback` names the reason when a Still was taken instead. |
| `capture.stream.size`, `.start`, `.firstFrame`, `.stop` | The steps of the stream Still. |
| `capture.makeCGImage`, `capture.displayStill` | The Frame to image conversion, and the display Still used while a pop-up is open. |
| `pipeline`, `pipeline.ocr`, `.segments`, `.ax`, `.compose`, `.axWait`, `.merge`, `.controlState` | The scene pipeline and its stages; text, segments and accessibility run concurrently. |
| `delivery.prepare`, `delivery`, `delivery.confirm` | Getting the Turn and the observation, posting the Command, and confirming it. |
| `pause` | Every fixed wait of the act cycle. |
| `settle` | The wait after a gesture on a streamed seat window, until its frames stop changing or the cap ([ADR 0035](adr/Adr0035SettleOnTheRunningWindowStream.md)); named `settle:stable`, `:quiet`, `:cap` or `:fallback.<reason>` by how it ended. |
| `render.scene`, `render.result` | Writing the scene for the model, and encoding and recording the answer. |

Splitting the identity cost of a Still: `target.observe` minus `seat.observe` is the
`SeatTarget` side, `seat.preCapture` and `seat.stillCurrent` are the seat's, and
`seat.captureLoop` minus `seat.captureSource` is what the loop spends around the capture.

The only points in the Engine and Perception layers are `ActionEngine.init` (`pause`) and
`ScenePipeline.perceive`.

Measured on 7 October 2026 in the app's test host, optimized, 20 `observe` and 20 `press_key`
per application ([raw table](measurements/CapturePhases20261007.txt)). The one-shot Still of
this system never carries a display time, so it is now taken once per seat: the median
`capture.windowStill` fell from 212 to 143 ms on Calculator, 208 to 144 ms on Chrome and 256
to 146 ms on TextEdit, which is the one-shot's own cost (68 to 85 ms) and, on TextEdit, a
faster stream after it. `target.observe` and `seat.observe` are equal to the tenth of a
millisecond, so the `SeatTarget` side costs nothing; what remains of a Still is the stream
itself (`capture.stream.size` about 46 ms, `.start` about 80 ms, `.stop` about 8 ms), and
the 310 ms `pause` is the largest part of an action.

Since then a window Still first reads the window stream the Broker's preview already runs, and
the running stream reads the window server once a second instead of twice a frame; see
[ADR 0034](adr/Adr0034ObserveFromTheRunningWindowStream.md). That has not been measured live yet.
The wait after a gesture then watches that same stream and ends once the window settled, capped
at the fixed pause; see [ADR 0035](adr/Adr0035SettleOnTheRunningWindowStream.md). Not measured
live either.

## Requirements

macOS 15 or later to build, the lowest version the package compiles for, though
every private primitive is validated per build, so the seat runs only on a build
the ledger lists: see [SpiLedger.md](SpiLedger.md) for what is used and what was discarded, and
[compatibility/](compatibility/) for the report of each validated build. Accessibility is
required for input and the fence, Screen Recording for capture. The kit relies on
undocumented system interfaces, so it is not a basis for the Mac App Store.

## Documents

| Path | What it holds |
|---|---|
| [CONTEXT.md](CONTEXT.md) | the domain vocabulary, binding |
| [CodeStyle.md](CodeStyle.md) | the Driver's local conventions |
| [SpiLedger.md](SpiLedger.md) | every private primitive that is used, that was verified and left out, or that was discarded, with the reason and the build |
| [adr/](adr/) | why the load-bearing decisions are what they are |
| [specs/](specs/) | the [hand-off specification](specs/HandoffSpec.md), the [keyboard](specs/KeyboardSpec.md) and [launch focus](specs/LaunchFocusSpec.md) designs |
| [platforms/](platforms/) | per-family policy and qualification: [Chromium](platforms/Chromium.md), [Qt](platforms/Qt.md), [Adobe UXP](platforms/UXP.md) |
| [reports/](reports/) | dated campaigns through the Mecum app: application flows, stabilization rounds, release readiness, Photoshop runs, the TryCUA comparison and the Cua Driver benchmark |
| [compatibility/](compatibility/) | `Build<build>.{md,json}`, the report of one validated build, and named campaigns |
| [measurements/](measurements/) | raw rows behind the live campaigns and benchmarks |

The comments are the fourth document. A comment here says what a thing does and
why it is that shape, with the number that decided it, and never where the
number came from: a reference to a research note somebody else cannot open
explains nothing.
