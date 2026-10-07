# ADR 0033: Explain what a pressed Command causes after its brief activation

Status: implemented for qualification, 2026-10-07. Offline tests only; no live
run. It extends [ADR 0013](Adr0013BriefActivationForStaleMenus.md) and
[ADR 0024](Adr0024DispatchAdmittedAdobeMenuBeforeHandback.md). The two-second
handback limit of [ADR 0023](Adr0023BriefHandbackVerificationLimit.md) is
unchanged.

## Evidence

Photoshop (PID 39362) driven through `menu "File > Place Embedded..."`, with
Mecum (PID 66737) as the person's application. Times are milliseconds from the
`menu` call. The command opens a native file panel, a window of Photoshop at
layer 8 that is born on the person's display, and Photoshop takes the front for
it.

- **Failure.** The brief activation held the front 1023 ms and the handback was
  verified in 40 ms, with the person in front at 1053. Photoshop retook the
  front by itself at 1111, before the panel existed. Its focused window became
  the `AXDialog` "Open" at 1568, and the window server row of panel 30776
  appeared at 1782, 730 ms after the handback, on the person's main display.
  The seat went `waiting` at 1161, reading Photoshop's activation as the
  person's (target re-activation 58 ms after the handback). The follow pass then
  refused the panel: `seatNotReady(waiting)`. A "Start Bar" window of Photoshop,
  born on the virtual display, was refused for the same reason. The seat stayed
  suspended and every observation failed with `surfaceOutsideSeat`.
- **Spurious waiting.** In another run the activation lasted 133 ms and the
  handback was verified in 293 ms. The person had the front from 172 ms and
  Photoshop never held it again. At about 590 ms, about 300 ms after the
  handback, the seat still went `ready -> waiting` on `targetActivated`
  ("No prepared action was held when this activation arrived", source
  `workspaceNotification`). That is the command's own activation notification
  arriving late. It recovered at 1923 ms and only then took the panel in.
- **Controls.** A third Place Embedded run and the Image Size control runs
  verified the handback, opened the panel after the person had the front, kept
  the seat `ready`, and the follow pass moved the panel in. They must not change.
- At the press, the focused and main window of Photoshop were the document on
  the virtual display in all runs, so the priming of ADR 0013 is not involved.

## Decision

### The Command Provenance record

A brief activation that presses an admitted command (ADR 0024) opens a
**Command Provenance** record, `CommandProvenance`, owned by `UserFocusRecovery`.
It holds the target's attested process identity, the target's on-screen window
numbers read immediately before the press, the press instant, the handback
instant and the person's window the front goes back to. It is per Command and
per brief activation. It is not the per-assignment `SurfaceOrigin
.bornDuringAssignment`, which says a window was born while the application was
assigned and nothing about which Command caused it.

It is valid from the press until the handback plus
`CommandProvenance.marginNanoseconds`, 1.5 s. The measurement is a panel row 730
ms after the handback, a re-activation 58 ms after it and a notification about
300 ms after it, so 1.5 s is twice the longest, a figure to qualify live. A
press that the seat refuses opens no record, and a failed pre-press reading
leaves the record unable to call any window new.

Every window of the target first seen while the record is valid, and absent from
the pre-press reading, is a sighting with its level, display and instant. Each
one writes one `.notice` line: window number, owner PID, layer, display and
milliseconds since the press. Sighting moves nothing.

### Lever A: an activation inside the record is the Command's effect

An activation of the target process that arrives while the record is valid,
whether the command's own workspace notification arriving late or the target
retaking the front for a window the Command opened, is not the person's. It
raises no `targetActivated`, closes no gate and opens no episode. The ordinary
paths are unchanged: an activation outside the record's validity, one of another
process, the context menu poll and the handback the seat itself judged
unverified.

