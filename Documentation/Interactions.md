# Passive interaction listener

`mecum watch` prints the events a person produces while using applications and diagnoses
which element the production perception pipeline resolves at each pointer position.
It is read-only: no Seat, actuation, provider calls, Brain ingestion or persistence.
The application hosts the same modules in its Watcher window; watching starts only on request.

## In the application

Open **Watcher → Show Watcher** or the waveform button in the main window's toolbar.
Choose **All applications** or a particular running application, then **Start Watching**.
Move the pointer into the target window and wait for **Ready** before clicking. Expand an event
for window identity, coordinates, source process, Before/After perception, native AX evidence and
any confirmed scene difference. Missing or interrupted evidence stays visible as such.

Input Monitoring and Screen Recording must belong to **Mecum**, not just the terminal.
The panel reads grants without prompting and offers explicit buttons to request missing grants and
open the corresponding System Settings pane. Accessibility is optional: without it the panel warns
that only pixel perception is available. After changing grants, reopen Mecum if macOS requires it.

One `WatcherModel` in `AppModel` owns the listener for all windows. Closing the Watcher window keeps
an explicit run active; the toolbar indicates its state and the Watcher menu can still stop it.
**Stop Watching** waits for native threads and pending perception to finish before permitting a
restart. Quitting the app includes watcher teardown in the delegate's bounded shutdown. Lost required
grants, target-app termination, tap failure or a full delivery buffer stop the run with an explanation.
Reopening a target app does not silently attach to its new process: select it and start again.

The panel keeps at most 100 compact display records in memory and the listener buffers at most 256
events. Overflow fails explicitly rather than silently dropping input. Clear empties the displayed
history without stopping. Restart starts a fresh history; quitting discards it. No event database,
screenshot archive, provider call or automatic Brain/living-memory ingestion is created. Perception
uses an eight-scene transient cache; scene differences remain observations with unverified causality.
Input from another automation process can appear, with its source PID; it is not proof of human input.

## Try the CLI

Build with the repository's Swift 6.4 toolchain, then run from a terminal with macOS grants:

```sh
swift build --product mecum
.build/debug/mecum watch "Pro Tools" --raw --duration 30
.build/debug/mecum watch "Pro Tools"
.build/debug/mecum watch "Adobe Premiere" --json --duration 60
```

The optional app argument accepts the CLI's existing running-app name or bundle-id lookup.
Omit it to follow all owners. `--raw` exercises input and window attribution without captures
or AX reads. `--json` emits one JSON object per event; diagnostics go to stderr. A `gap` line
reports input the listener could not keep under pressure; it is never filtered by app.
`--no-hover` disables dwell observations. `--interval-ms 500` sets the minimum pause between
ambient perception reads. Ctrl+C, SIGTERM and `--duration` stop the listener and release its tap.
A pending perception read must finish before shutdown completes. At stop, one stderr line reports
the counters: observed sequences, records queued, coalescing, loss and gaps.

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

- `InteractionListener`: event values, fixed-width input records, a preallocated record queue,
  gesture coalescing, hover dwell, delivery-time window attribution against a window snapshot, a
  passive macOS event tap and application-activation notifications. Depends only on platform
  frameworks. It has no perception, CLI, storage or agent dependency.
- `InteractionObservation`: exact-window captures through an injected production `ScenePipeline`,
  point resolution, a diagnostic production name lookup, native AX hit testing and scene differences.
  Depends on the listener, Perception, PerceptionCore and ScreenCapture. No EngineRuntime or memory.
- `WatchCommand`: options, signal/duration handling, app selection and terminal rendering. Composes
  the modules with `ProductionPerception.pipeline()` without constructing an action engine.

`UserInteractions` exposes both modules as a library product. `NativeWatcherSession` composes them
inside Mecum's process with the production perception pipeline. `WatcherModel` owns lifecycle,
permission/target health checks and bounded UI history. A typed `InteractionObserverStatus` reports
readiness and capture failure without parsing CLI diagnostics. Brain and memory ingestion remain
separate from this passive diagnostic stream.

