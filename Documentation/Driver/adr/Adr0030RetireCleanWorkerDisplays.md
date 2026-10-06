# Retire a clean worker lease's display

Status: candidate, 2026-10-05. Application qualification is recorded in
[the stabilization rounds](../reports/StabilizationRounds.md).

## Evidence

The queue reuses an AgentSession across worker leases. With Release0468ac57,
repeated QuickTime and Prism workflows complete only the first of three
cycles; later native windows are refused as Stage Manager thumbnails.
Resolve likewise refuses full-size adoption on that reused host. Restarting
the unchanged executable permits three full-size Resolve adoptions. Those
input-free comparisons change the process as well as the host, so they do not
prove that display reuse alone is the native cause.

## Decision

After finishUsingApp successfully returns the held application and its
provenance permits any required quit, a lease with no outstanding restitution
calls the existing SeatDriver.stop. The queue's AgentSession stays open and
reusable. Its next adoption starts a host and creates a new Seat.

A finish warning or an unrestored window retains the host. The change does
not erase deferred returns, replay input, choose another window, relax geometry
or identity guards, or extend application activation. Handover within a lease
keeps its existing lifecycle; explicit lease completion is the new boundary.

The retirement precondition covers the seat's entire lifetime, including
refused returns and failed-adoption restorations from previous assignments.
It is separate from the current application's provenance check: an unrelated
earlier refusal must not prevent quitting an application whose own windows
were returned. Accepted hidden-window returns remain with their independent
ledger and do not require retaining this display.

## Cost and limits

Each clean lease pays for display removal and the next host startup. This
comparison makes no latency percentile claim. Outstanding restitution may
still retain a host; focus and modal adoption remain separate obligations.

## Verification

Release8f22792c completes three independent QuickTime launches, panel Cancel,
scoped empty-window readings, clean session closes and actual process exits,
without restarting Mecum. Prism also completes three Unicode/control/Cancel
cycles with its actual raw values; standalone-observation repeats remain
separately tracked. Earlier failures are preserved.

Resolve adopts at full size on the first candidate trials but refuses Search
input with targetActivated. Later opening attempts encounter the still-open
owned timeline modal. An externally cancelled modal is not a successful
Native workflow and does not qualify timeline creation or undo/redo.

The candidate's offline baseline, full app tests, Release build/signature
and host checks pass before the additional lifecycle regression. The gated
cleanLeasesRetireTheirSeat test then adds three queue reacquisitions: it checks
that the AgentSession identity survives, each ready Seat identity is new,
application cleanup has no warning and the process started by the lease exits.
The gated test actually passes with the previously closed Prism Launcher:
one test, three lease acquisitions, no skips, 15.779 seconds. This exercises
the broker lifecycle; it does not replace Native app workflow qualification.

The subsequent broad 8f22792c cohort stops at Electron cleanup: teardown
reports two Chrome windows refused, although the current Electron overlay
had closed. That explicit session teardown still reports its complete ledger.
A fake-window regression then reproduces the separate automatic-retirement
hazard: the first app refuses return, the second returns to its original
frame, and an empty pending-adoption register alone incorrectly permits host
retirement. The new whole-seat predicate retains the host in that case.
This regression goes red and then passes within the 17-test assignment suite.
The final f0ab94d6 Release build and signature pass. Its Native Prism workflow
also completes three independent cycles with standalone text, toggle, parent
and closure observations. That result qualifies the owned Prism row only;
Photoshop and Resolve adoption, Chrome drag and CEF's composite row do not
complete in the same cohort. The whole-host refusal guard has an offline
regression, not a live reproduction of the earlier refused Chrome return.
