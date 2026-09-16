# Agent Seat

The domain vocabulary of AgentSeatKit. It is binding on code, comments, API
names and test names, and it is shared with whatever consumes the kit: a term's
_Avoid_ list is the set of words that already mean something else here. Every
term is English, whatever language the consumer speaks to its own users in.

## Seats

**Agent Seat**:
The agent's operating domain on the shared Virtual Display: one or more Adopted
Windows with their own input routing, guard, recovery and capture. Today exactly
one seat exists per host; the model admits n.
_Avoid_: agent desktop, virtual seat, sandbox

**Seat Host**:
The owner of one Virtual Display and of the shared Cursor Fence. It starts and
stops the display and creates Agent Seats on it.
_Avoid_: stage, display manager, session

**User Seat**:
The person's operating domain: their displays, focus, cursor and windows. Never
a fallback for agent input. The explicit recovery exception in ADR 0010 can
restore the last observed user window after an adopted application activates.
It cannot click, type, move the pointer or select an arbitrary user window.
_Avoid_: user desktop, human seat, main screen

**Seat Backend**:
The concrete mechanism that realizes a seat's input, focus and output.
AgentSeatKit is one backend: a virtual display inside the user's own session.
_Avoid_: engine, runtime

## Actuation

**Background Driver**:
The last execution layer. It receives a Window Reference, a location and one
command, builds the events, and posts them to the target process. It knows no
accessibility tree and no UI semantics.
_Avoid_: actuator (the Orchestrator's verified layer), input engine

**Command**:
One complete, atomic input action: key, click of either button, drag or scroll.
One call, one command; the driver never splits or retries it.
_Avoid_: action, gesture, step

**Contextual Menu**:
The menu a right click opens inside the target: a window of that process at the
pop up menu level, running a modal tracking loop, and absent from the target's
own accessibility tree. It is not a Command, because it has to be closed again:
the seat opens one, lets the caller use it and closes it in a single action.
_Avoid_: popup, right click menu, tendina (prose only)

**Receipt**:
What the driver returns after posting: how many events went out and by which
route. It proves delivery, never effect.
_Avoid_: result, outcome (the Orchestrator's verified classification)

**Platform**:
The preparation and pacing policy for one family of target apps (AppKit,
Chromium and Electron, a consumer's own). The posting route is the same for all.
_Avoid_: profile (the research-era name), route, backend

**Preparation**:
The two records that make the target window active and key inside its own
process only, sent before a mouse Command on platforms that need it and undone
once the Command is done.
_Avoid_: activation (the user-visible kind), focus, prep

**Cursor Fence**:
The HID-level event tap that keeps the physical cursor on physical displays and
suppresses presses that start outside them.
_Avoid_: recinto (prose only), cursor lock, clamp

## Surfaces

**Virtual Display**:
The CGVirtualDisplay-backed screen owned by a Seat Host and shared by its Agent
Seats, attached to a corner of the physical topology.
_Avoid_: virtual screen, virtual monitor

**Frame**:
One captured image of the Virtual Display or of an Adopted Window, backed by an
IOSurface. A receiver holds at most one at a time.
_Avoid_: screenshot, image, sample

**Still**:
A Frame of the Adopted Window taken once, on request, for observation.
_Avoid_: snapshot (an accessibility model of a window), screenshot, capture

**Monitor**:
The live preview stream of the Virtual Display shown to the human.
_Avoid_: preview, feed

**Adopted Window**:
A target window a seat moved onto the Virtual Display, with its original frame
recorded so that releasing it returns it to the User Seat.
_Avoid_: hosted window, captured window, managed window

**Window Reference**:
Process ID bound to one process lifetime, Window ID, owning WindowServer
connection and frame. The only identity the kit needs for a target window; the
consumer resolves it through the WindowServer observation layer. A raw PID and
Window ID are an unverified compatibility value and cannot authorize input.
The system exposes no window birth identifier here: after observing a close,
the consumer discards the reference and resolves any replacement again.
_Avoid_: snapshot (an accessibility model of a window), target window

## Integrity

**Issue**:
A detected anomaly during a seat operation. Critical issues stop the seat;
recoverable ones suspend and retry within a bounded budget.
_Avoid_: error, warning, anomaly

**Recovery**:
The bounded sequence that re-confirms identity, window and display after a
recoverable Issue. An unverified input is never replayed.
_Avoid_: retry, healing

**Seat Observer**:
The component that watches the User Seat while a Command is in flight, so that a
voluntary change by the person is told apart from an anomaly of the target.
_Avoid_: transient observer, watcher (the Orchestrator's learning pipeline)

**Watchdog**:
The eight checks that re-verify the seat invariants (main display, physical
geometry, display online, tap active, tap never disabled, pointer out of the
virtual display, pointer inside the physical region, pointer readable) and
trigger Fail Closed on a violation. It runs on events where events exist, the
display reconfiguration callback and the fence's own latch, plus one heartbeat a
second; the 20 ms loop it replaced is the research-era engine, not the contract.
_Avoid_: monitor (the preview stream), health check

**Turn**:
Exclusive use of one Agent Seat between two safe points, with a monotonic
generation and a flag saying whether anything happened since the holder's last
one. It carries no TTL, priority or revocation: those are the Orchestrator's
Lease and Epoch, built on top of this.
_Avoid_: lease, lock, session

**Heartbeat**:
The one-a-second pass that re-reads what nothing reports: the cursor's position,
the tap's enabled bit, the CPU share the Monitor's quality policy needs, and
whether a `waiting` seat's target went back to the background.
_Avoid_: poll, tick, watchdog (the checks it runs)

**Fail Closed**:
On an unknown symbol, record layout or macOS build the facility refuses to act.
There is no implicit fallback to global event posting.
_Avoid_: graceful degradation, best effort

## Primitives

**Facility**:
One service the kit offers or refuses on the running macOS build: Display,
Input, Fence and Capture. A Facility reports `validated`,
`unvalidated(build)` or `unavailable(reason)` and is built from Primitives.
_Avoid_: capability (the Orchestrator's revocable authority), backend, provider

**Primitive**:
One OS function or private symbol the kit relies on, tracked per macOS build
with a state: verified, limited, discarded or untested.
_Avoid_: API, call, SPI (use "private primitive")

**Ledger**:
The kit's record, per macOS build and hardware model, of every Primitive's state
and of the verdict derived for each Facility.
_Avoid_: registry, whitelist, database

**Promotion**:
The human act of copying a build's draft entry into the Ledger after reading its
compatibility report. Never automatic.
_Avoid_: approval, sign-off, merge

**Fixture**:
The cooperative AppKit target app the Live tier drives. It belongs to the
**consumer**, not to the kit: the kit ships no application, and the Live tier
finds the binary through `AGENTSEAT_FIXTURE_APP`.
_Avoid_: test app, dummy, mock

**Window Reader**:
The read-only reader of another application's accessibility tree, linkable by a
consumer: the type `WindowReader` in the module `TargetReader`, answering with
an `ObservedWindow`. It reads and returns value types and never acts on the
target; the one write it makes is `AXManualAccessibility`, the precondition of
reading a Chromium tree at all (ADR 0009). No Facility depends on it, and what a
reading *means* is the caller's.
_Avoid_: probe (kept only for `WindowServerProbe`, which reads the window
server and not a tree), observer, checker, snapshot
