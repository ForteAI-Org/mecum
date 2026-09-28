# Passive interaction listener

`mecum watch` prints the events a person produces while using applications and diagnoses
which element the production perception pipeline resolves at each pointer position.
It is read-only: no Seat, actuation, provider calls, Brain ingestion or persistence.
The application does not start this listener yet.

## Try it

Build with the repository's Swift 6.4 toolchain, then run from a terminal with macOS grants:

```sh
swift build --product mecum
.build/debug/mecum watch "Pro Tools" --raw --duration 30
.build/debug/mecum watch "Pro Tools"
.build/debug/mecum watch "Adobe Premiere" --json --duration 60
```

The optional app argument accepts the CLI's existing running-app name or bundle-id lookup.
Omit it to follow all owners. `--raw` exercises input and window attribution without captures
or AX reads. `--json` emits one JSON object per event; diagnostics go to stderr.
`--no-hover` disables dwell observations. `--interval-ms 500` sets the minimum pause between
ambient perception reads. Ctrl+C, SIGTERM and `--duration` stop the listener and release its tap.
A pending perception read must finish before shutdown completes.

Input Monitoring must be granted to the launching terminal. The tap is listen-only.
Perception also requires Screen Recording; Accessibility contributes native controls.
Missing Accessibility is reported explicitly, and pixel perception can continue.
The command checks grants but never changes them or launches permission dialogs automatically.
After changing grants, quit and reopen the terminal if macOS still reports them missing.

1. Start with `--raw`. Click, right-click and scroll in the target app. Confirm the printed
   process, window number/title, coordinates and scroll axes. Popup windows retain their own id.
2. Start without `--raw`, bring the app forward, move the pointer into its window and wait for
   `ready`. Click one control, then pause before the next input.
3. Inspect `BEFORE`: the element, kind, AX role, section, age and name lookup result.
   `name=same_element` means the production label resolver chose the same element as the point hit.
   An ambiguous name is useful diagnostic output even when the pointer hit is unique.
4. Inspect `AFTER` and `AX` separately. Hovers use the cached scene and report
   `not_requested_for_hover`; they do not request another capture. Clicks wait for a valid
   acquisition instead of dropping the read with `capture_busy`. Input arriving while waiting
   invalidates it and is reported as `input_during_observation`.
   `name_source` identifies an AX title, description, filename, display value or named descendant.
   Empty strings are skipped; editable and secure values are not used by the point reader.
   Both `AFTER` and `AX` are read after delivery. A dropdown can close before these reads,
   so neither replaces missing pre-click evidence.
5. In Pro Tools, test I/O Setup, All Busses, Output Busses, New Paths and Create. Confirm the
   popup/dialog window numbers change. Also test duplicate labels and a control beside plain text.
6. Test a fast click burst and switch apps mid-scroll. Missing or interrupted scene evidence
   must remain unresolved; the gesture must retain the original owner.
7. With `--json`, stdout must remain parseable JSON Lines. No event file is created unless the
   person explicitly redirects stdout.

## Responsibilities and dependencies

- `InteractionListener`: event values, gesture coalescing, hover dwell, delivery-time window
  attribution, a passive macOS event tap and application-activation notifications. Depends only
  on platform frameworks. It has no perception, CLI, storage or agent dependency.
- `InteractionObservation`: exact-window captures through an injected production `ScenePipeline`,
  point resolution, a diagnostic production name lookup, native AX hit testing and scene differences.
  Depends on the listener, Perception, PerceptionCore and ScreenCapture. No EngineRuntime or memory.
- `WatchCommand`: options, signal/duration handling, app selection and terminal rendering. Composes
  the modules with `ProductionPerception.pipeline()` without constructing an action engine.

`UserInteractions` exposes both modules as a library product. A future app host can own the same
listener and consume its event/report stream. Connecting Brain, memory or application settings
requires a separate change; this implementation creates none of those connections.

## Timing and ownership

The event tap and its scroll/hover timer share a dedicated thread. Callback work stamps input,
looks up the surface and enqueues values. OCR and AX scene traversal never run on that thread.
A mutex protects lifecycle and revision data across threads. `stop()` waits for callback teardown;
deinitialization requests teardown as a safety net.

The stream holds at most 128 events and fails visibly on overflow. A disabled tap terminates the
stream instead of claiming uninterrupted recording. Only one capture is in flight per observer.
Its cache retains at most eight window scenes and is discarded at process exit. Event reads have
priority over ambient refresh. A matching in-flight acquisition is shared; an older one is joined
before a new acquisition starts. New input cancels the need for that observation, without abandoning
an underlying capture. This removes skipped reads due to contention, not the cost of perception.
A changed scene may require a second acquisition and therefore a later report.

