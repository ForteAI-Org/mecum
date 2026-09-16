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
the Window ID, and the 0x200 mode bit. Runtime results and test scope are in
[the focus recovery experiment](../user-focus-recovery-2026-09-10.md).

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
See [the campaign](../focus-certification-2026-09-10.md) for measurement limits.
