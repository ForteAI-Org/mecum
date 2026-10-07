# ADR 0034: Observe from the window stream that is already running

Status: implemented, 2026-10-07. Offline tests only; no live run. Part 2 ("unchanged") is a
design, not implemented. It builds on [ADR 0003](Adr0003KitOwnsSeatCapture.md): the kit still
owns every capture path, and the consumer only lends a stream it already runs.

## Evidence

Measured on 7 October 2026 in the Mecum app's test host, optimized measurement build
(`MECUM_PHASES`), Calculator, TextEdit and Chrome, 20 inputs each:

- After each adoption the Broker runs `PreviewStreamController`: one 30 fps stream of the
  attested window that follows the delivery window. It delivered about 29.3 `complete` frames a
  second, 100% with `displayTime`, also while the window did not change and also on an animated
  page. `idle` frames: about 0. Size and framing were those of the observation stream (TextEdit
  656 by 422 on both).
- Every `observe` and every post-action observation started a second stream,
  `SeatCaptureStream.timestampedStill`: size about 46 ms, start about 80 ms, stop about 8 ms, so
  about 135 ms a capture. After an input its first frame came about 450 ms after delivery (the
  act cycle's 310 ms pause plus that start). On the running stream the first frame came 17 to
  26 ms after delivery (p95 32 to 34, maximum 34 at a 33.3 ms frame interval), and the first
  frame with changed pixels about 31 ms after it (p95 40 to 51).
- Per running-stream frame the receiver asked the window server twice: identity (about 14 ms a
  second) and geometry (about 14 ms a second). Over the whole run the geometry answer never
  changed. ScreenCaptureKit attached `scaleFactor` and `contentScale` and never `contentRect` or
  `screenRect`. Host CPU at rest with one session was about 24 ms a second, against a target of
  1.5 ms a second.
- Every complete frame carried dirty rectangles, at rest included: the first frame with dirty
  rectangles after an input was always the first frame.

## Decision

### Source injection

The Driver declares `LiveWindowFrameSourcing` (`SeatSession`): a `@MainActor` role that answers
the first complete Frame of an attested window displayed after an instant, within a bound, or a
`LiveFrameFallback` saying why not. `SeatHost.makeSeat(liveFrames:)` passes it to
`SeatCaptureObservationSource`, with the virtual display's ID for its scale. The Broker's
`PreviewStreamController` conforms and `SeatDriver` composes it. The Driver never imports the
Broker, and a seat made with no source (every caller but `SeatDriver`, including `SeatTarget`'s
own host) behaves exactly as before.

`SeatCaptureStream.firstFrame(displayedAfter:within:)` is the running-stream half: it reads the
stream's `frames` with the same function the stream Still uses on the stream it starts.

### Freshness

The observation barrier is a counter, not an instant: `ObservationIssuer` advances it after a
complete Command and on every invalidation, and a one-shot Still carries it in its coalescing
key. No code compared it with `displayTime`. The stream Still's freshness was implicit: its
stream starts after the request, so its first timestamped frame was displayed after the request.

The running stream is held to that rule explicitly. The instant is the moment the request
reaches `SeatCaptureObservationSource.captureWindowStill`; the seat reads the barrier before it
calls, so the instant is after the barrier's last advance. A frame qualifies when its
`displayTime`, converted by `MachAbsoluteContentClock.displayTimeNanoseconds(fromMachTicks:)`
exactly as `firstTimestampedFrame` converts it, is strictly after the instant. A frame delivered
before its display instant is waited for, as before.

What changes is timing only: the stream start used to add about 120 ms of settling after the
request without anybody asking for it. How long an action is given to show its effect is the act
cycle's pause, which is the Engine's and unchanged.

### Fallbacks

Every fallback is the stream Still, as today, and none fails the observation. The source
declines when the preview is pinned to the display (`pinnedToDisplay`), suspended in its bounded
recovery (`recovering`), idle or unavailable or not running (`notLive`), or on another target
(`otherWindow`). No display frame is cropped. The wait is `LiveFrameHandover.bound`, 100 ms,
three frame intervals at 30 fps against a measured maximum of 34 ms, never more than what is left
of the request's deadline (`noFrameInBound`).

At the hand-over `LiveFrameHandover` checks again, against readings taken after the frame
arrived: the frame's source is the requested window lifetime (`otherWindow`), the window server
gives that window number the same identity now (`identityChanged`), the display time is after the
instant (`displayedBeforeInstant`), the window is at exactly the frame's rectangle
(`geometryChanged`), and the frame's buffer and its filled content agree with the window's size
at the display's scale within `CaptureShapeStabilisation.contentPixelTolerance`
(`sizeMismatch`). The frame is then copied out of the stream's pool (`copyFailed` otherwise).

Hosted-sheet crops and menu surfaces never ask: the running stream shows one window.

### Size

On macOS 27 a frame's geometry comes from `SeatFrame.fallbackGeometry`, which declares the whole
surface to be content, so a stream still running at an earlier shape would hand over a black band
with nothing in its geometry to show it. The size check above is therefore against the window
server's size for the window now, not against the stream's configuration. A reshape that
`CaptureShapeStabilisation` has not settled yet, or that the stream has not applied, is a
mismatch and a fallback; the Still that follows is sized by its own filter and the preview
reshapes after it as before.

### The one frame contract

A delivery is kept for a whole act cycle (`SeatTarget` holds it until the next observation). A
running stream's surface held that long is one of its three pool surfaces the producer cannot
write into. `SeatFrame.detachedCopy()` copies the 32BGRA rows into a surface of its own (1 to
4 MB, a copy against a 135 ms stream), so the pool gets its surface back at once.

### What still holds

- Identity attestation: the hand-over reads `WindowIdentityWitness` fresh, the frame must carry
  `.window(identity)`, and `FrameSampleQualifier` still refuses any other source.
- `stillCurrent`: unchanged, it runs after `captureWindowStill` returns whichever path answered:
  barrier, assignment, selection generation and observation picture.
- Qualification: unchanged, the same `FrameSampleQualifier` with the same clock: valid, full
  window and uniform geometry, and a known, monotonic content age.
- Coalescing: a post-Command request cannot receive pre-barrier pixels, since its frame was
  displayed after its own request instant; the one-shot Still keeps the barrier in its key.
- Deadline: the wait is inside the request's deadline and spends no capture attempt.

### Cached window server readings

`FrameReceiver` keeps both answers in `WindowServerReadingCache` and reads them again after
`refreshIntervalNanoseconds` (1 s), when a frame's pixel size or scale attachments differ from
the reading's, or after `SeatCaptureStream.invalidateWindowServerReadings()`, which
`PreviewStreamController.follow` calls when an observation reports the window at another
rectangle or size. The first frame of every receiver reads both, so a stream Still is checked as
before. A failed identity check and an empty rectangle are never kept. The cache serves the
receiver's own bookkeeping; the hand-over above does not rely on it.

The 30 fps itself is unchanged. The next measurement, idle CPU with the cache, decides it: if the
rest cost stays above 1.5 ms a second, the options are a lower rate while nothing is pending and
nobody watches, or stopping the stream when no layer is attached. Both move this ADR's bound: at
10 fps a qualifying frame can be 100 ms away, and a stopped stream is a fallback on every Still.

## Part 2: "unchanged" (design only)

macOS 27 sends no `idle` frames and puts dirty rectangles on every frame, so neither can say a
window did not change. "Unchanged" already exists one layer up: `AutomationTools` keeps the
scene each window was last read as (its baseline), and `SceneChanges.text` answers
"Unchanged since revision N." when a new scene equals it. What costs time is the pipeline that
builds the new scene. The design that would skip it:

- The Driver compares two Frames for the consumer: the same source identity, the same pixel
  size, the same rectangle, and equal bytes. Both Frames own their surfaces (a stream Still's
  stream is stopped, a running stream's frame is detached), so an exact `memcmp` of 1 to 4 MB
  should cost about a millisecond (an estimate, not measured) and, unlike a hash, has no
  collision: a forced change of any pixel can never compare equal.
- `SeatSceneProvider` keeps the Frame its last scene was built from with the `PerceivedWindow`.
  When the new Frame compares equal, no pop-up is open (the display path never reuses) and the
  window census gives the same window number and title, it returns the kept scene without running
  the pipeline. The tool answer then says "Unchanged since revision N." through the existing
  baseline, with no new field; `full: true` still sends the whole scene.

It is not implemented here, because it is not a contained change and one rule is not the Driver's
to set:

- `SeatSceneProvider` is the Integration joint of the Perception owner's pipeline; its change
  needs that owner.
- The scene is not made of pixels alone. The accessibility stage can report a change that draws
  nothing (a value, or focus moving to an element that is not drawn). Reusing the scene on equal
  pixels drops those; running the accessibility stage alone spends its 0.35 s budget, which
  defeats a 100 ms "unchanged" answer. The owner has to accept the first or choose another rule.
- A Driver comparison with no consumer would be speculative code, so none was added.

## Consequences

- An observation on an adopted window with the preview live costs the wait for one frame plus a
  copy instead of a stream start, and every refusal costs at most 100 ms before the old path.
- The live acceptance (capture median under 80 ms, no qualification error over 50 consecutive
  observe and act, idle CPU before and after) has not been run.
- Frames handed over from the preview carry the preview stream's own display generation, which
  nothing downstream reads; the preview never outlives its host (`SeatDriver.stop`).
- With phases on, `capture.liveFrame` times the attempt and `capture.liveFallback` names the
  reason of each fallback.
