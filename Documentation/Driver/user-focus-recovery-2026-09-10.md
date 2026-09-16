# User focus recovery, 2026-09-10

System: macOS 27.0 build 26A5425a, Mac16,1. These are focused experiments,
not promotion of a macOS build or a promise about all dialog implementations.

The reproducer creates its own Chrome process/profile and local probe page,
adopts and stages its window on the virtual display, returns focus to the actual
previous user window, reads the context menu image, uniquely identifies Print,
and clicks its menu Window ID. It never submits a print job. It terminates only
the Chrome process it created and removes its virtual display on success or
failure.

The baseline from the preceding menu investigation activated Chrome after Print
without physical input. A standalone private activation request restored the
same user window, with request code 0, notification latency 17.58 ms, no cursor
movement, and zero HID events. This showed feasibility; it did not certify
integration or a universal bound.

An integrated activation-only run verified focus at 45.03 ms but failed its
later AX window check. Another verified at 463.53 ms. The final recipe uses the
existing explicit key-window record pair after private activation; its first
integrated run verified at 176.84 ms and passed the later window readings,
with zero HID events and unchanged cursor. This small comparison does not
establish the cause of the earlier disagreement or a latency distribution.

The permanent `UserFocusRecoveryLiveTests.printRestoresUserFocus` checks the
public session path, Print actually chosen, a recorded activation/recovery,
exact destination PID/Window ID, return code, unchanged pointer, no HID activity,
post-menu focus stability, target geometry on the virtual display, no pending
menu receipts, and display teardown. It distinguishes the first frontmost
observation from completion of window verification in its output. Missing AX
evidence fails the test rather than being counted as a pass.

Run it with:

```sh
AGENTSEAT_LIVE_TESTS=1 bash Scripts/run-tier.sh focus-recovery 1 \
  xcrun swift test --filter UserFocusRecoveryLiveTests --no-parallel
```

The unit tests cover pause-before-request, two matching readings, wrong or
missing windows, target geometry outside the virtual display, user app switches,
ambiguous gestures, timeout, repeated activation, idle behavior, teardown,
preserving a waiting state after send completion, and partial sequence receipts.
`make live-tests` includes this regression as a tenth row, separately from the
existing Select All/Undo/Redo checks that must cause no focus transfer at all.

The Lab records recovery events and treats a verified recovery during the same
planner action as resolved focus interference. Its strict manual non-interference
tests still report that focus changed. Action-effect verification remains
separate and is never replaced by successful focus restoration.

## Applied verification

The applied unit tier completed with 419 executed tests and 32 explicitly
skipped Host/Live tests (451 reported), plus all 12 tier-parser checks. The
complete Live tier completed in 48.14 seconds: 7 executed, 3 optional
calibrations skipped, 10 reported. It retained four known issues: two Command-V
effect failures and two Chrome AX-content limitations. The earlier run with
physical mouse activity was inconclusive in two rows and is not counted as a
successful non-interference measurement. Chrome drag changed the probe from
0 to 240 in the complete run.

After that run, the focus watcher was tightened to keep the existing user AX
observer during an adopted app's transient activation. It no longer registers
an observer on Chrome's busy AX server on this urgent path. The final focused
Print regression passed in 5.29 seconds, with frontmost restoration observed at
24.28 ms and two matching window observations completed at 463.15 ms. The
pointer stayed at the same coordinates and HID activity was zero. These are
one-run measurements, not a guaranteed latency; the latter includes AX and
main-run-loop delays. This final change was checked by the focused regression,
not by claiming another complete Live run.

The Lab is built from `AgentSeatLab.xcworkspace`, which includes the local kit;
building only `Research_locator.xcodeproj` omits its package products. No build
ledger was promoted.

See [ADR 0010](adr/0010-bound-user-focus-recovery.md) for the exact authority,
command-boundary pause semantics, opt-in gate, and limitations.

## Follow-up: 8 ms investigation

The subsequent [latency investigation](focus-latency-2026-09-10.md) adds phase
timings, batches window readings, and provides an independent measured budget.
The 8 ms target was not met. The old single 24.28 ms result must not be compared
with the different WindowServer-sampled metric to claim an improvement.
