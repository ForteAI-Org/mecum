# Focus recovery latency, 2026-09-10

## Result

The requested **8 ms limit is not met**. The final five Chrome Print trials all
passed the functional regression: the same user window recovered, request code
0, no pointer movement, no physical HID events, stable later focus readings,
and complete disposal of the owned Chrome process and virtual display.
Two trials proved a budget overrun; three had sampling intervals crossing the
budget and are inconclusive for latency. None certified 8 ms.

On the original metric, detection to the first NSWorkspace frontmost observation,
the final minimum/median/maximum were **19.84 / 25.27 / 44.48 ms**. The earlier
24.28 ms result was one observation. These measurements do **not** establish an
end-to-end speedup. The independent private front-process readings are a separate
metric and must not be presented as a reduction from those 24 ms.

Window verification completed in 376.38..681.70 ms. This is when two AX/window
observations permitted commands again, not a measurement of how long pixels
were visibly unfocused. No claim of visual invisibility is made.

## Implementation

Recovery uses one fresh visible-window reading for all adopted-window,
activating-process and destination checks. The previous path made four window
information calls with one adopted window. The input tap is checked once,
immediately before the private request. Owner and PSN resolution still happen
for that request. All visible windows of the activating PID must fit on the
virtual display, and the destination must still belong to the recorded user PID
and fit on a physical display. An unavailable batch reading fails closed.

The redundant second destination validation after `currentUserWindow()` was
removed; the first still validates the current identity, visibility and physical
geometry. Input remains paused until two matching focus observations. The
private activation mode, key-window record pair, no-replay policy and one-attempt
per-hold rule are unchanged. No private symbol was promoted or added to the
production facility by this investigation.

A display-cache variant was tested and removed: it did not establish a useful
additional latency benefit. The final code reads the display configuration on
every recovery. The callback implementation and its lifecycle are unchanged.

`UserFocusRecoveryReport.timing` exposes raw monotonic phase durations and the
activation-handler entry timestamp. The destination preparation at hold entry
is separate from the urgent path (median 1.162 ms in this series). Timing logs
are emitted by the test after recovery, never from the urgent callbacks.

## Phase durations

Milliseconds, minimum/median/maximum over the final five trials. Each span has
the measured clock-pair control subtracted, clamped at zero. The raw values are
retained in the JSON. Control subtraction is not applied to the focus interval
used to judge the 8 ms budget. Medians of phases must not be summed to invent an
end-to-end median.

| Phase | Minimum | Median | Maximum |
| --- | ---: | ---: | ---: |
| Pause input and publish the issue | 0.049 | 0.054 | 0.063 |
| Read display topology | 0.034 | 0.042 | 0.044 |
| Read visible windows and check the activating PID | 6.086 | 6.777 | 8.657 |
| Check adopted window identities and bounds | 0.004 | 0.006 | 0.007 |
| Check the destination identity and physical bounds | 0.007 | 0.010 | 0.012 |
| Check frontmost PID, user intent, and the live input tap | 0.138 | 2.437 | 3.646 |
| Resolve owning connection | 0.013 | 0.026 | 1.137 |
| Resolve process serial number | 0.008 | 0.013 | 0.034 |
| Private front-process request | 3.947 | 4.015 | 4.650 |
| First key-window record | 3.471 | 7.139 | 9.330 |
| Second key-window record | 0.218 | 1.604 | 4.872 |

The remaining cost is concentrated in WindowServer operations. Shortening the
5 ms verification timer would not remove these synchronous request costs.

## Independent focus interval

A bounded read-only helper samples `_SLPSGetFrontProcess` through its checked
arm64 ABI. It compares the PSNs resolved from the user and owned Chrome Window
IDs, with no setters, mouse events, key events or AX actions. Sampling requests
500 microseconds and a user-interactive QoS hint for at most four seconds; actual
scheduling gaps remain measured and can be much larger. The sampler does not
change the production recovery thread's priority.

