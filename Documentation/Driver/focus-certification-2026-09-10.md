# Focus recovery diagnostic campaign, 2026-09-10

This campaign separates exact-window correctness, independent front-process
latency, notification delivery and measurement uncertainty. It does not certify
a universal timing guarantee or promote the private build ledger.

## Protocol fixed before the live run

- Same macOS build 26A5425a, Swift 6.4 Debug build, same remembered user app/window.
- Twelve cells: two repetitions of cold Chrome, warmed menu, and controlled CPU
  load, each with activation-only and activation plus two key-window records.
  First repetition orders A then B; second orders B then A within each scenario.
- Each cell launches its own Chrome process and empty profile on the virtual
  display. Warm-menu opens and cancels the native context menu once before
  measuring Print; it is **not** a second Print in an already warmed print dialog.
- CPU load is two owned `yes` processes, terminated after that cell. It is a
  limited contention scenario, not whole-machine saturation.
- The user leaves physical input idle. HID activity or cursor movement invalidates
  measurement. Unknown or missing functional evidence never qualifies.
- The independent read-only sampler requests 100 microsecond sleeps at interactive
  QoS. Real sample gaps, read cost, process CPU/wall time and transition intervals
  are retained. The requested sleep is not a claimed precision guarantee.
- A trial passes the 8 ms latency test only if its upper bound is <= 8 ms. A
  lower bound > 8 ms proves failure; an interval crossing 8 ms is inconclusive.
  Measurement precision is separately reported against a 0.5 ms interval width.
- AX failure remains a functional failure even when timing passes. A functional
  failure never suppresses valid independent latency evidence.
- Observe notification receipt before queue dispatch, then recovery handler entry.
  Keep the context-menu polling path distinguishable. Clock origin matches the
  sampler's monotonic uptime clock. Receipt is not the OS's event creation time.
- AX observations retain the timeout setter result, attribute result, value type,
  raw Window ID mapping result, exact Window ID, phase, timestamp and duration.
  These are read-only oracles; they never substitute a main window for focus.

## Qualification gate

The diagnostic matrix is not a statistical qualification. Only after a fixed
implementation and representative protocol pass the pilot should a separate
campaign attempt 300 approximately independent valid successes. With zero
failures, the exact one-sided 95% lower bound is 0.05^(1/300) = 0.990064.
That statement depends on independence and a defined workload distribution;
consecutive warm repetitions on one Mac do not automatically satisfy it.
Inconclusive or missing trials must not be silently removed or retried until
success. A definite pilot counterexample blocks an 8 ms qualification claim.

## Reproduction

Compile with `make test` outside the quiet measurement interval. Then:

```sh
python3 Scripts/measure-focus-latency.py --matrix --skip-build --sample-us 100 \
  --output /tmp/focus-certification-matrix.json
```

The runner saves the complete plan, every attempted cell, independent outcomes,
raw measurements, and a path to each original log. It continues after a recorded
AX failure; it stops on missing evidence or physical interference. A later
single-mode campaign can use `--runs 300`, but its interpretation still requires
the frozen qualification protocol above.

## Historical correction

Replaying the original failed AX log now gives functional **failed** and latency
**failed**, with bounds 15.075917–18.264292 ms. The older parser rejected the row
before looking at the valid sampler data. Historical raw data is unchanged;
the previous narrative table has been corrected.

## Results

Completed all **12 planned cells**, each with one executed test and no skips.
All twelve passed the functional test: **72/72 AX reads** returned the exact
remembered Window ID, including 60 post-recovery/stability reads. No attribute
or Window ID mapping error was observed. This does **not** establish the cause
of the historical transient AX failure; the new data can now distinguish it
when it recurs. Neither mode showed an AX advantage in this small comparison.

One earlier attempt is retained separately: its four-second sampler expired
while the first menu OCR was still initializing. AX and recovery succeeded,
but latency was unobserved. The sampler now starts after OCR identifies Print
and immediately before the chosen point is returned for the click.

