# ADR 0016: UXP keys with stale global focus

Trials on 2026-10-02, Photoshop 27.10.0 on build 26A434, exposed two refusals
on adopted, contained and captured surfaces. Displace or Duplicate Layer could
retain focus on a blocked document or expose no focused control. After a tab
switch, AXFocusedWindow could instead name an empty AXLayoutArea/AXUnknown
proxy while AXMainWindow named the explicitly selected document.

The Driver may qualify a destination to make key from a complete own-window
subtree. It never converts pixel selection into AX focus. The modal route
requires application modality or an explicitly selected standalone UXP dialog,
including AXModal=false. A stale-focus refusal must name another adopted window
of the same process lifetime, or explicitly lack a focused-window number. Every
node must name the selected dialog's Window ID and process. Remote, windowless,
unreadable and hosted modal trees refuse.

On 03/10/2026, a resized document's Stage Manager thumbnail fit geometrically
inside New Document while global AX focus still named that blocked document.
Containment had admitted it as remote content. Endpoint resolution now rejects
any recipient blocked by the logical modal as `recipientModallyBlocked`, and
the command boundary retires the same invalid relation. A complete own modal
proof may qualify its exact make-key recipe; geometric containment never
overrides modal eligibility.

The document route requires an explicitly selected standalone UXP document,
no blocking modal or sheet, and AXFocusedUIElement's typed absence. The focused
proxy must have the same PID, a positive different Window ID, AXLayoutArea role,
AXUnknown subrole, AXModal=false and a successful zero-child reading.
AXMainWindow must match the exact selected WindowServer identity. Its complete
own-window tree retains the ordinary proof's narrow exception for positively
inert, complete, windowless decoration. Foreign input-bearing descendants refuse.

Both readings use a 300 ms budget, 1,024-node limit and depth 64, with bracketed
identity/focus facts. Endpoints carry `unfocusedModalSurface` or
`mainWindowUnderFocusProxy`, without invented focused-node facts. Classification
requires only the recipient's make-key pair and configured settle, 300 ms by
default. No application activation record is included. Overrides omitting the
pair, choosing another window or requesting full activation refuse. Identity,
selection, geometry, eligibility and full proof repeat at the operation boundary
and after priming before the first post. Changed or unreadable evidence posts
nothing. Newly established ordinary focus on the same recipient can replace
the priming proof.

Other families and pointer commands retain their routes. Full AppKit preparation
remains explicit calibration; preparing Photoshop's blocked document previously
crashed its host in `_handleActivatedEvent:`. The ordinary UXP family therefore
prepares nothing by default.

The measured document editing recipe explicitly prepares a left canvas click
before its menu shortcut. Preparing keys alone could restore the zoom field
as first responder. `preparingLeftClicks` and `preparingKeys` are consumer
recipes on the selected unblocked document; they do not change modal inference.
Three-cycle native effects in UXP.md qualify only the named selection, pixel
and layer commands. No mouse-down offset or failing drag calibration is shipped.

Unit tests cover incomplete facts, eligibility changes and overrides. Native
rows in [UXP.md](../platforms/UXP.md) separately require effects and User Seat preservation.
Character shortcuts use the installed layout with no Unicode payload. Key 13
was comma on this Mac; negative hardcoded Cmd+W trials were harness errors.
This decision does not qualify other hosts, localizations, operating systems or
a shorter wait.