Click ownership uses the annotated session tap's actual recipient window, including popup and
desktop surfaces. When Quartz omits the window id (for example, scrolling), only surfaces owned by
the routed target process are eligible. Missing routing stays unresolved rather than selecting an
unrelated overlay. Pointer movement updates routing for hover and ambient captures, without emitting
movement events. Move the pointer into the target window after starting the listener to warm it.
Scrolls coalesce after 500 ms without ticks and split on a window, source-process or input-sequence change.
Both horizontal and vertical deltas are in screen points; a zero-net gesture remains an event.
Hover emits once after 1.2 seconds within three points of one location on the same surface.
Application activation has a separate event; consecutive duplicate activations are suppressed.
Keys and drag movements invalidate scene evidence, but their text, key codes and paths are not retained or output.

A `BEFORE` scene must match the exact window identity and geometry, finish before the event,
start no more than two seconds before it and have no intervening input. The acquisition is also
rejected if input arrives during capture. These checks cannot prove that an application did not
repaint spontaneously between two observations; scene age remains visible in the report.
Fresh post-event results never manufacture a missing pre-event control.

Native interactive roles take precedence over overlapping captions. Equally ranked and equally
sized distinct controls remain ambiguous. Candidates, including their AX roles and bounds, are
available in JSON. A scene difference is diagnostic temporal evidence, not a learned causal fact;
a geometric cluster alone is not reported as a verified menu opening.

The listener uses its own conservative `InteractionDifference`, without changing the Engine's
`SceneDifference`. A potential change requires two non-overlapping post-input acquisitions in the
same window, geometry and input revision. Names, role, container and overlapping geometry must
agree for an appeared element; a disappeared element must be absent twice. A state change needs
an unambiguous native counterpart in both samples. Window title changes must persist too.
`OBSERVATION: observed_consistently (causality unverified)` describes this evidence, not an effect
attributed to the click. JSON carries the structured `observation` object. No stable difference is
claimed when confirmation is interrupted.

A new label occupying an old element's position may be OCR noise or a real replacement; it is
excluded from appeared/disappeared claims. Raw scene labels remain visible, including uncertain
pixel text. This does not invent canonical names or persistent identities. Duplicate names and
controls that replace each other can remain unresolved. `no perceived elements` describes capture
coverage, not an empty desktop.

AX hit testing is scoped to the routed application so an unrelated overlay cannot supply its
label. `AXFilename` supplies file-entry names without reading a renaming field's editable value.

The AX point reader traverses at most 12 descendants to depth two and only enters cell, row and
group containers. Multiple different descendant names stay unnamed. It uses a 150 ms traversal
budget and 20 ms per-message timeout after the hit test. Static text and text fields explicitly
reported as non-editable can supply display values. The name source remains visible; this is
post-input evidence and is never substituted into `BEFORE`.

Quartz's source process is included when available. Events posted by the listener itself are
excluded; another automation process may still appear in the stream. A future agent integration
must correlate its own actuation before classifying those observations as human activity.

## Verification

```sh
swift test --filter 'InteractionResolutionTests|InteractionRoutingTests|InteractionObservationTests|GestureTests|WatchOptionsTests'
make test SWIFT=swift
git diff --check
```

The pure tests cover scroll ownership, gesture boundaries, hover reset, stale/cross-window scene
rejection, native control/caption resolution, ambiguity, capture priority/sharing/cancellation,
AX name selection and editable-value exclusion, repeated scene changes and CLI validation. The manual procedure
above is needed for actual event delivery, TCC, popup behavior and pixel/AX agreement. Unit tests
alone do not establish that live coverage.

A read-only AX adapter check is opt-in and requires a known, currently visible control in the
specified app's tree. Fill the coordinates and expected name/source from that live fixture:

```sh
MECUM_INTERACTION_LIVE_AX=1 MECUM_INTERACTION_AX_PID=<pid> \
MECUM_INTERACTION_AX_X=<x> MECUM_INTERACTION_AX_Y=<y> \
MECUM_INTERACTION_AX_LABEL="<visible name>" MECUM_INTERACTION_AX_SOURCE=filename \
swift test --filter InteractionObservationLiveTests
```

This test is skipped by the ordinary unit tier; it never clicks, activates or edits the app.