For each transition, the previous sample start and current sample end bound the
unknown transition instant. Subtracting these intervals produces conservative
bounds on the observed front-process episode. An interval crossing 8 ms is
inconclusive, not a pass. Missing target transitions, a different user app,
physical activity or an incomplete functional test also cannot pass the budget.
The uncertainty can include most of a trial; the upper bound is not an exact
measurement of the visible interruption.

| Trial | Lower bound, ms | Upper bound, ms | 8 ms verdict |
| --- | ---: | ---: | --- |
| 1 | 7.727 | 10.185 | inconclusive |
| 2 | 3.794 | 32.360 | inconclusive |
| 3 | 10.695 | 18.496 | failed |
| 4 | 7.485 | 11.004 | inconclusive |
| 5 | 9.495 | 11.334 | failed |

NSWorkspace observations depend on main-run-loop updates; they are not an
independent timestamp of the global focus transfer.
[Apple documents that update policy](https://developer.apple.com/documentation/appkit/nsrunningapplication).
The private PSN ABI is declared by
[yabai](https://github.com/koekeishiya/yabai/blob/master/src/misc/extern.h)
and was cross-checked in the current SkyLight disassembly before the helper ran.

## Private reader investigation

A read-only `SLSWindowQueryWindows`/iterator prototype was compared with
`CGWindowListCopyWindowInfo`. After correcting its CFNumber array input, it was
fast on warm calls but returned PID 0 for 15 of 21 visible windows. An attempt to
resolve those owners did not complete successfully. It therefore cannot replace
the identity oracle used to authorize recovery and is not in the shipped path.
The temporary helpers live under `/tmp/agentseat-window-query-*`.

## Reproduction and evidence

Run from the kit, with an awake Mac and no physical input during the trials:

```sh
make focus-latency FOCUS_RUNS=5 FOCUS_OUTPUT=/tmp/focus-latency.json
```

The command builds the read-only sampler, runs the existing real Print test
through the counted tier wrapper, and writes the per-trial logs and JSON. It
returns 0 only when every observed interval's upper bound is at most 8 ms; 1
means the budget was not met and 2 means evidence could not be collected.
The sampler is limited to macOS build 26A5425a until its private ABI is checked
on another build. It neither updates the compatibility ledger nor counts skips
as executions.

The final series used macOS 27.0 build 26A5425a, Mac16,1, and the Debug Swift
Testing harness built with Xcode beta Swift 6.4. It measures this harness, not
the complete Lab application's rendering or scheduling.

- [Final raw measurements](measurements/focus-latency-2026-09-10.json)
- `/tmp/agentseat-latency-final-series.trial-1.log` through `trial-5.log`
- `/tmp/agentseat-latency-final-series.log`: functional success, budget not met

The initial 8 ms assertion also failed on the previous path at 11.25 ms. Earlier
cache and batch experiments are retained in `/tmp/agentseat-latency-*.log`; they
are not mixed into the final distribution. A preparation interrupted by an app
switch and the run that failed with `noPhysicalDisplays` are not valid latency
measurements.
## Installed validation

The 20 changed source, test, script and evidence files were copied to the active
kit only after their original hashes matched the pre-change baseline. All 210
tracked-by-manifest paths matched the expected installed content; unrelated
files from that baseline were unchanged. A backup of replaced files is retained
at the path recorded in `/tmp/agentseat-latency-installed.json`.

On the installed kit, `make test` passed: **417 executed, 35 skipped, 452
reported** across 11 Swift test runs, plus **12 tier-parser tests and 8 latency
parser tests**. Three display-presence tests were skipped by their existing
`aDisplayIsAwake()` condition. The preceding run on byte-identical staged source
passed with **420 executed and 32 skipped**, including those three tests.
Neither count treats skipped tests as executions. The five real Print recovery
trials above were run against that staged source before installation.

The `AgentSeatLab.xcworkspace` Debug build of the `Research_locator` scheme with
`CODE_SIGNING_ALLOWED=NO` succeeded using the updated local package. This is
integration compilation evidence; no additional Lab runtime latency result is
claimed. Logs: `/tmp/agentseat-latency-installed-unit.log` and
`/tmp/agentseat-latency-lab-build.log`.
