# Prepared user-focus recovery

Implemented on 2026-09-10 for the opt-in Lab facility on macOS 27.0, build
26A5425a. The automatic checks pass. Live results show a shorter urgent path,
but do **not** certify a universal 8 ms return or fully stable activation-only
window recovery. No build-ledger promotion follows from this work.

## Behavior

Before target preparation and every atomic command, the driver awaits a fresh
user destination, owning connection/PSN and visible-window snapshot. The window
list is read through a structured `@concurrent` call with immutable geometry;
AppKit and AX remain on MainActor. This includes the click selecting Print,
not only the earlier right click, and every command of a sequence.

The prepared action expires one second after its capture starts and is bound to
the current hold, user window and adopted set. User app/window changes and
teardown invalidate it; cancellation, an ended/replaced action or an inactive
fence prevents posting after the await. A missing/expired preparation causes a
miss with input paused, not a synchronous emergency scan or replay.

On activation, the gate closes first. The callback validates prepared geometry,
current display topology, user switch intent and the current front-process PSN
through the exact `_SLPSGetFrontProcess` export. The previously prepared user
PSN/Window ID is passed to `_SLPSSetFrontProcessWithOptions` with mode 0x200.
No owner lookup, window enumeration or key-window records run on this path.

The live `CGEvent.tapIsEnabled` query runs before input (also after the async
read) and before gate reopening. It does not delay focus-only restoration,
which sends no pointer event. The original two matching frontmost/focused-window
observations are still required before commands resume. One automatic attempt
per hold remains the limit. Refusal details survive the verification timeout.

This deliberately accepts bounded stale geometry: a dialog created after the
snapshot is absent from it. The agent application is assumed to keep its new
windows on its separate display. Snapshot age in these trials was around
380–405 ms because the native menu command activates after its transition.
A snapshot restricted to just a few milliseconds would miss this trigger.
See [ADR 0010](adr/0010-bound-user-focus-recovery.md) for the contract.

## Final live measurements

The same production source was exercised six times: five matrix attempts and
one diagnostic repeat. The repeat only added AX error diagnostics to the test;
no production behavior changed. Every trial reported zero physical HID events
and an unchanged pointer. Five passed the independent functional oracles. One
failed because two independent post-recovery AX reads returned nil after the
coordinator had already verified the expected Window ID twice; no different
Window ID was reported. The cause of those missing readings was not established,
and this row remains failed. A subsequent repeat passed with no AX read error.

The sampler uses independent, read-only WindowServer observations. Intervals
are lower/upper bounds on **target front process → user front process**. They
are not request-call durations, NSWorkspace callback durations, or gate-resume
times. Wide sampling gaps must remain visible as uncertainty.

| Attempt | Functional result | Interruption bounds, ms | 8 ms verdict |
| --- | --- | ---: | --- |
| 1 | passed | 3.182–13.588 | inconclusive |
| 2 | passed | 5.849–7.797 | passed |
| 3 | passed | 2.748–4.099 | passed |
| 4 | passed | 5.322–7.262 | passed |
| 5 | failed: two AX reads returned nil | 15.076–18.264 | failed |
| 6 | passed | 6.567–29.993 | inconclusive |

Three of six independent measurements prove the 8 ms budget. Two are inconclusive;
one of those spans 6.567–29.993 ms because the sampler missed observations.
That does not prove a 30 ms interruption. The failed AX row also independently proves a latency failure: even its lower
bound exceeds 8 ms. The earlier report discarded that valid latency evidence
when AX failed. The corrected parser keeps functional and timing results separate;
this correction does not change the historical source or raw data.

Raw measurements, counts and the failed-row evidence are in
[focus-prepared-2026-09-10.json](measurements/focus-prepared-2026-09-10.json).

## Costs on the five functionally valid trials

These are raw phase readings, in milliseconds; empty clock control was 23–38 ns
in these runs. Phase medians must not be added to manufacture an end-to-end
median. The first three rows happen **before** input; request completion is an
offset from activation handling. The preparation span starts after its initial
fence check and includes the final post-await fence check. The app can become frontmost before the private
activation call returns.

| Phase | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: |
| Prepared identity resolution | 0.050 | 0.053 | 0.060 |
| Prepared window enumeration | 0.368 | 0.386 | 0.418 |
| Measured pre-action preparation | 1.141 | 1.502 | 3.979 |
| Pause and publication | 0.049 | 0.052 | 0.055 |
| Current display checks | 0.021 | 0.022 | 0.027 |
| Prepared adopted-window checks | 0.002 | 0.002 | 0.003 |
| Prepared visible-window checks | 0.006 | 0.006 | 0.007 |
| Prepared destination check | 0.003 | 0.003 | 0.004 |
| Direct front-process and user-intent checks | 0.005 | 0.005 | 0.006 |
| Private activation call | 4.759 | 8.857 | 9.982 |
| Detection to request completion | 4.851 | 8.953 | 10.084 |

Urgent owner/PSN lookup and both key-record timings are zero. The final guard
fell from 2.4–4.0 ms in the preceding iteration to microseconds when the live
fence query moved out of focus restoration. The remaining urgent wall time is
almost entirely in the private activation call. This observation is specific
to these trials and is not an OS latency floor or a guarantee for other dialogs.

## Earlier iterations retained for comparison

The initial prepared-window/activation-only iteration completed two functional
trials at 8.017–9.380 and 11.592–15.265 ms; a third made no recovery request.
Its refusal did not yet identify the exact failed guard, so its cause is not
retrospectively assigned. See [initial evidence](measurements/focus-prepared-initial-2026-09-10.json).

Preparing the identity chain and using the direct front-process witness then
passed all five functional trials. Their upper bounds ranged from 5.425 to
10.027 ms, median 8.653 ms; one proved 8 ms and four were inconclusive for that
budget. See [evidence before moving the fence check](measurements/focus-prepared-before-fence-2026-09-10.json).

These are sequential development runs, not randomized paired benchmarks.
The last iteration remains experimental because of the unresolved AX observation
failure and insufficient evidence for a consistent 8 ms bound.

## Automatic validation

`make test` runs the counted unit tier plus the tier-parser and latency-parser
regressions. Coverage includes missing/expired snapshots, stale async completion,
changed user/hold/target, cancellation, per-boundary preparation, direct-front
refusal, one-attempt behavior, and an inactive fence preventing input/resumption
while allowing pointer-free focus restoration. The new missing-preparation test
first failed against the original urgent scanner, then passed after the change.

Final counted result: **431 executed, 32 skipped, 463 reported**, plus **12 tier-parser
and 8 latency-parser tests passed**. The 32 skips are opt-in Host/Live rows, not
failed focus rows. The failed live AX trial above is retained separately.
