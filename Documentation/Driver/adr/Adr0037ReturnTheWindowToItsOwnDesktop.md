# ADR 0037: Return a window to its own desktop, and say when it is not

Status: implemented, 2026-10-09. Measured on the app path on macOS 27.0.1
(26A434) with the built-in display's two desktops; the external-display case is
prepared and not yet run (see Verification).

## Problem

With more than one desktop (Space) on a display, a window the seat took comes
back on the wrong one, and then no public window list names it:

- A window the seat finds already inside the Virtual Display when it first owns
  it ("taken in place": TextEdit's other documents, measured with 14 of them on
  the external display) recorded the Virtual Display's frame and display as what
  it is owed. Its return was a no-op at that place; when the display went away
  macOS put it on the first desktop of the main display, not the current one.
  It was off screen, absent from `AXWindows` and from the broker's window list,
  while teardown reported `returned`.
- `returned` only ever meant "the frame agreed twice". A window at the right
  frame on the wrong desktop was reported as home.
- A window the person left on a non-current desktop is invisible to every public
  list, so `open_session` waited 20 s and said the application "showed no window
  ... brought to the front", which is false and unhelpful.

## Decision

**What is recorded, and when.** Every window of the application that is on
screen and outside the Virtual Display, with its place: the accessibility body,
the window server's rectangle (only when it describes that body, never a Stage
Manager thumbnail), the physical display and the desktop (`WindowOrigin`, held
by `AgentSeat.physicalOrigins`, dropped with the assignment). The reading has
to be taken **before the Virtual Display is created**. Measured with TextEdit
and an external display (2026-10-09, a second run after the first fix failed its
acceptance): a reading taken inside the seat's first adoption, 70 ms after the
display was up and before anything of the seat had moved, found no window of the
application outside the Virtual Display, the target included, and the handover
reading then found the other fourteen already contained in it. So the display's
creation and topology transaction had already moved the windows, and the
fourteen were taken in place at the Virtual Display's frame, display and
desktop. The target's desktop, read at that moment, was the Virtual Display's,
and its return then failed its own check as "on another desktop".

So `SeatDriver.adopt` reads the places (`WindowOrigin.readBeforeHostStarts`)
before it starts the host and hands them to the seat (`AgentSeat.noteOrigins`).
A caller that brings none still gets the seat's own reading before its first
move, which is enough when nothing moves windows earlier. A place read earlier
is never replaced by a later reading of the same window.

**Who owes it.** A window owes its recorded place when it is inside the Virtual
Display or still at the recorded rectangle, the target included. A window found
anywhere else outside the Virtual Display was moved by the person after the
reading and owes where it is. The desktop of a window with no record is read
where the window really is (not at the rectangle the seat was handed) and is
left unknown inside the Virtual Display. A window with no record that is found
inside the Virtual Display, such as one an application restored there while the
display was still up from an earlier session, has no place in the User Seat
that anything can name: it owes the frame it is found at, as it did before this
ADR, and is not claimed to be home on a desktop. An unreadable window list
records nothing and the old behavior stands.

**The return rule.** Unchanged in mechanism: `AXPosition` at the recorded
frame, on the recorded display. The seat does not need to write a desktop for
this to be enough where it was measured (built-in display, below). The pure
`SpaceReturn.target` names the desktop owed: the original while a display still
lists it; if it is gone, the current desktop of the original display; otherwise
unknown.

**The verification.** After the two agreeing frame readings, the desktops of
the window are read, twice in agreement. Only then is the outcome `returned`.
A window on another desktop is `WindowReleaseOutcome.returnedToOtherSpace`:
back on its display, not on its desktop, nothing more the seat can do. The
desktop follows the frame a moment later, so a window that reads elsewhere is
read again until a budget of one second shared by the whole release is spent,
which keeps a stuck window from costing a wait each. Outcomes:

