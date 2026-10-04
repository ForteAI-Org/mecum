# ADR 0019: Qt return geometry is read at adoption

Status: accepted, verified on macOS 27.0.1 (26A434), PySide6 6.11.2.

## Evidence

An owned Qt fixture discovered before SeatHost creation reported a body at
`(1082, 776, 700, 652)`. With Stage Manager enabled, its body had settled to
`(812, 330, 700, 652)` by adoption. The old discovery reference still became
`originalFrame`. Release reached that old rectangle, returned to the virtual
frame, and refused after its bounded two-reading check. A prepared-return
control also failed. Driver move tracing showed only adoption and return
writes; Qt's native geometry notifications reported the reversal.

A control with a fresh adoption-time AX reference returned successfully.
The production fix also passes when the consumer supplies the original stale
reference, and three later AX readings retain the current home. User Seat
comparison and zero physical input pass; display and fence are removed.

## Decision

Explicit Qt adoption reads its current AX body before recording its return
obligation. Matching WindowServer identities bracket that read. A replacement
or missing identity refuses before placement. Readable invalid geometry also
refuses; absent AX geometry retains the existing placement route.

The body supplies position and full size. A Stage Manager thumbnail supplies
identity only. In-place adoption, an explicit restoration frame and a normal
frame already read after fullscreen exit retain their existing behavior.
The return still requires its existing agreeing server readings and exact
identity; no tolerance, repeat-input or physical-input fallback is added.

## Qualification

`QtAdoptionGeometryTests` verifies the current return frame and refusal before
moving a replaced identity. `make qt-geometry-live-tests` is the owned live
regression, requires Stage Manager already enabled, and supports a supplied
`QT_INITIAL_POSITION` for another physical geometry.

This records where ownership begins. It does not restore a position changed
before adoption or qualify all Stage Manager transitions, Qt versions or OS
builds. The current build remains outside the compatibility ledger.