| Cell | Scenario | Mode | Interruption bounds, ms | Uncertainty width, ms | 8 ms |
| --- | --- | --- | ---: | ---: | --- |
| 1 | cold | activation only | 3.280–3.663 | 0.383 | passed |
| 2 | cold | activation + key pair | 3.270–3.549 | 0.279 | passed |
| 3 | warm-menu | activation only | 4.889–5.178 | 0.288 | passed |
| 4 | warm-menu | activation + key pair | 4.407–4.693 | 0.286 | passed |
| 5 | cpu-load | activation only | 6.404–6.697 | 0.293 | passed |
| 6 | cpu-load | activation + key pair | 9.011–9.701 | 0.690 | failed |
| 7 | cold | activation + key pair | 3.115–3.444 | 0.329 | passed |
| 8 | cold | activation only | 3.095–3.405 | 0.310 | passed |
| 9 | warm-menu | activation + key pair | 3.000–3.288 | 0.289 | passed |
| 10 | warm-menu | activation only | 3.122–3.408 | 0.286 | passed |
| 11 | cpu-load | activation + key pair | 4.711–7.732 | 3.021 | passed |
| 12 | cpu-load | activation only | 2.705–5.791 | 3.087 | passed |

Activation-only passed **6/6** within 8 ms (upper bounds
3.405–6.697 ms).
The key-pair mode passed **5/6**. This is not evidence that the pair caused its
latency failure: in cell 6 the delay precedes both the recovery and the pair.
The pair itself adds 2.862–5.587 ms
of synchronous work after activation. No reason to enable it in the Lab was
established, so production remains activation-only.

### Detection

All twelve activations came through `workspaceNotification`, none through the
30 ms context-menu fallback. In the failed cell, the independent sampler places
notification receipt **8.769–8.914 ms after focus loss**; receipt-to-handler is
**0.199 ms**. The interruption itself is **9.011–9.701 ms**, definitively over 8.
The notification-to-handler span ranges from 0.085 to 1.745 ms across the matrix.
Thus the large delay in cell 6 is already upstream of our urgent recovery code.
This does not distinguish WindowServer event delivery, AppKit notification
publication, or a busy main run loop before publication; calling it an OS-only
scheduling fault would exceed the evidence. The next targeted probe must trace
those boundaries while Chrome Print activates, or compare an independent,
bounded activation detector against the notification on the same event.

### Precision

The total interruption uncertainty is <=0.5 ms in **9/12** cells. The three
remaining widths are 0.690, 3.021 and 3.086 ms, all under CPU load. Their 8 ms
verdicts remain determinate because their whole intervals lie on one side of
8 ms. A 100 microsecond request improved normal observations but did not
establish a maximum sampling gap under load.
Sampler CPU cost was 3.80–5.67% of one core during its
bounded window, median 4.77%; the measurement itself is
not free. The original 500 microsecond sampling and this campaign are not a
randomized sampler A/B, so no causal precision-improvement percentage is claimed.

### Certification decision

**No 8 ms certification.** Six successful activation-only samples cannot certify
99% reliability with 95% confidence. Even under an independent identical-trial
assumption, 6/6 gives only 60.70% as the one-sided lower bound.
The late notification was observed in the pair variant but occurred before
any pair was posted, so it identifies a timing limitation in the shared
notification-based path. That is an inference about the common mechanism,
not a measured activation-only failure in this matrix.

The 300-trial qualification campaign was **not run**. The diagnostic campaign
first exposed an unresolved upstream timing limitation and load-dependent
measurement precision. A fixed implementation, precise observation and a stated
workload distribution are needed before spending that qualification budget.
No promise is made about other apps, dialogs, display refresh rates or builds.
These measurements concern front-process identity, not rendered pixels or
proof that the human eye cannot see a focus transition.

### Installed evidence and checks

Raw logs, the initial incomplete attempt and all structured observations are in
[the measurement bundle](measurements/focus-certification-2026-09-10.json).
After the matrix, a lifecycle guard was added to discard a notification queued
before observer stop, and runner timeout cleanup was hardened. These changes
passed the automatic tier; this report does not claim a fresh live measurement
of those post-campaign changes. The input-fence callback is untouched.
Automatic validation: 432 executed, 32 opt-in skips, 464 reported; 12 tier-parser
and 13 latency-parser regressions passed. The Research_locator Lab workspace Debug build passed after integration
(`CODE_SIGNING_ALLOWED=NO`); no application was launched for this build check.
