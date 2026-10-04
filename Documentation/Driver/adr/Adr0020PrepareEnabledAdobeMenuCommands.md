# Prepare an enabled Adobe menu command before dispatch

Implemented for qualification on 2026-10-04. This extends
[ADR 0013](Adr0013BriefActivationForStaleMenus.md) for an enabled Adobe command;
it does not establish live coverage of other UXP hosts.

## Evidence

On signed Release Mecum `6f6c08ac`, three declared Photoshop New Document
workflows adopt the correct document and resolve File > New... as enabled.
Each AX press acknowledges delivery, but the following scene and window list
remain unchanged. The Window menu retains the same four owned documents;
each session closes cleanly. No Return commit is reached. An earlier scoped
pre-menu preparation produced visible modal editing effects, but later cold
commands still require complete workflow qualification.

The existing refresh only runs for a disabled item. A positive enabled state
therefore cannot rule out this observed lack of vendor command preparation.
The candidate asks the existing Seat operation to prepare an enabled command
before its first and only dispatch. Whether it closes this Photoshop failure
must be established through the rebuilt app.

## Decision

Only a command admitted by menu resolution in an application classified
`adobeUXP` requests preparation. A menu listing, a missing path and a hiding,
system or unauthorized destructive command request none. Disabled Adobe
commands retain the existing refresh path.

Preparation uses `AgentSeat.bringTargetBrieflyInFront`: an identity-bound
target, an expected activation, the existing deadline, and verified handback.
A refusal or an unverified handback dispatches nothing. On readiness, the menu
is resolved again, so an old AX item cannot authorize a changed command. A
newly disabled item refuses without a second preparation. No acknowledgement
is treated as a verified effect; the following scene and window evidence still
decide the command's outcome. An unconfirmed dispatch is never replayed.

The native menu adapter and controlled tests share the same orchestration.
The compiled regressions fail before preparation with 18 assertion issues;
they cover the current item, all preparation refusal cases, listing/destructive
exclusions and an item disabled after readiness. Existing non-Adobe callers
keep the default policy.

### Foreground readiness and scoped key preparation

The first Release repeat (`76dda26d`) still has no command effect. Its native
brief-activation log reports readiness after 100.1 ms while the foreground
remains Mecum. An enabled menu predicate was evaluated even though Photoshop
had never held foreground. This is a false readiness result, independently of
the later command's effect.

Readiness now requires an observed target foreground, and the polling deadline
and cancellation are checked again after its wait. The existing destination
key preparation is selected only for brief activation and its verified
handback. Both requests consume the same fully attested destination used by
ordinary restoration. Ordinary focus recovery retains its configured policy.
No caller may dispatch merely because the activation request acknowledges.

Three compiled regressions cover an acknowledged request that never activates,
an elapsed deadline before the predicate, and the scoped target/handback
restoration route. Native command and foreground effects still require a
rebuilt-app repeat; the controlled regressions do not establish either.

Release `3aa20a1c` reaches a positive server foreground witness, but its native
log reports a return to Mecum's process without the expected window being
verified. The menu still has no effect; the four owned documents are unchanged,
the session closes with null status, and Mecum remains visible without an
external rescue. This is a failed diagnostic, not acceptance.

Readiness now requires agreement between the server witness and workspace
activation. It rechecks both, the deadline and cancellation after the predicate
returns. A readiness result does not survive an unverified handback or a
different foreground chosen during that reading. No recovery request overrides
the person's different foreground. The original target retaining foreground
still hands its episode to ordinary recovery. The handback also rechecks its
deadline after waiting. These additional compiled regressions are required
before the next signed-app repetition.

## Qualification limit

This is a candidate correction until a fresh signed-app workflow proves its
effect and cleanup. It does not qualify Photoshop Return, exact Unicode,
editing, undo/redo, scrolling, other Adobe applications or OS versions by
itself. The local acceptance matrix retains the three original failures.
