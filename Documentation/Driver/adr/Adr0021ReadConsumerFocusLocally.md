# Read the consumer's focused window locally

Implemented for qualification on 2026-10-04. This preserves the foreground,
identity and physical-visibility checks used by focus recovery.

## Evidence

Release Mecum `f73b09bd` observes Photoshop foreground readiness after 97.5 ms,
then fails to verify the return to Mecum's own window within 250 ms. The app
remains visible, a fresh scene retains the Photoshop document, and session
closure leaves null status. The command correctly refuses before dispatch.
This is not successful menu qualification.

The production focus reader sends an AX focused-window request even when the
foreground process is the consumer itself. Those calls run on the same UI
executor described by `SystemSeatSensing`. The candidate removes this own-process
request; a native repeat must establish whether it closes the observed failure.
No passing controlled test is claimed as proof of the native handback.

## Decision

For the consumer's own foreground PID, read AppKit's local key-window number
on the existing main-actor boundary. If there is no key window, return no
reading without a self-AX fallback. Do not raise, activate or choose another
window while reading focus.

For an external foreground process, retain the 50 ms AX focused-window reading.
Both routes resolve the number through WindowServer and require the same owner
and number. Recovery still checks the expected complete identity, physical
visibility, exclusion from the virtual display, and two agreeing observations
within its deadline. A local number alone never verifies handback.

The small selection seam is shared by the native reader and controlled tests.
Compiled regressions fail with four assertion issues before the local route is
selected. They require no self-AX request, no fallback on local absence, the
unchanged external route, and refusal of foreign or mismatched geometry. The
first test invocation was a compile failure in a method reference and is
retained separately from the compiled behavior failure.

## Qualification limit

The signed-app repeat must verify both the intended window and the command's
effect. This change cannot qualify a menu invocation, a modal return, another
OS build or an Adobe host by itself. The native failed diagnostic remains in
[the stabilization record](../reports/StabilizationRounds.md).
