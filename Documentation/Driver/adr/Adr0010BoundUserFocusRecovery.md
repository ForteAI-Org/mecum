# Restore user focus after an adopted app activates

Accepted for the Lab on 2026-09-10 at the user's request. This is a narrow
exception to the former rule that no kit operation may actuate the User Seat.
It does not authorize agent input on physical displays.

Before input, every visible window belonging to an adopted application must
be inside the virtual display in the prepared snapshot. During a held turn, a
workspace activation notification closes the driver's command gate before the
session validates or restores anything. The destination is the last focused user window observed on a physical
display. Read-only focused-window notifications update it when the user changes
windows within an application; ordinary user app switches update it as well.

The user window must appear in the on-screen WindowServer list and have a
nonempty visible area on a physical display, with no intersection of the
virtual display. It need not fit wholly inside a single physical display:
oversized windows and windows spanning physical displays remain destinations.
This rule applies both to pre-action/verification readings and to the prepared
snapshot. Adopted windows still require full virtual-display containment.

Before input, recovery resolves that window's owning connection and PSN, then
retains them with the prepared snapshot. Upon activation it calls the
exact `_SLPSSetFrontProcessWithOptions` export with its Window ID and mode 0x200.
The activation request itself names the intended window. Recovery sends no
additional key-window records; the exact focused Window ID is verified before
the command gate reopens. The record pair remains in ordinary background target
preparation, where it has a different purpose.
There is no pointer event, global keyboard event, app-wide raise, AX focus write,
process suspension signal or process termination.

## Pre-action preparation (2026-09-10)

The input driver awaits preparation before touching the target's AppKit state
and immediately before each atomic command, including a menu selection and each
command in a sequence. The seat reserves the action before this await and checks
its held correlation ID, recovery instance and acting state on both sides.
Cancellation or a gate closed during the await prevents posting. Earlier
sequence receipts remain attached to `InputSequenceFailure`; no command is retried.

Focused user identity and display ownership stay on MainActor. A structured
`@concurrent` call enumerates the WindowServer list using only Sendable geometry;
MainActor remains available for activation notifications during that read. Each
preparation replaces the previous one. It expires one second after preparation
**starts**, matching the existing 800 ms delayed menu-activation observation
window with a small preparation allowance. This is an upper validity bound,
not an assertion that the saved window is necessarily still current.

A changed hold, teardown, observed user app/window change, changed adopted set,
cancellation or slow completion prevents reuse. At activation, the snapshot is
consumed once; current front-process PSN, switch intent and display topology
are still read. The live fence query runs before input and before reopening the
command gate, not before focus-only restoration: the gate is already closed
and restoration emits no pointer input. `CGEvent.tapIsEnabled` can require a
WindowServer round trip; moving it does not admit input with a disabled fence. `_SLPSGetFrontProcess` compares against the adopted
process serial numbers resolved before input, avoiding the NSWorkspace getter
on this urgent path. The exact underscore export is separately required by the
opt-in focus facility; its ABI was already verified in the read-only sampler.
The prepared destination PSN is never replaced by a newly discovered owner
after activation. Window enumeration and AX destination discovery do not run on
the urgent path. A missing/expired preparation is a miss: input stays paused,
with no synchronous scan or automatic second attempt.

This is the user's accepted best-effort tradeoff: windows/dialogs created or
moved after preparation are absent from the evidence. The recovery assumes the
agent application continues to place them on its separate display. It cannot
prove fresh post-action geometry without paying for another scan. Custom
`SeatSensing` implementations must supply a snapshot through the new async
method or its synchronous default to enable automatic recovery.

Timing reports distinguish pre-action preparation, prepared identity resolution,
prepared window enumeration and snapshot age from the activation-path phases. `firstKeyNanoseconds` and
`secondKeyNanoseconds` remain for report compatibility and are zero on this
activation-only path, as are urgent owner/PSN lookup durations. The independent WindowServer sampler remains the oracle
for actual front-process interruption; neither request completion nor AX
verification duration substitutes for that interval.

