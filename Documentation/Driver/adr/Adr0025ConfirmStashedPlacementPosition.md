# ADR 0025: confirm the requested position after staging a thumbnail

Date: 2026-10-04

Status: implemented; native qualification recorded in the stabilization rounds.

## Problem

On macOS 27.0.1, Stage Manager can publish two agreeing full-size window
readings before completing the move to the virtual display. A scoped
Calculator measurement records a 230×408 window at 2459,1374, the Seat's
ready transition, then the same identity and size at the requested 2677,1498.
The first command refuses with geometryChanged. Resolve also reproduces a
first-command geometry interruption after successful adoption.

Size, containment and agreement alone therefore do not confirm the end of
this staging movement. Extending the geometry guard's tolerance would admit
input at coordinates that the window no longer occupies.

## Decision

Before moving a window, record whether an attested WindowServer reading
positively identifies its size as a thumbnail of the complete body. If it
was a thumbnail, or confirmation itself needed staging, require the requested
position as well as the complete size before accepting two agreeing readings.
Use the existing cross-source frame tolerance because the requested body and
the WindowServer reading may differ by a few points.

Ordinary full-size windows and windows adopted in place keep their existing
confirmation contracts. The attempt remains bounded by the existing placement
deadline. Failure rolls back through the existing return obligation; no input
is posted to finish placement and no command is replayed after a refusal.

## Verification

Controlled regressions hold several readings at an intermediate full-size
position before allowing the requested position, and hold a staged window
at the wrong position until rollback. Existing panel, borrowed-identity and
handback regressions guard the scope. Full commands, unsuccessful attempts
and native repeats are recorded in
[stabilization rounds](../reports/StabilizationRounds.md).
