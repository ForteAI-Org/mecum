# ADR 0017: A window taken in place may settle at a new size

Photoshop 27.10.0 on macOS 27.0.1 (26A434) exposed a Save prompt that changed
its WindowServer size during adoption. The prior confirmation compared every
reading with the first appearance. A smaller frame was treated as a Stage
Manager thumbnail and staged at the old size. The prompt refused AXSize;
confirmation and rollback then failed the Seat.

An in-place adoption may accept a different body only with fresh AX geometry
bracketed by two WindowServer readings of the same full identity. Both server
frames must agree and both sources must be contained in the Virtual Display.
The AX/server comparison keeps the existing cross-source tolerance. Two
successive confirmation rounds must agree on server geometry and the full body
within the existing placement tolerance. Missing or changed identity remains
a refusal. There is no wider tolerance or fixed Photoshop dimension.

A smaller server frame whose AX body is still full size remains a thumbnail
and takes the existing staging path. A stage request does not establish that
the thumbnail became the full window: confirmation still requires the fresh
server size to agree with the body on two successive rounds. A stable
thumbnail after staging exhausts the same confirmation budget and rolls back.
An adoption that moves a physical window
retains its original frame and resize obligation. Explicit restoration frames
and fullscreen provenance also retain their existing obligations.

If the body changed during an in-place adoption without a physical frame being
borrowed, the confirmed AX body and matching server frame become its return
destination. Retaining the transient birth size would require an unrequested
resize and could make a read-only-size modal impossible to release. The record
preserves identity, title, original display and attached-host provenance.
The operational size and staged classification use the same confirmed body.

Pure regressions reproduce the old adoption and release failures, verify no
move or resize for a naturally settled modal, and distinguish a thumbnail
with a disagreeing AX body. The 55 follow/adoption/rollback checks passed on
2026-10-03. Live Photoshop results and remaining limits are recorded separately
in [UXP.md](../UXP.md). This is a shared placement rule; it does not qualify any
other application's input behavior.

## A held sheet that grows in place (2026-10-05)

TextEdit's Save sheet, held beside its document window, widened from 390 to
about 891 points when its disclosure was pressed. The guard stays on the host
for a surface that owes no return, so every Command on the sheet read
`geometryChanged` from the sheet's record, sent a recovery episode after a host
that had not moved, finished, and left the record at its adoption size: the
next Command looped the same way.

Before input, a surface that owes no return and whose only Issue is
`geometryChanged` takes its current window server frame as its operational
geometry when that frame keeps its identity, lies inside the Virtual Display
and the host the guard watches reads no Issue. The Command that found it is
refused without a recovery episode, because its observation predates the
accepted frame; the next observation is admitted. A host that moved, a sheet
outside the display or any other Issue keeps the existing report and recovery.
`SheetGeometryTests` reproduces the loop offline; no live run was made.
