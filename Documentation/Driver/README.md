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

The [Chromium qualification guide](Chromium.md) records the app's renderer
readiness, bounded native composition and eight owned-browser rows in
`make chromium-live-tests`, including known menu-equivalent effect failures.

The [Qt driver guide](Qt.md) records the command policy and the live
qualification of DaVinci Resolve's Project Manager, including the commands
whose target-side effect still needs a witness.

The [Mecum application flow checks](ApplicationFlowChecks.md) record effects,
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
the [Adobe UXP qualification guide](UXP.md) for exact coverage and limitations.

A selected UXP dialog with stale global focus, or a selected document behind a
positively empty focus proxy, can qualify its own complete subtree as a
recipient to make key. Only that window's key pair and settle are applied,
without application activation. The proof repeats before the first post, and
incompatible caller overrides refuse. See
[ADR 0016](adr/Adr0016UXPModalKeysWithStaleFocus.md).

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
The [UXP guide](UXP.md) records each operation and environment actually verified,
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

When adoption begins from an attested thumbnail, or confirmation needs
staging, two agreeing full-size readings must also reach the requested
position. Stage Manager can otherwise pause at an intermediate position and
move again after adoption. The existing deadline and rollback apply; ordinary
full-size and in-place windows retain their confirmation rules. See
[ADR 0025](adr/Adr0025ConfirmStashedPlacementPosition.md).

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
checks still apply. See [stabilization evidence](StabilizationRounds.md).

## Testing it

Everything goes through the `Makefile`; `make help` lists it.

```
make test           unit tier: pure, serialized, no permission needed
make host-tests     host tier: TCC and a real display, two commands, counts asserted
make live-tests     live tier: real windows and a real browser
make bench          the measurements of spec section 8, each one a gate
make compat-report  runs the tiers and writes docs/compatibility/Build<build>.{md,json}
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
around the same built Swift Testing bundle. The Host tier still
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

`make compat-report` runs the tiers and assembles `docs/compatibility/Build<build>.md`
for a person to read, plus `docs/compatibility/Build<build>.json`, a draft ledger
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

## Requirements

macOS 15 or later to build, the lowest version the package compiles for, though
every private primitive is validated per build, so the seat runs only on a build
the ledger lists: see `docs/SpiLedger.md` for what is used and what was discarded, and
`docs/compatibility/` for the report of each validated build. Accessibility is
required for input and the fence, Screen Recording for capture. The kit relies on
undocumented system interfaces, so it is not a basis for the Mac App Store.

## Documents

`docs/Spec.md` (the hand-off specification), `docs/adr/` (why the load-bearing
decisions are what they are), `docs/SpiLedger.md` (every private primitive that
is used, that was verified and left out, or that was discarded, with the reason
and the build), `docs/compatibility/Build<build>.md` (the report of one validated
build), `Context.md` (the domain vocabulary, binding), `CodeStyle.md`,
`CLAUDE.md`.

The comments are the fourth document. A comment here says what a thing does and
why it is that shape, with the number that decided it, and never where the
number came from: a reference to a research note somebody else cannot open
explains nothing.
