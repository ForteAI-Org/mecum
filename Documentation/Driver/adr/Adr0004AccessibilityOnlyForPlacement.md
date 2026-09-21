# Accessibility is used only to place a window

The kit's only use of the accessibility API is placing the target window:
`AXPosition` to move it onto the Virtual Display, `AXRaise` to stage it, and
`_AXUIElementGetWindow` to find the element for a Window ID. It never reads the
element tree and never acts on a control. Observation, semantics and target
resolution belong to the consumer, which reaches the kit with coordinates.

## Context

The research this kit comes from exists because accessibility is not a reliable
control surface: a standard `NSTextView` refuses a mouse selection from an
inactive window even when accessibility can set the same selection directly. The
project's rule is that private input primitives do the acting and accessibility
does not become an implicit fallback.

## What placement now writes, and what the observation half reads (2026-09-16)

**`AXSize` joins `AXPosition`.** An application can open a window larger than
the Virtual Display: measured on DaVinci Resolve, a project window 2593 points
across a 2560 point display, 33 points too wide. The window was refused, so it
stayed on the person's screen and outside the seat, and when the application
then closed the windows the seat held there was nothing left to hand over to and
the seat failed. Refusing it is not neutral: it leaves an agent driving an
application whose main window it cannot reach.

The write is bounded by the same rule as the move. It happens only for a window
that does not fit, only down to the display's own bounds, and only in the
dimension that overflows. It proves nothing by itself: an application with a
minimum size accepts the write and keeps what it had, so the window is read
again afterwards and a window that still does not fit is refused exactly as
before. What the person is owed does not change — the frame from **before** the
shrink is what the adoption records, and the return writes that size back before
the origin, because the return is verified against the whole frame and a
restored origin alone would never match.

This is still not a control surface. It moves and sizes a window; it reads no
control and acts on none.

**Reading is now wider than this ADR's first paragraph.** The observation
adapters read each assigned application's `AXWindows` and, per window, role,
subrole, minimised, modal and parent, to scope which windows belong to the
application and cross-check them against WindowServer. That is a window-level
reading and not an element tree of controls, and it decides nothing on its own:
every row it produces must also be attested by WindowServer. The table in
`../README.md` is the current record of which of those adapters exist and what
each one still owes the Live matrix.