## Timing and ownership

The event tap, focus notifications and one scroll/hover timer share a dedicated thread, the only
producer of a single-producer single-consumer queue. Callback work reads event fields, stamps a
monotonic time and revision, hit-tests an in-memory window snapshot and writes a 104-byte
`InputRecord`: no window listing, title lookup, allocation per event, blocking or IPC. The timer is
armed from scroll-settle and dwell deadlines only, so a still pointer and idle input cause no
wakeups. A refresher thread lists windows 100 ms after the pointer enters another surface (its routed
recipient window changes), a click, the first move after a drag, a focus change or a stale
attribution, never for moves inside one surface or while input is idle, and publishes each snapshot
whole under a new generation. A consumer
thread wakes when the queue turns non-empty, resolves the window title for each record and yields
`InteractionEvent` values. OCR and AX scene traversal never run on the tap thread. `stop()` joins all
three threads; deinitialization requests teardown as a safety net.

The queue holds 1024 records, 256 of them reserved for clicks, focus and loss markers. Short of room
it keeps the last hover, aggregates compatible scrolls and keeps critical input in its reserve; when
the reserve is exhausted too, a `gap` event reports the lost sequence range and how many critical and
coalescible records it held. Sequences are otherwise contiguous, `queueCounters` totals coalescing and
loss. Queue pressure does not fail the stream. Hosts can additionally bound the event stream after
the consumer thread with `eventBufferLimit`; overflow ends it with `consumerTooSlow` and requests
tap teardown. The application uses 256 events. The CLI retains its unbounded diagnostic stream,
so a stalled CLI reader grows memory instead of degrading the queue. A disabled tap terminates the
stream instead of claiming uninterrupted recording. Only one capture is in flight per observer.
Its cache retains at most eight window scenes and is discarded at process exit. Event reads have
priority over ambient refresh. A matching in-flight acquisition is shared; an older one is joined
before a new acquisition starts. New input cancels the need for that observation, without abandoning
an underlying capture. This removes skipped reads due to contention, not the cost of perception.
A changed scene may require a second acquisition and therefore a later report.

Click ownership uses the annotated session tap's actual recipient window, including popup and
desktop surfaces. When Quartz omits the window id (for example, scrolling), only surfaces owned by
the routed target process are eligible. Missing routing stays unresolved rather than selecting an
unrelated overlay. The callback hit-tests a window snapshot listed after the pointer last entered a
surface, a click, a drag's end or a focus change. A routed window the snapshot cannot confirm (new, moved or closed since it was
listed) is flagged stale and triggers a refresh. When the record is delivered, the routed window's
own row is read once: if that exact window is on screen, visible, owned by the routed process and
contains the point, it becomes the event's window with its frame and title at delivery, so a popup
opened just before the click keeps its id. Otherwise it stays unresolved; process-only routing never
falls back to a frontmost window. Titles are always read at delivery, not at the click. Pointer
movement updates routing for hover and ambient captures, without emitting movement events. Move the
pointer into the target window after starting the listener to warm it.
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

## Why one process

The tap, its queue and the consumer run in their host process (the CLI or Mecum app). A two-process variant (the tap
in a separate observer process behind a shared-memory ring) was built and measured live against this
one on 29 Sep 2026: at human pace it had the same callback latency and the same CPU, and cost 8 MiB
more memory and 6 more threads. The in-process queue already isolates the callback from the consumer:
the tap thread never waits for it, and a stalled consumer degrades into counted coalescing and gaps.
The variant was removed.

## Measuring the tap (B9)