- `returnedToOtherSpace` is home for the seat (`SeatDriver.isHome`, no
  obligation, no retained display) and is named to the person: the run's notes,
  the close warning and the teardown sentence say that the window is back on its
  display but on another desktop and that the seat does not move windows between
  desktops.
- A desktop that cannot be read (symbol missing, layout unreadable, never
  recorded, native fullscreen window) leaves the return as the frames proved it
  and says "its desktop is unknown" in the log. It claims nothing about the
  desktop.
- A cancelled or out-of-time verification is `refused`, as the frame step is.

**No desktop writes.** The kit only reads desktops. No window is moved between
desktops, no desktop is switched, no input is posted and nothing is activated.
Moving a window to a desktop would be a private write with a larger blast
radius and no way to prove it landed anywhere the person wants.

**Another desktop on open.** `SeatBroker.launch`, for a running application the
on-screen list shows no window of, reads the desktops of its remaining windows.
When one exists on a desktop no display shows, it answers at once with
`SeatBrokerError.windowOnAnotherDesktop`: "<App>'s window is on another desktop:
bring it to the current desktop and ask again." It does not ask the application
for a window and does not wait. It answers nothing when the desktops cannot be
read.

**Private symbols.** `SLSCopySpacesForWindows` and `SLSCopyManagedDisplaySpaces`
are read-only. They are `PrivateSymbol` cases behind the `windowSpaces`
Facility, which is not one of the four baseline Facilities, like
`remoteWindowGeometry` and for the same reason: they are not promoted into the
build ledger. The ledger carries two `untested` rows for them
(`Sources/Driver/PrivateSymbols/Ledger/validated-builds.json`), and
`SpiLedger.md` lists them. Promotion stays a maintainer decision
(`make promote-build`). Both resolve on 26A434 (the CGS twins were read in the
phase 1 measurement; the SLS spellings used here were read in the runs below).

## Consequences

- A seat that took windows in place gives them back to their frame and display;
  with one desktop per display nothing changes.
- A window the seat cannot bring back to its desktop is reported, not hidden.
- A deferred return (`returnsWhenShown`, `HiddenWindowReturns`) is not verified
  against the desktop: it happens when the application shows the window, outside
  the release.
- The verification costs about 50 ms a window, and up to the shared one second
  when windows stay elsewhere.

## Verification

Pure tests: `WindowOriginTests` (the reading, a pulled target and others that
return to their display and desktop, a moved window, the earlier reading wins),
`DesktopSpacesTests` (original present, gone, unknown; verdicts; a
window on another desktop), `WindowSpaceProbeTests`,
`AssignedSurfaceInventoryTests`, `SurfaceRestitutionTests`,
`PrimitiveRequirementTests`. Seat tests: `WindowSpaceReturnTests` (outcome
`returned`, `returnedToOtherSpace`, closed desktop, unreadable desktop, late
desktop, shared wait, a window taken in place keeps and returns to its origin).
Broker tests: `WindowOnAnotherDesktopTests`.

Live, app path, built-in display only, scratch fixture app with three windows
in two modes. In the first one window moves the others onto the Virtual Display
when it moves, which is what TextEdit's documents did: before the change two of
the three windows came back on the first desktop, off screen; after it all
three came back to their frame on the current desktop. In the second the
fixture pulls all three windows (the target included) into the Virtual Display
the moment the display appears, which is the order the external-display run
showed. One fresh display per run: the baseline failed 3 of 3 (target and one
window on the first desktop, off screen), the first fix failed 5 of 5 (a false
"another desktop" on the target and windows left on the Virtual Display, with
the seat's own reading finding none of them in 2 runs), and this one passed 6
of 6, in 3 of them with the seat's own reading finding none and the broker's
reading, taken before the host, supplying all three. An application whose only
window is on the first desktop answers the message in about 0.5 s and nothing
moves. The same case with TextEdit on the external display is prepared and not
run: it needs that display free.
