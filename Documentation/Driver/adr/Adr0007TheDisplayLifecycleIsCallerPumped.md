# The virtual display lifecycle is driven by the caller's event loop

`VirtualDisplay` is a `@MainActor` class, not an `actor`, and it has no method
that waits for the display to appear or to go away. `create` and `invalidate`
return immediately; `isRegistered`, `appKitScreen` and `isOnline` are the
predicates, and the caller polls them **while turning its own application event
loop**.

## Context

Spec section 7 lists `VirtualDisplay` among the actors. Measurement on 26A5425a
made that shape unbuildable, in two steps.

**A virtual display only makes progress while `NSApplication` pumps events.**
Not a `RunLoop` turn: `RunLoop.current.run(mode:before:)` with
`finishLaunching()` already done leaves the second display of a process forever
inactive and never publishes an `NSScreen` for it. It has to be
`nextEvent`/`sendEvent`. That is true of the AppKit registration, of the
CoreGraphics one, and of the removal.

**A wait that blocks therefore never ends, and a wait that suspends ends the
process.** A blocking wait inside `create` holds the thread that would have
pumped, so the display never becomes active. Making the wait `async` instead
returns the thread to the concurrency runtime, and on an `async` main, that
runtime's own drain loop then decides the program is over and calls `exit(0)` in
the middle of the run: reproduced at the third consecutive creation in the
benchmark, and in the test process it took the whole run down with a green exit
code and no report.

The lifecycle is therefore not something a library can own on the caller's
behalf. Only the caller knows how it pumps: an application has
`NSApplication.run()`, a benchmark and a test harness drive `nextEvent`
themselves.

## Decision

- `VirtualDisplay` is `@MainActor`, which is where the `NSScreen` registration
  and the display configuration transaction have to happen anyway, and where a
  `SeatHost` already lives (spec section 7).
- `create` builds the surface and returns. It does not wait for CoreGraphics.
- `invalidate()` drops the private object and returns. There is no `remove()`
  that waits.
- `configureTopology()` refuses with `notRegistered` when it is called before
  the display is published, so the mistake has a name instead of a `CGError`.
- The waits belong to the caller and are documented at `invalidate()` and at
  `ScreenRegistration`.

## Consequences

The Seat Host of phase 7 owns the pumping question, which is right: it is the
component that has a run loop. A consumer that cannot pump cannot own a virtual
display, and it should find that out from a timeout with a name rather than from
a process that disappears.

If a future need really wants the display off the main actor, the type becomes
an `actor` and the waits become `Task.sleep` again, and whatever drives them
still has to pump AppKit for the display to move at all.