The tap thread times the body of every callback with two `CLOCK_UPTIME_RAW` reads into fixed
log2-bucket histograms (count, buckets, exact maximum) that only it writes: no lock, no allocation.
`input` holds the callbacks that can produce an event (left and right mouse down, scroll), `pointer`
every other callback (moves, drags, keys), and `timer` the body of the scroll/hover timer, which runs
on the same thread and delays callbacks queued behind it. They measure work inside the callback, not
how late the event reached it. SIGUSR1 to `mecum watch` prints one line per histogram and resets
them; the same three lines are printed once at stop:

```
callback[inprocess] input: n 412 p50 2.1us p90 4.0us p99 9.8us max 40.2us (since last dump)
callback[inprocess] pointer: n 9120 p50 0.4us p90 0.7us p99 1.1us max 8.0us (since last dump)
callback[inprocess] timer: n 0 (since last dump)
```

`(since last dump, at stop)` marks the stop lines. A dispatch source takes the signal and the tap
thread takes and resets the histograms, so they keep one writer. Percentiles are interpolated inside
their octave, so two p99s in the same bucket compare only approximately.

SIGUSR2 to `mecum watch --raw` pauses or resumes the loop that reads `events`; the listener keeps
running. The consumer thread keeps draining the queue into the unbounded stream, so the pause stalls
the stream's reader only and puts no pressure on the queue.

The same work is visible in Instruments as signpost intervals, subsystem `com.forte.mecum`, category
`InteractionTap`: `receive` for the callback, `wakeFired` for the scroll/hover timer and `focus` for an
application activation. They are begun only while signposts are enabled.

`Tools/Engine/Scripts/watch-resources.sh` runs the measurement with the person at the machine through
an idle, an active and a stall phase. It prints CPU, wakeups, memory and threads, the three latency
kinds per phase and the verdicts: idle CPU at most 0.1%, no polling, no `input` callback over 1 ms,
a stall survived with its losses counted in gaps, and the pointer target (p50 at most 0.5 µs, max at
most 60 µs). Beside them it prints the 29 Sep 2026 reference: the original listener and this one
before the pointer path was trimmed.

`PointerMoveTests` drives the callback body with synthetic moves on a stand-in tap thread, with the
real refresher and wake timer and no tap, and prints the move path's p50/p99/max for moves that each
enter another surface (every move woke the refresher before) and for moves inside one surface.

## Verification

```sh
swift test --no-parallel --filter 'InteractionTests|WatchOptionsTests'
make test SWIFT=swift
git diff --check
```

The app's `WatcherModelTests` use a controlled session to cover no automatic startup, grant checks,
joined cleanup, duplicate starts, late callbacks, history bounds, permission revocation, target exit,
shutdown and visible listener failure. They do not request grants or observe real apps.
`ListenerBufferTests` exercises explicit delivery overflow without a live tap.

The pure tests cover the record layout, queue wraparound, degradation and gap accounting, a
two-thread stress with randomized consumer stalls, snapshot parity with the direct window reader,
stale attribution and its resolution at delivery, which moves wake the snapshot refresher, scroll ownership, gesture boundaries, settle and
dwell deadlines, stale/cross-window scene rejection, native control/caption resolution, ambiguity,
capture priority/sharing/cancellation, AX name selection and editable-value exclusion, repeated
scene changes and CLI validation. The manual procedure above is needed for actual event delivery,
TCC, popup behavior and pixel/AX agreement. Unit tests alone do not establish that live coverage.

A read-only AX adapter check is opt-in and requires a known, currently visible control in the
specified app's tree. Fill the coordinates and expected name/source from that live fixture:

```sh
MECUM_INTERACTION_LIVE_AX=1 MECUM_INTERACTION_AX_PID=<pid> \
MECUM_INTERACTION_AX_X=<x> MECUM_INTERACTION_AX_Y=<y> \
MECUM_INTERACTION_AX_LABEL="<visible name>" MECUM_INTERACTION_AX_SOURCE=filename \
swift test --filter InteractionObservationLiveTests
```

This test is skipped by the ordinary unit tier; it never clicks, activates or edits the app.
