# The Seat Host pumps the event loop only when nobody else does

`SeatHost` and `AgentSeat` wait through one helper, `EventLoopWait`. A caller
that already drives its own loop hands that function over
(`SeatHostConfiguration.eventLoopPump`) and the helper calls it; otherwise the
helper has one branch, when `NSApplication.shared.isRunning` the wait
**suspends**, and when nothing is running a loop the wait **turns the loop
itself and never suspends**.

A periodic background loop, the watchdog's heartbeat and the recovery's cadence,
uses the suspending form always and the pumping form never.

## Context

ADR 0007 established that a virtual display makes progress only while
`NSApplication` pumps events, that `VirtualDisplay` therefore has no wait inside
it, and that the waits belong to whoever owns a run loop. It left the question
to this phase in one sentence: "the Seat Host of phase 7 owns the pumping
question, which is right: it is the component that has a run loop."

Owning it turned out to mean choosing between two mechanisms that each break in
the other's context, and both failures were measured here.

**A suspending wait ends a process that has no loop.** `SeatHost.start` first
waited for the `NSScreen` with `Task.sleep`. In the Lab, under
`NSApplication.run()`, that works and is what the Lab always did. In a
`swift test` process it does not: the host test printed its baseline, entered
`start`, and the process exited with code 0, no failure, no crash report, in the
middle of the suite. It is the same thing ADR 0007 saw at the third display of a
benchmark, from the other side: an `async` main hands the thread back to the
concurrency runtime, whose drain loop decides the program is over.

**A pumping wait starves a process that has one.** Turning `nextEvent` from a
`@MainActor` context holds the main actor for the whole slice. Used for the
display's registration that is harmless, because the caller is awaiting that
anyway. Used for the watchdog's one-second heartbeat it is fatal: the host test
hung, because a task that pumps for a second at a time never gives the main
actor back and the test body could never be resumed.

## Decision

- `EventLoopWait.step(_:)` for a bounded wait **inside an operation the caller
  is awaiting**: the display appearing in `start`, the window coming to rest in
  `adopt`, the window going home in `release`, the display leaving the online
  list in `stop`. It pumps when `isRunning` is false and suspends when it is
  true.
- `EventLoopWait.sleep(_:)` for a **periodic background loop**: the watchdog's
  heartbeat and the recovery's cadence. It never pumps.
- `SeatHost.stop` runs the teardown **inline** rather than inside a child task,
  because awaiting a child task is a suspension and a caller that pumps its own
  loop cannot afford one there. Single flight is a flag plus the stored report.
- A caller that already pumps somewhere else hands that function over in
  `SeatHostConfiguration.eventLoopPump`, so the kit does not open a second
  `nextEvent` call site in a process that has one.
- A caller that can neither pump nor suspend gets `SessionFailure.pumpTimedOut`
  with the number of seconds on it, which is the named timeout ADR 0007 asked
  for.

## Consequences

The three consumers all work, and each for a different reason. The Lab pumps
through `NSApplication.run()` and the host suspends. The benchmark drives
`nextEvent` from a synchronous `main` and the host pumps, which is also why the
benchmark's own `pump(until:)` loops can service the main queue. A test body is
a main-actor job, so the host pumps there too and never suspends inside the
operations the body awaits.

What the test tier still needs on its own side is a task that keeps waking up
while it waits on anything else, for the same drain-loop reason; the Host suite
documents that where it uses it.

The branch is a `Bool` read from AppKit, so a consumer that starts its loop
after calling `start` gets the pumping path for that call and the suspending
path afterwards. That is the correct answer in both halves, and it is why the
choice is made per wait rather than once per host.
