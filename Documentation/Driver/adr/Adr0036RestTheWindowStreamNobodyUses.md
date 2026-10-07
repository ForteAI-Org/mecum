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
waits for a frame, as it would on a stream at 30 fps, instead of declining. Revised on 7 October
2026 after the live measurement of the wake (below); the first version declined at once with
`LiveFrameFallback.resting` and took the Still.

What keeps a frame drawn during the rest from being handed over is the rule every request
already has, not a check of the rate: `FrameWaiters` serves a frame only if its display time is
strictly after the request's instant (`notBefore`), the newest frame kept included. A frame
displayed after the instant is fresh whatever the rate, so one at the rest rate that arrives
before the wake is confirmed is served too. `LiveFrameHandover`'s checks and the one frame
contract are unchanged.

The wait is bounded as the request is. A request that finds the stream awake and confirmed waits
`LiveFrameHandover.bound`, 100 ms, as before. One that must wake it waits
`LiveFrameHandover.boundAfterRest`, 150 ms, and both are cut to what is left of the request's
deadline. The wake, `preview.update:rate.30`, measured 59 to 69 ms (median) across six apps, and
the first 30 fps frame after it is up to 33 ms later: about 100 ms in the worst measured case,
which the plain bound would miss at random. 150 ms leaves about 50 ms for the main actor hop that
starts the update. A wake that misses it costs the Still on top of the wait, so the worst case is
about 150 + 135 ms, against 135 ms before; only a stream whose wake is slower than any measured
pays it.

When no qualifying frame comes inside the bound the request declines and the seat takes its
stream Still, never an error. The reason says what was found at the end of the bound:
`resting` when the wake was still unconfirmed (the update had not returned), `noFrameInBound`
when the stream was awake and delivered nothing in time. `LiveWindowFrameSourcing` carries the
longer bound as `afterRestWithin`, which a source with no rest rate ignores; the settle reads the
plain method.

The settle reads the same source with its own bound, what is left of its cap, for both. During a
rest it wakes the stream and uses the frames that come, as it does on a running one, and never
waits past its cap: the first frame it sees is the one after the wake, and silence is the cap, as
before. A settle whose wake is still unconfirmed at the cap ends as the fixed pause (`resting`).

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
declined after waiting out a rest whose wake never confirmed is `capture.liveFallback` `resting`
(`noFrameInBound` when the stream was awake), and its settle `settle:fallback.resting`. The wait
for the wake is inside the request's `capture.liveFrame` interval.

To be measured live, none of it is yet:

- host CPU at rest with one session, proc_pid_rusage only, after more than the delay: target
  1.5 ms a second, against about 20 before;
- the first `observe` after a rest: its `tool:observe` time and its `capture.liveFrame` interval,
  and that none falls back (the wake latency, `preview.update:rate.30`, is measured: 59 to 69 ms
  median across six apps);
- frames a second at rest and window server readings a second, from `frames.second` and
  `geometry.second`.

If the rest still costs more than 1.5 ms a second, the next step is stopping the stream at rest,
which makes every first observation after a rest a Still and adds a stream start to the wake.

## Consequences

- An idle session's stream delivers about one frame a second instead of about 29.
- The first observation of a tool call that comes more than 2.5 s after the last one waits for the
  wake and one frame (about 60 to 100 ms, measured for the wake only) instead of taking a Still of
  about 135 ms; a wake that is slower than 150 ms is the Still after the wait. An observation or
  settle within the delay is unchanged.
- The Lab's picture is unchanged while it is shown.
