# Agent Seat

The domain vocabulary of AgentSeatKit. It is binding on code, comments, API
names and test names, and it is shared with whatever consumes the kit: a term's
_Avoid_ list is the set of words that already mean something else here. Every
term is English, whatever language the consumer speaks to its own users in.

## Seats

**Agent Seat**:
The agent's operating domain on the shared Virtual Display, encompassing Assigned
Applications and Adopted Windows with their input routing, guard, recovery and
capture. An assigned application can remain in this domain without any open windows.
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

**Shortcut**:
A declarative hotkey: one key reference plus the modifiers held around it. It is
not a Command. It is the value that resolves, through the Key Table and the
Keyboard Layout, into the one key Command the driver posts.
_Avoid_: hotkey, key combo, accelerator

**Key Table**:
The kit's own versioned table from virtual key to physical key name, the name
that describes a position and is the same on every layout. Its version is bumped
by hand, so a consumer that stored a physical name notices when the table moved
under it.
_Avoid_: keymap, key codes

**Keyboard Layout**:
One reading of the keyboard layout installed right now: its input source id, a
generation that changes when the person switches layout, and the base, Command
and Shift rows that name each virtual key. It resolves a shortcut expressed as
a character. Option and Control remain event flags rather than changing that
name, and no Unicode payload is attached to a resolved Shortcut. It is the only
place the layout enters at all.
_Avoid_: keymap, snapshot (an accessibility model of a window), input source

**Key Hold**:
The keys the kit itself is holding down on one target process, owned per Turn.
It holds keys and not only modifiers, because a letter left down leaks the same
way a Command key does; the modifiers are the subset whose virtual key is one,
and that subset is what stamps the flags of the next Command. It never describes
the person's own hand, which the kit neither reads nor infers. A Turn cannot be
given back while it still holds a key.
_Avoid_: modifier state, modifier hold, flags

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
The activation and key-window records that make the target window active and
key inside its own process only. A platform applies them before a Command and
restores them afterwards. A qualified Native Text Input scope can own them
across separately observed Commands until its bounded closure.
_Avoid_: activation (the user-visible kind), focus, prep

**Native Text Input**:
A bounded, explicitly qualified composition scope that keeps the recipient's
native input context prepared in one Turn. Every physical key still requires
its own observation, decision and confirmation. Deadline, cancellation and
window return close the scope and restore preparation. Closure is not document
rollback and does not promise to discard marked text.
_Avoid_: sequence, batch, foreground typing.

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

**Assigned Application**:
An application instance entrusted as a whole to an Agent Seat, including its
attributable windows. Its assignment persists while that instance has no windows.
_Avoid_: adopted process, target PID

**Adopted Window**:
An identified window accepted into a seat's management on the Virtual Display,
whether moved there or already contained there. It is distinct from the Assigned
Application and need not be the current input or observation target.
_Avoid_: hosted window, captured window, managed window

**Window Recency**:
The relative order of verified appearances, reappearances and returns to the
front within an Assigned Application, excluding raises caused by the kit.
It is neither window creation age nor the User Seat's global focus.
_Avoid_: adoption order, birth order, global focus

**Selected Target**:
The identified window chosen for the agent's next observation and input, which
may not yet be ready for interaction.
_Avoid_: focused window, frontmost window

**Operational Target**:
A Selected Target ready for agent input, with verified identity and containment,
an up-to-date Frame of that window, and no remaining input suspension.
_Avoid_: detected window, captured window

**Observation Reference**:
The link between a Frame and the selected window identity, selection generation
and geometry version on which a Command is based. It identifies the observation,
not permission to act or proof of the Command's effect.
_Avoid_: Window Reference, Receipt, input authority

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
On a missing permission, unresolved symbol or invalid record layout the facility
refuses to act. Missing build qualification is reported without blocking use
(ADR 0015). There is no implicit fallback to global event posting.
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