When the front is not with the person, the record allows at most **one** new
handback attempt, shared by every trigger so two can never be made. It is made
after a window of the Command has been taken in, or when the margin ends with a
window of the Command seen. If the margin ends with the target still in front
and no window of the Command seen, or the attempt was spent or is not verified,
the target's activation is read as it always was: `targetActivated` and
`waiting`.

### Lever C: a window the Command opened is admitted while the seat waits

`mayAdmit` and the follow pass's scope admit a window while the seat is
`waiting` when all of these hold: its owner is the target process with attested
identity, it is a sighting of the record (so it was absent before the press and
first seen between the press and the end of the margin), it is at the modal
panel layer 8 or the selection nucleus attests it as a dialog, no focus request
is in flight, and the `waiting` episode began while the record was valid. Any
other window is offered again and left where it is, and a `waiting` that a real
activation of the person produced, before or after the record, still refuses
adoption. A seat that waited on that episode goes back to `waiting` after the
adoption, and the person's focus ends it as before.

Admission is by the nucleus' dialog attestation, not by reading an AX subrole in
the pass: a window that is neither at level 8 nor already attested as a dialog
is not admitted.

### Settling

The margin is settled by a task of the recovery when it ends, and by the seat
when it takes in a window of the record. Settling first reads the
target's windows once more and sights any new one as seen at the margin's last
instant, because the follow pass can be busy with another transfer and miss a
panel that appeared inside the margin. The follow pass runs at its anticipated
cadence through the margin after such a press, so a panel that appears late is
seen.

## What this keeps

The command is never re-sent. No window of another process and no window that
existed before the press is adopted. The handback verification limit stays two
seconds. No foreground input, no global HID event and no AppleScript is used.
The one extra handback uses the primed restorer the first one uses.

## Messages

The suspension clause for a window left on the person's screen said that closing
it there clears the suspension. It now says the seat takes it in, because the
seat does and the person is not asked to close the panel. The post-dispatch
observation failure message has one point per sentence. The tool layer's
"Observe before any retry." is unchanged, and the worker notice of ADR 0032 is
left for its own decision.

### The verdict of a Command whose return is verified late

The brief activation of a panel-opening Command answers `handbackNotVerified`
because the panel is born during the handback, yet the extra handback above
verifies the return about a second later, before the tool answers. The `menu`
tool already observes after dispatch and attaches the scene, so it reads, after
that observation, whether the front is back with the person
(`AgentSeat.frontIsBackAfterCommand`): the extra handback of the record was
verified, the recovery is not paused and the target is not in front. It is a
read of what the seat already knows; it sends no input and asks for no front.
When it holds, the outcome is the ordinary window verdict, `foundActed` or the
"no window opened" `actedUnverified`, with the scene. When it does not, the
outcome stays `actedUnverified` with the scene, says the seat accepts no input
until the front is back with the person's window, keeps "Do not repeat it
blind." and no longer asks for an observation, which would cost the tokens of
a scene the outcome already holds. The observation-failure message is unchanged.

## Left to decide

The margin is a first value. A person who really switches to the target inside
it is read as the Command's effect, and the extra handback would take the front
from them. The record has no way to tell the two apart, and the measurement has
no case of it. Reading the AX subrole of a window in the follow pass would widen
admission to dialogs that are not at layer 8 and not yet attested, and nothing
here measures one.

## Verification

`CommandProvenanceTests` pin the record: another process, a reused PID, a window
present before the press, an unreadable pre-press reading, a window first seen
at and after the margin, and the notice line. `CommandBornWindowTests` drive the
seat over the fakes: a late notification inside the record, the retaken front
with a late panel and exactly one handback, the margin ending with the target in
front, an activation outside the record, a failed handback with the panel present
adopting it and retrying once, only the Command's own panel admitted while
waiting, a window first seen after the margin refused, a panel that appeared while the
follow pass did not run being sighted by the settle read, and the read of the verdict only
after a verified return. `MenuBarCommandTests` pin both verdicts. Offline only: no live
run was made, so the measured Place Embedded sequence is not reproduced.