The input gate opens only after two observations agree on the frontmost PID and
focused Window ID, with the physical window still visible and the display and
fence intact. A changed application selected by the user during recovery wins.
One automatic request is allowed per hold. A missing destination, recent click
or app-switch shortcut, refused request, recurring activation or verification
timeout keeps the seat waiting. Verification uses a 5 ms timer for up to 250 ms,
then a 100 ms timer while awaiting the user. These are observation cadences, not
latency guarantees: AX calls and the main run loop can delay them.

Pausing occurs at command boundaries. An already admitted command remains
atomic so a mouse/key down is not abandoned without its release. The next
command, including a subsequent command in a sequence, checks the gate. A
sequence interrupted after earlier commands returns `InputSequenceFailure`
with their receipts; the seat preserves them as unconfirmed. Nothing is queued
for automatic replay. The agent must perceive the resulting dialog or page and
confirm the previous action before deciding its next one.

Recovery is explicitly enabled through `SeatHostConfiguration.restoresUserFocus`.
It is off by default. The Lab opts in and enables
`allowUnvalidatedFocusRecovery`; this affects only the new optional facility,
not display/input/fence/capture readiness. The new private export is not promoted
into `validated-builds.json` by these focused experiments. Its symbol resolution,
record self-checks and Accessibility preflight still run and cannot be bypassed.
Consumers can read `AgentSeat.focusRecoveryReadiness`, `lastFocusRecovery`, and
the `SeatEvent.userFocusRecoveryChanged` reports.

The mechanism is app-independent; the measured dialog trigger is Chrome Print.
Other dialogs and macOS builds need their own live evidence. It does not prevent
the initial focus transfer or guarantee that no physical keystroke lands in the
target during the interval before recovery. An activation first observed only
after a hold ends is not automatically reversed. An idle user activation is
left alone. Physical app-switch intent is conservative and can defer recovery
after an unrelated click.

