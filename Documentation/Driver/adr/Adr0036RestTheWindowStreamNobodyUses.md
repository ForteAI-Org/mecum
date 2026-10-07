# ADR 0036: Rest the window stream nobody uses

Status: implemented, 2026-10-07. Offline tests only; no live run. It builds on
[ADR 0034](Adr0034ObserveFromTheRunningWindowStream.md) and
[ADR 0035](Adr0035SettleOnTheRunningWindowStream.md).

## Evidence

Measured on 7 October 2026 (ADR 0034's acceptance, app test host, optimized): with one open
session and no tool call the host spent about 20 ms of CPU a second (31 before the window
server readings were cached), against a target of 1.5 ms a second. What is left is the
Broker's running window stream itself: about 29 `complete` frames a second at 30 fps, also for
a window that does not change, since macOS 27 sends no `idle` frames. ADR 0034 named the two
options: a lower rate while nothing is pending and nobody watches, or stopping the stream.

## Decision

`PreviewStreamController` lowers the rate of its running stream while it is unused and not
shown, and raises it again on the next use. The constants are `PreviewRestPlan`'s:

- `delay`, 2.5 s without a use. An act cycle's own gaps (observe, Turn, Command, settle,
  observe) are tens to hundreds of milliseconds, so the stream never rests inside a tool call;
  a model choosing its next call usually takes longer, and that is the rest this is for.
- `framesPerSecond`, 1: the lowest whole rate `SeatCaptureConfiguration` asks for. The stream
  keeps running, so the change both ways is `SCStream.updateConfiguration`, which the preview
  already uses to reshape, and not a stop and a start (about 8 and 80 ms, plus a resource the
  framework may keep).

### What counts as a use

Every request for a frame (an observation through `LiveWindowFrameSourcing`, and each frame of
a settle), every observation the preview follows, the adoption that starts the stream, and,
through `SeatDriver`, a Turn and a Command. The engine's own act cycle acquires its Turn and
sends its Command right after the observation that starts it, so its first request is already
the use. A layer attached or detached is a use too.

### Shown to the person

The Lab shows the stream through `LivePreviewView`, which attaches its `MonitorLayer` to the
controller while the view is in a window and detaches it when the view leaves its window. A
controller with any layer attached never rests, and attaching one wakes it: the person watching
gets 30 fps exactly as before. A stream pinned to the display is shown the same way: it never
rests while pinned, pinning wakes it and unpinning starts the delay. A view in a window that is
hidden or covered still counts as shown; that only costs the rest it could have had.

### Freshness

A request that finds the stream resting, or not yet confirmed back at 30 fps, wakes it and
declines at once with the new `LiveFrameFallback.resting`. It never asks the stream for a
frame, so no frame drawn during the rest can be handed over, and the seat takes its stream
Still as for any other fallback: the worst case of the first observation after a rest is
today's Still (about 130 ms), never a wait on the update and never an error. The rate counts as
active only once `updateConfiguration` has returned; a request made while a rest update is still
in flight waits for a frame displayed after its own instant within the 100 ms bound, as before,
and falls back if none comes. `LiveFrameHandover`'s checks and the one frame contract are
unchanged.

The settle reads the same source: during a rest or a wake it gets `resting` and waits the rest
of its cap, which is the fixed pause (ADR 0035), so no settle ends early on a slow stream.

Waiting for the wake inside the bound was not chosen because the update's latency has not been
measured. If the live run shows it reliably under about 50 ms, the first request could wait for
the wake and the 30 fps frame after it instead of taking the Still.

### Serialization

A rate change re-runs the last transition the controller was asked for (same target, size and
previous reading), and `replaceStreamIfNeeded` reads the rate wanted when it runs. A rest and a
wake therefore queue behind a reshape or a replacement and never overlap another
`updateConfiguration` (which the stream refuses with `configurationUpdateInProgress`), and a
newer wish always wins. A refused rate change falls back to the restart a refused reshape
already takes. A stream started while the controller rests starts at the rest rate.

## Measuring it

With phases on, `preview.rest` events say `enter` and `leave.<use>` (`frameRequest`,
`observation`, `adoption`, `turn`, `command`, `layer`, `pin`), and `preview.update` times each
configuration update, named `reshape`, `rate.1` (the rest) or `rate.30` (the wake). A request
declined during a rest is `capture.liveFallback` `resting`, and its settle `settle:fallback.resting`.

To be measured live, none of it is yet:

- host CPU at rest with one session, proc_pid_rusage only, after more than the delay: target
  1.5 ms a second, against about 20 before;
- `preview.update:rate.30`, the wake latency, median and maximum, which decides the paragraph
  above;
- the first `observe` after a rest: its `tool:observe` time and that its fallback is `resting`;
- frames a second at rest and window server readings a second, from `frames.second` and
  `geometry.second`.

If the rest still costs more than 1.5 ms a second, the next step is stopping the stream at rest,
which makes every first observation after a rest a Still and adds a stream start to the wake.

## Consequences

- An idle session's stream delivers about one frame a second instead of about 29.
- The first observation of a tool call that comes more than 2.5 s after the last one is a Still
  again, about 100 ms slower than a frame of the running stream; an observation or settle within
  the delay is unchanged.
- The Lab's picture is unchanged while it is shown.
