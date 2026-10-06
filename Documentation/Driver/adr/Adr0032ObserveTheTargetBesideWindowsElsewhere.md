# ADR 0032: Observe the target beside windows the seat cannot take in

Status: implemented, 2026-10-05. Offline seam tests only; no live run.

## Evidence

A worker run on DaVinci Resolve through Mecum, 2026-10-05. The kit log of
that run was not kept, so the paths below are read from the code against the
exact sentences the worker received.

- `Clip > Clip Speed > Change Clip Speed` was dispatched, and the observation
  after it refused: "whether window 7631 ... is visible did not decide". The
  observation five seconds later showed the main window; 7631 was never
  reached. The observation refused on every cause of the gate, including
  `visibilityUncertain` and every containment block of a member it would not
  have shown.
- A double click on an inspector value left no scene, and every later
  observation refused as `notAdopted` while the main window stayed on screen.
  The worker closed and reopened the session, twice. A window its application
  stops listing while the window server still shows it is closed after the
  one second grace of ADR 0010, and the record was dropped even when it was
  the operating target with nothing to take over. The borrowed `SeatTarget`
  then refused before the seat could observe, and the window follower never
  offers again a window it already knew.

## Decision

An observation goes ahead when every remaining cause speaks only of windows
it does not show: a visibility that did not decide, a window outside the
seat, absent from the last reading or not yet confirmed, a move refused or
spent, a surface deadline or stall, and the handover deadline that is their
sum. Those causes travel with the delivery (`causesElsewhere`) and each
observation reads them again.

The worker is told only about a window it can do something about: one the
window server shows on screen, outside the Virtual Display, which the delivery
carries as `shownOutsideSeat`. The broker names each by its window server title
and the role the seat read, and the sentence says to continue with the scene
and, if that window is needed, to ask the person to close it or bring it back.
A window its application hid or ordered out, one whose visibility did not
decide inside the seat and one missing from the reading give no sentence:
told about DaVinci Resolve's hidden Project Manager and Create New Project
dialog (2026-10-06) as "not confirmed visible yet", a worker stopped and asked
the person to close windows nobody could see.

Everything else still refuses as before: a modal block or doubt, a reading
that cannot carry the whole application, an attribution in doubt, and any
cause about the observed surface or a host its picture climbs to. A selected
window outside the seat that the seat could not take in still refuses, and the
refusal now says it is on the person's screen. Moves are unchanged: a window
with a qualified move is still taken in first, and attempts stay bounded.

A Command decided on such an observation is admitted as any other. That is
the new risk this accepts: input reaches the target while another window of
the application stands on the person's screen. The prepared snapshot of ADR
0010 is unchanged, so if the application activates meanwhile, the person's
focus is not restored automatically and the seat waits for the person.

An operating target its application withdrew, with no predecessor and no held
selected window to hand over to, keeps its record, platform and return. The
selection takes it back once it is listed again, and the record is let go
when another held window takes over. The borrowed `SeatTarget` observes a seat
that lost its target instead of refusing first.

## Left to decide

The seat does not fall back to the operating target when the application's
own focused window is outside the seat. Doing it pins the selection against
the application, and a window brought in a moment later would then never be
followed. The kit's coherent state still lists the causes elsewhere as
suspensions.

## Verification

`WindowsElsewhereTests` reproduce the three refusals, keep a blocking modal
refusing and give no notice for windows hidden by the application or undecided
inside the seat; two `AppWindowFollowTests` rows that asserted the suspension
now assert the named window. No live, Host or manual run was made.

## A small auxiliary surface does not ask for a choice (2026-10-06)

Twice in one minute on DaVinci Resolve, after a dialog closed, every
observation refused with "2 windows are equally plausible targets": the
project's window and a 66 by 20 point untitled `AXDialog` the system puts up
in the application's process (also measured in TextEdit). The document had
been selected as the only candidate, no recency was ever qualified, and the
small dialog made two candidates with no observed order.

The reader claims a non-modal dialog of at most 80 by 24 points a decoration,
which is never a candidate, so the document is again the only one. The size
is the only fact read that separates it, so it is marked as a size class to
replace with a native trait. The selection policy is unchanged: two candidates
with no observed order still ask, because preferring the current selection
would leave a real non-modal dialog reachable only by reopening the session.
`SmallAuxiliarySurfaceTests` reproduce both sequences offline; no live run was
made.

## A window the seat found and could not take in fails nothing (2026-10-06)

A drag from Resolve's media pool to its timeline made Qt put up its drag
image, 101 by 88 points at level 1000, at the real cursor on the person's
screen. The follower tried to move it; the move was never confirmed, the
rollback could not put back a window that follows the cursor, and the
adoption's refused rollback turned the seat `starting -> failed (cancelled)`.
The worker was then told to close the session, with no cause.

The follower takes only surfaces drawn below the pop up menu level; help tags,
drag images and screen-saver level surfaces are never moved or owned. A
detected window whose transfer fails, whatever the rollback answers, returns
the seat to its previous state, leaves the target and its observation as they
were, and keeps what the window is owed in the restitution ledger (the host is
retained) without holding up the next detection. A window the consumer adopts
and that can be neither taken in nor put back still fails the seat, and its
stop now names the window. `DetectedWindowRefusalTests` reproduce the sequence
offline; no live run was made.