Primary source for the private ABI and key-window recipe:
[yabai extern.h](https://github.com/koekeishiya/yabai/blob/master/src/misc/extern.h)
and [window_manager.c](https://github.com/koekeishiya/yabai/blob/master/src/window_manager.c).
Local arm64 disassembly on 26A5425a confirms the pointer to two 32-bit PSN words,
the Window ID, and the 0x200 mode bit. The raw runtime evidence remains under
`../measurements/` and the contract remains in this ADR.

## Diagnostic comparison and event provenance (2026-09-10)

A package-only, default-off comparison flag can append the two existing key-window
records to the exact prepared destination. It uses the same gated facility and
never discovers another user window. It is not the Lab's production setting.
Activation-only remains the default: the twelve-cell comparison found no AX
failures in either mode and does not establish a benefit from the extra records.

The read-only activation observer now timestamps notification receipt on the
posting thread. It preserves synchronous handling when already on main and
passes immutable PID/time values to MainActor otherwise. A stopped observer
ignores a queued callback. Reports distinguish receipt, handler entry and the
context-menu fallback poll; notification receipt is not an OS event timestamp.
The measurement bundle under `../measurements/` records the campaign limits.

## Process scope of prepared window evidence (2026-09-14)

Preparation requests the set of all adopted application PIDs plus the saved
destination PID. The WindowServer list's owner PID classifies each row before
identity resolution. Every on-screen row for those processes must resolve to
an attested Window Reference with the same PID and Window ID. This includes
dialogs and other windows of an adopted application, not only adopted IDs.
All adopted processes must have their visible windows inside the virtual
display before a restoration request is allowed.

A row belonging to another positive PID is outside this claim and is not
attested. This applies to WindowServer surfaces and unrelated applications
without guessing from owner names, window titles, levels or connection IDs.
In particular, a failed identity lookup is never itself an exclusion rule.
An unavailable list, a missing or invalid owner PID, or an unresolved relevant
row invalidates the window evidence and keeps recovery paused. No partial
list authorizes restoration.

`FocusRecoverySnapshot.coveredProcessIDs` records the scope. A nil scope means
the custom reader declares a complete reading of all processes; an explicit
set cannot support claims about other processes. The scoped sensing method
defaults to the existing unscoped reader, preserving custom conformers without
silently granting coverage. `windowsAreComplete` describes that scope alone
and remains separate from display topology. Every snapshot predicate checks
both completeness and process coverage.

This relies on the PID supplied by the WindowServer listing for classification,
and on the independent connection/PSN/PID chain for every retained reference.
It does not establish identity from a PID alone or change the existing limit
on windows created or moved after preparation. Hold binding, cancellation,
snapshot age, exact destination identity, user intent, the closed input gate
and the two verification readings retain their existing rules.

## The containment exception for focus alone, and the approved budgets (2026-09-16)

The rule at the head of this ADR — every visible window of an adopted
application inside the virtual display before anything happens — is revised in
exactly one place and no further. During delivery, staging and automatic
containment, a focus restoration to the prepared and attested user destination
may be requested **while windows surely attributed to the adopted application
are still to be transferred**, with the agent input gate closed throughout.

The exception is limited to the containment precondition of the focus
restoration. Full containment remains required before input and before the
delivery is complete, and every other guard is unchanged: attested destination
and identity, completeness and process scope of the evidence, a valid
preparation, display topology, the user's own intent and the Facility gate. A
recovered focus does not mean a successful containment, and it reopens none of
the other causes of the gate.

The budgets these paths are held to are the ones already approved, written here
so they are read together and not restated anywhere else:

| Interval | Budget | Measured from, to |
|---|---|---|
| one `UserFocusRestorer.restore` call | 8 ms | entry to exit of the whole method, primitive, preparation, detection, effect and verification kept apart |
| containment of a newly detected window | 250 ms | first detection of the window, to its verified containment |
| the initial delivery | 2 s | the start of the delivery, to the verified completion of the initial set |
| focus verification | 250 ms | the return of the activation request, to two agreeing readings of the exact destination |
| a late activation | 1 s | the start of the original preparation, which is not renewed |
| automatic attempts | one | per Turn, or per complete delivery/containment operation outside a Turn, never per window or per notification |

Every one of those is a **requirement to be qualified**, not a measurement that
has been taken. An overrun fails the performance criterion of the campaign; it
never triggers a second restoration, a replay or a redirection, and no average,
tolerance or historical report substitutes for the per-call maximum. Nothing
here is a hard real-time guarantee.

## What the observation cutover changed here (2026-09-16)

`AgentSeat` no longer exposes an entry point that posts a list of Commands, so
the paragraph above about "a subsequent command in a sequence" now describes the
input driver's own sequence, which is unchanged. A consumer that wants a
succession orchestrates it, observing and deciding again between Commands; the
driver's `InputSequenceFailure`, its retained receipts and the rule that nothing
is queued for automatic replay are untouched.

The boundary before the first event gained one more check and lost none. A
Command is addressed by a `SeatObservationReference`, and that reference is
verified at admission and again on the last main-actor statement before the
sender is handed the Command, alongside the existing identity, geometry, gate
and fence checks. The recipient is the reference's and is never recomputed from
the current target.

This section records a change of code and of contract. It certifies no native
capability: on this build the content clock is unqualified, the dedicated
surface of a contextual menu cannot be captured, and the surface enumeration is
incomplete, so the kit refuses with those gaps named. The 8 ms, 250 ms, 2 s and
1 s figures above have not been measured by this work, no live, Host or manual
run was performed for it, and the historical reports elsewhere in this ADR
remain what they were when they were written.

## A refusal names the stop (2026-09-16)

Every pause used to arrive as one `InputFailure.inputPaused` with nothing
attached, so a failed run could not be told apart: a gate held closed by a
window transfer, a hold that had already ended, an inactive fence, a restore
that named an unprepared window and a preparation belonging to another action
all printed the same sentence. The case now carries `[InputPauseReason]`, the
gate reports the causes of the one reading that refused, and each other refusing
site names its own. Consumers keep writing the sentence; the kit still carries
no prose.

The names are a record of the reading that refused, not a promise about the next
one, and none of them reopens the gate, shortens a wait or authorises a retry.
The stops themselves, the verification rule, the one automatic request per hold
and the budgets above are unchanged by this, and nothing here was measured.

The capability statements in the previous section were written before the
observation adapters of the same day; the table in `../README.md` is the current
record of what has an adapter and what is still waiting for the Live matrix.

## A Command does not disarm the recovery it needs (2026-09-16)

Pre-action preparation superseded **and discarded** the preparation already
held, and rebuilt one only when the person's application was the front one.
Those two rules met in the case the recovery exists for. An adopted application
that raises a dialog activates itself; the next Command is prepared while that
application is in front, so the rebuild cannot read a fresh destination and the
discard has already thrown away the evidence made moments earlier. The
activation notification then arrived with nothing prepared, no request went out,
and the seat waited for a person who had done nothing. Measured in the Lab on
DaVinci Resolve's New Project dialog: `waitingForUser`, zero requests, input
paused for the rest of the session.

Preparation now supersedes what is in flight without discarding what is held.
A preparation is still dropped when it is about something else: a changed hold,
a teardown, a changed user window, or the activation that consumes it. Nothing
else changed, and in particular nothing was relaxed to make the kept evidence
usable: the one-second lifetime still expires it, and the environment, adopted
windows, target containment, destination, front process and app-switch intent
are still re-checked at the activation. This narrows the documented gap rather
than widening it — the alternative was not fresher evidence, it was no request
at all.

The one automatic request per hold, the verification rule and every budget above
are unchanged. No live, Host or manual run was performed for this change; the
sequence is pinned by an offline suite.

## Three rules the Lab's evidence changed (2026-09-16)

Accepted at the user's request after four measured Lab runs against DaVinci
Resolve's New Project flow, each one reported by the kit's own refusal.

**The pass no longer stands down because the driven application is active.** It
was the wrong reading of the right evidence. The applications this seat drives
activate themselves exactly when they open the window the pass exists to find,
so the rule left every dialog, and every window an agent's own Command opened,
outside the seat and on the person's display for as long as it held focus, with
containment expiring and the seat suspended. What separates the person's intent
from the application's own is the physical evidence the same guard already
reads — a click or an app-switch shortcut in the last third of a second — and
that, the hold, an action in flight, a teardown and a recovery still restoring
are unchanged.

**One automatic request per activation, not per hold.** The budget was spent for
the rest of the hold by the first activation. A consumer that holds the seat
across a run therefore had one request per run: the second dialog it opened
waited for a person who had not done anything. The episode's end now returns the
request, so each activation may ask once and no activation may ask twice. A
failed verification still never asks again inside its own episode.

**A window the application stopped scoping is closed after a grace.**
`ClosureEvidence` gains `applicationWithdrewTheWindow` for it. Where the
enumeration is positively scoped by AX, a window the application no longer lists
is not one of its windows, even though the window server still holds a visible
surface: measured on Resolve, its Project Manager does exactly that, and the
member stayed absent-uncertain for the rest of the session while containment
could never verify again. It is neither of the two evidences that existed —
nothing was destroyed, and this is not a reading that missed something — so it
is its own, and it is offered only after the surface has been outside the
application's scope for a whole second, which excludes a slow or momentarily
unavailable accessibility reading. The cross-check reports what it saw and the
transition filter holds the clock; a surface listed again in between starts the
clock over.

Everything these three touch is offline evidence. No live, Host or manual run
was performed for them, the budgets and the verification rule above are
unchanged, and the Live matrix for the observation adapters is still pending.

## The desktop is not one of the application's windows (2026-09-18)

The sentence at the head of this ADR, "every visible window belonging to an
adopted application must be inside the virtual display in the prepared
snapshot", is wrong as written, and it was wrong from the start. It is revised
here in one place.

Measured on 26A5425a in a live run with the Finder adopted. The restoration was
refused with `A prepared target window is outside the virtual display: Window ID
39 of PID 487 at (0.0, 0.0, 1512.0, 982.0)`, and the run stopped with the input
paused. Listing pid 487 through `CGWindowListCopyWindowInfo` showed what Window
ID 39 is:

| winID | layer | on screen | bounds | name |
|---|---|---|---|---|
| 39 | -2147483603 | true | (0, 0, 1512, 982) | |
| 43302 | -2147483603 | true | (1512, 982, 2560, 1440) | |
| 39393 | 0 | true | (15, 781, 120, 155) | Downloads |

Layer -2147483603 is `CGWindowLevelForKey(.desktopIconWindow)`. Window 39 is the
desktop of the physical display and 43302 is the desktop of the virtual one. The
Finder draws one per display, always, and neither is a window anybody drives. So
`containsOnlyVirtualWindows` could never be true while the Finder was adopted, on
any machine, by construction. It was found during the foreground window
experiment that ADR 0012 records as withdrawn, and it is not that experiment's:
the automatic recovery this ADR governs had the same false positive, and this
section stands whether or not anything else from that work does.

A row whose `kCGWindowLayer` is at or below `CGWindowLevelForKey(.desktopIconWindow)`
is therefore excluded when the snapshot's window list is read. The reason is not
convenience: a window at or below that level is behind every ordinary window,
the person's own included, so it cannot be on top of their work, and being on
top of their work is the whole of what the containment rule protects against.
Excluding it does not weaken the rule; it makes the rule mean what it already
said.

The exclusion is by level, asked of the system through
`WindowServerProbe.desktopIconLevel`, and never by owner name, window title,
size or any other heuristic. A row with no layer key is not excluded: absent is
not evidence of depth. An excluded row does not make the listing incomplete,
because nothing failed to read.

It applies to every predicate built on that list, which is deliberate and was
verified rather than assumed. `containsUserWindow` looks the destination up in
the same list, so a desktop window can no longer be found there and a
restoration whose destination is the desktop is refused instead of made. Before
this, the desktop of a physical display satisfied every clause of that predicate:
it has area, it does not intersect the virtual display, and it is on a physical
one. `containsAdoptedWindows` is untouched and still requires each adopted window
to be inside the virtual display; an adopted window that was itself excluded
would fail it, which is the fail-closed direction.

The guarantee is the shipped reader's. A custom `SeatSensing` that builds a
`FocusRecoverySnapshot` through the public initializer supplies window
references, which carry no level, so it can still place a desktop window in the
evidence. That is the same boundary as `windowsAreComplete`, and the same rule
applies: a custom conformer is responsible for the evidence it declares.

No other guard moves, and no budget changes. The live run above is the evidence
for what Window ID 39 is; the behaviour of the change itself is pinned by an
offline row and its mirror, an ordinary window at level 0 outside the virtual
display, which still refuses.

## A sheet is observed and driven through its host (2026-09-18)

Measured on 26A5425a with Slack adopted. Opening the attach-file panel moved the
capture filter from the host window 45288, 1333 by 949, to the "Open" sheet
46128, 933 by 490. `SCContentFilter(desktopIndependentWindow:)` aimed at an
`AXSheet` delivers the **host** window's pixels scaled into the sheet's
rectangle with black padding down the right-hand side, and both the
ScreenCaptureKit attachment and `SeatFrame.fallbackGeometry` declare the content
rectangle to be the whole buffer, so no reader downstream can tell. The panel's
own controls live in the host's accessibility tree at true screen coordinates,
so a point chosen on that picture and converted by
`FrameGeometryObservation.screenPoint(fromPixelPoint:)` maps proportionally into
the sheet's rectangle and lands hundreds of points away. The black band and the
dialogs that ignored clicks are the same defect.

The same run showed the second half. The sheet is a member and a candidate, its
`AXModal` is unreadable and its role carries the fact, and the modal relation it
declares is scoped to the host's window. The host therefore stops being a
candidate, and the seat read that as the target being gone: the session followed
the sheet, emitted `targetChanged` with reason `detected`, and every Command
already decided on the host was refused mid-action as "the observation is no
longer current". The seat also adopted the sheet as a window born on the Virtual
Display, recording the frame it was born at as what it owes the person on its
return, and gave it the host's platform, which addressed Chromium's activation
and key-window preparation to a native AppKit panel.

Five rules follow, and none of them is a guard at a call site.

**A window-scoped modal is observed through the window it blocks.** When the
selected surface declares a modal scope of `.window(host)` and the seat holds a
record for that host, the capture is aimed at the host, and the geometry the
observation carries is the host's whole rectangle. The Observation Reference
names the host as the observed surface and carries the new role
`ObservedSurfaceRole.hostedSheet(sheet:)`, so it still says which surface the
consumer is operating. The picture is honest: a consumer computing
`InputLocation(pixelPoint:observedIn:)` on it obtains a true screen point,
because the rectangle it is converted through is the one the pixels are of. A
modal whose host the seat holds no record for keeps its own picture; there is
nothing better to aim at, and substituting a window the seat cannot address
would be worse than the band.

**The window under the point is the recipient.** A point anywhere in the host's
picture is admissible. The sheet is a separate window server window drawn inside
that rectangle and an event routed to the host does not reach it, so the
recipient is decided per Command: the sheet when the Command's first mouse point
is inside the sheet's current window server frame, the host otherwise. The
Command is re-expressed and never recomputed (the same screen point, the window
point measured from the sheet's origin, which is what the routed process reads),
and a gesture belongs to the window its first point is in, the way a real drag
belongs to the window that received its press. A later point outside that window
is refused by `WindowCoordinateValidator` exactly as it is for the host.
`InputEngine` is unchanged: it re-reads the recipient's geometry immediately
before its first post and compares it with `requireUnchanged`, so a sheet that
moved between the reading and the post refuses instead of being clicked where it
used to be.

**A detection never retargets the session.** `operatingTargetStoppedQualifying`
answered true for a target that was only modally blocked, which is how the
session ended up on a window the consumer never operated. A modal block is not a
target that is gone: the window comes back the moment the sheet closes. The two
legitimate moves are unchanged, the consumer's own `switchTarget(to:)` and the
takeover after the current target is proved gone on closure evidence. The
observation and the admission cannot diverge over this, because both are keyed
off the selected surface and both pass it through the same
`observationPicture(for:)`; the sheet is reached through the host's picture
rather than by moving the session onto it.

**A sheet is owned and owes nothing back.** `AdoptedWindow` gains
`owesNoReturn`, decided once at the adoption from the accessibility evidence
that was current then and never recomputed, because after the host closes
nothing can say any more what the surface used to be attached to and that is
exactly when a handback asks. `AssignedSurfaceInventory` carries the matching
fact for the member and keeps it out of `heldMembers`, which is what `release`
turns into the return obligation. So the seat holds a record and a platform for
the sheet, `releaseAssignedApplication` is not refused over it, and no return is
opened for a surface that has no place of its own in the User Seat and cannot be
placed anywhere its host is not.

**A sheet is AppKit's, whatever drew the host.** `platformForDetected` gives
`AppKitPlatform` to a surface the accessibility tree declares a modal attached to
one of the application's windows. The role is the evidence and the size of the
surface is not consulted at all: an `AXSheet` is a fact of AppKit's own window
machinery, and a toolkit that draws its dialogs itself publishes them as ordinary
`AXWindow` rows rather than as a sheet of another window. Slack is the case that
proves it matters, because its open and save panel is a remote AppKit view inside
a Chromium host.

The pixel behaviour of the parent capture with a real sheet is the one thing
none of this verifies. The reading above is the evidence for what the filter
does aimed at the sheet; that aiming it at the host delivers the host's own
unscaled pixels while the sheet is up has not been measured, and neither has a
click routed to a real `AXSheet` window number. Everything shipped here is
pinned offline, by the unit tier. No live, Host or manual run was performed for
it, and the Live matrix for the observation adapters is still pending.

## The closure of a dialog is an episode with evidence of its own (2026-09-19)

A Command aimed at a modal surface can close it, and closing it is what takes
the person's focus. Everything the recovery needs to give it back is readable
before that Command and unreadable after it, so a closure now opens an episode
of its own, before the post, on the preparation the driver builds immediately
before the post: the person's window and its attested identity and serial
number, the surfaces the seat holds, the processes that may cause the steal,
the preparation generation, and one monotonic deadline. Nothing it goes back to
is learned afterwards. A destination discovered after the steal is the driven
application's own activation dressed as the person's choice, which is what
sending the focus "back" to whatever is in front would amount to.

The measured run this answers: a closure returned the focus in 17 ms with the
verification complete at 46 ms and the restore call at 11 ms, and a second
activation 32 ms later was refused because the episode's one attempt was
already spent. Another closure left the seat waiting about 107 seconds. Those
are the kit's own report and not an independent sampling, and 11 ms is over the
8 ms this ADR requires per call: it is a measurement, not a pass, and the
figures above are evidence of the defect and not constants anywhere in the code.

**A preparation attempt and a request are two counts.** The episode used to
raise one flag, and it raised it before the request path knew whether a request
could start: a stale preparation or a stale inventory then spent the whole
budget without restoring anything, and the seat waited for a person who had
done nothing. A request is now counted where the restorer is invoked. A call
that throws, or answers a non-zero code, still counts, because nothing here can
prove the focus did not move.

**A refused preparation may be renewed with the gate closed, and only that.**
Rebuilding the ordinary way requires the person's application to be frontmost,
which after the steal it is not, so the rebuild would refuse for the reason it
refused the first time. The reconciliation keeps the destination, its identity
and its retained serial number, and verifies that the same window is still
there. It refreshes only the adopted set, the retentions and the window server
snapshot. It never derives the person's focused window again, never learns a
destination from whatever is active, and never substitutes an owner whose
retention is gone: when the original destination is not the window it was, it
answers nothing and the seat waits for a real choice. It is bounded by the
transition's deadline and by its own count.

**The set the Command changed is reconciled before it is validated.** An ID
that is gone from the adopted set during a closure transition is the effect
that was asked for — the panel, and the nested dialog that was above it — and
not evidence that went stale. Nothing is relaxed in the other direction: every
surviving window must still be the same window at the same place, a window the
preparation never saw still disarms the transition, and `containsAdoptedWindows`,
`containsOnlyVirtualWindows` and `windowsAreComplete` are untouched, so a real
window out of place stays an obligation instead of becoming a pass.

**The budget of this ADR changes in one row, and only inside this episode.**
The table above reads "automatic attempts: one per Turn, or per complete
delivery/containment operation outside a Turn". A closure transition may make
**at most two**, and it keeps the count across the verified return in the
middle of it: the first steal is answered, the person's window comes back, and
the application takes it again a moment later, which is a distinct activation
that the episode had nothing left for. The second request is not a licence and
not a retry of the first: it needs evidence that is valid again, it is refused
while the request it would repeat is still unverified, and the consumed
snapshot is never reused. A third is refused. Two is a **proposal to be
qualified** by the live campaign, exactly like every other figure in that table,
and nothing here was measured live.

**Two more limits, so this can never become a fight.** The transition carries a
whole-transition deadline, which is the preparation lifetime its reconciliation
may renew plus the verification window of the last request it may make, and is
those two rather than a third number. Past it nothing automatic asks again and
the report says `unrecoverable`, naming the elapsed time, the requests made and
the last refusal. That is a precise end and not a stopped seat: the person
coming back still ends the episode and reopens the gate, and the explicit panic
is still theirs to press. And after the dialog's accessibility surface
disappears the episode keeps a short protection, because an Electron panel's
completion is deferred and two readings taken an instant apart can both catch a
focus that is about to be taken again; inside the protection two agreeing
readings end nothing, and the episode closes only when they still agree at the
end of it. The protection is the same 250 ms as the verification window because
it is the same question asked of the same two readings, and it is to be
qualified as well.

**A remote service is an actor, not a surface.** The process that draws a
hosted panel can take the front, and an activation nobody classified was being
read as the person choosing another application, which replaced the saved
destination with whatever that process had. Its serial number now joins the
destination's and the targets' when the transition opens, so its activation is
read as the application's. That is the whole of it: nothing is adopted or
attributed by being in that set, only surfaces descending from the relation the
seat has already attested are passed, the service's other windows are not the
seat's, and an activation that classifies as neither the person nor the seat
leaves the saved destination alone and the gate closed.

**The post, the dialog's effect and the recovery stay three facts.** A Cancel
that went out stays out while the recovery is still running; the recovery posts
nothing, repeats nothing and queues nothing, and the rule that no Command is
replayed is unchanged. Verifying the dialog's effect is the consumer's, and the
seat's report says only what the seat saw.

**The panic closes the gate first.** It used to reach the gate only through the
teardown, which a run in flight is given a bounded moment to unwind before: for
the whole of that moment the gate was open and whatever the run tried next was
admitted. `AgentSeat.stopAdmittingCommands` closes it with its own terminal
cause, `deliberateStop`, which nothing resolves, and it is deliberately not on
the focus lane: it activates nothing, returns no window and takes no display
down. The Command already admitted stays atomic, so a key or a button that is
down still gets its release; the gate stops the next one.

The containment exception is reused unchanged: a restoration to the prepared
and attested destination may be requested while windows are still to be
transferred, with the gate closed throughout, and a recovered focus reopens
none of the other causes of the gate. Every guard above it is the one that was
already there. No live, Host or manual run was performed for any of this; it is
pinned by the offline unit tier, and the Live matrix is still pending.
