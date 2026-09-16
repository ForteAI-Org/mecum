# Why focus recovery spends milliseconds in window reads and the first key record

Date: 2026-09-10. Scope: diagnosis on macOS 27.0 build 26A5425a, not a new
production optimization. The installed kit's 210 baseline/installed-manifest
paths remained unchanged. Temporary source instrumentation was removed after
saving its patch. Three additional real Chrome Print recovery trials passed
all existing identity, focus, cursor/HID and teardown assertions.

## Finding

The large costs are inside macOS calls, mostly elapsed time without CPU execution
on the calling thread. Swift dictionary conversion and record preparation are
small. Rewriting those loops or switching to Release cannot account for the
observed multi-millisecond delays. This does not establish an irreducible OS
latency floor: the same first-record call varied from 0.993 to 7.967 ms, and one
new trial bounded the front-process interruption below 8 ms.

These are medians of three live trials, in milliseconds. A separately measured
empty clock control was subtracted and clamped at zero (328 ns wall, 136 ns
thread CPU). Raw readings remain in the linked JSON. Phase medians must not be
summed into an invented end-to-end median.

| Operation | Elapsed | Calling-thread CPU |
| --- | ---: | ---: |
| `CGWindowListCopyWindowInfo` itself | 6.456 | 0.148 |
| Bridge its result to Swift dictionaries | 0.086 | 0.086 |
| Parse PID, Window ID and geometry | 0.032 | 0.032 |
| Build the first key record | 0.006 | 0.005 |
| `SLPSPostEventRecordTo`, first key record | 7.716 | 0.042 |
| Build the second key record | 0.005 | 0.004 |
| `SLPSPostEventRecordTo`, second key record | 0.068 | 0.022 |

More than 99% of the first-record call's median elapsed time and roughly 98% of
the window call's median elapsed time are not CPU execution on the caller.
This subtraction alone cannot distinguish a thread blocked in an IPC wait from
scheduler delay or prove which server-side operation is slow.

## Window reading: a concrete connection cost

Disassembly of this build resolves the public window-info call to
`SLWindowListCopyWindowInfo`. Its path synchronizes a pending SLS/Core Animation
transaction, then calls `copy_window_description_list_internal_direct`. That
function gets a session port, requests the descriptions and decodes a property
list. It requests substantially more metadata than the three fields used by
the recovery guard.

A separate one-second, 1 ms stack sample of a read-only window-list probe found
221 samples beneath `SLWindowListCopyWindowInfo` at its description-list call:
178 were in `get_session_port`, including 157 in its Mach reply wait and 21 in
server-root lookup. A further 36 samples were in the description RPC's Mach
reply wait. Only six were in property-list decoding on that branch. These are
sample counts from an intrusive profiling run, not precise durations and not
percentages that can be assigned to the live recovery trials.

The relevant chain was:

```text
CGWindowListCopyWindowInfo / SLWindowListCopyWindowInfo
  copy_window_description_list_internal_direct
    get_session_port
      CGSLookupServerRootPort / bootstrap lookup
      mach_msg -> mach_msg2_trap
    description request -> mach_msg -> mach_msg2_trap
    property-list decoding
```

The transaction synchronization is present in disassembly but was not the
dominant sampled wait. It should not be called the proven cause of the 6.456 ms
live result. The session-port lookup is a concrete cost of the reader worth
removing from a replacement path.

Two isolated, unprofiled probes performed 51 reads each. Excluding each process's
first call, the Debug median API time was 0.876 ms and the Release median was
0.578 ms. Swift bridging plus parsing were small in both. These were separate,
unpaired runs under different scheduling conditions, so the difference is not
an attributed Release speedup. The first API calls took 21.786 and 88.833 ms,
respectively: cold setup must remain separate from warm/live recovery costs.

A next reader experiment should use the already-open connection and obtain only
fresh identity/geometry information. It must still enumerate every visible
window belonging to the activating PID, including new dialogs. Caching old
frames or omitting unknown owners would change the authorization predicate.
The earlier lightweight private iterator returned incomplete PIDs; this remains
a correctness blocker for replacing the current reader. The newly inspected
owner/PSN accessors are leads, not a validated replacement.

## First key record: synchronous delivery, not expensive record construction

The first record is 256 bytes of temporary stack storage with a declared 248-byte
payload. Its preparation cost is approximately six microseconds. The slow span
starts at the private call, not in the Swift field writes.

The inspected client path is:

```text
SLPSPostEventRecordTo
  copy_primary_conn_send_port (synchronous internal queue access)
  CGSEncodeEventRecord
    _SLEventRecordCreateData
    encodeEventRecordForPostTo
      cached client permission check
      synchronous Mach request/reply
```

On this build `SLSTCCService::requestAccess` uses a once flag and a cached result.
It is not evidence of an expensive fresh client permission request for every
record. The server separately checks synthesis authority, decodes the record
and routes it through `CPXPostEventToProcessOnly` before replying. No permission
check was modified or bypassed.

The live timing proves the wait is inside this private call. It does not yet
partition the 7.716 ms among the internal connection queue, encoding, IPC
scheduling and server work. The first/second disparity is consistent with work
or contention after activation, but that specific cause is still a hypothesis.
These results do not establish a fixed 7 ms delay. The production code has no sleep between
the key records; the published
[yabai key-window recipe](https://github.com/koekeishiya/yabai/blob/master/src/window_manager.c)
likewise sends the pair sequentially. Its separate same-application activation
workaround is not present in this kit path.

Reducing the record builder cannot remove this wait. A useful semantic experiment
is to determine whether the preceding activation already restores the exact
remembered window, making the extra pair unnecessary in a narrowly verified
case. That experiment must cover multiple windows and dialog states, with input
still gated until the same focused Window ID is confirmed. Removing either
record or changing request ordering has not been validated by this diagnosis.

## App activation and correct-window verification remain distinct

In three of the prior five trials, the independent sampler's upper bound for
returning to the user's front process preceded the approximate start of the
first key record. The comparison derives that start from request completion
minus the two measured record spans; it is not a direct key-window timestamp.
It shows why the whole key-record duration cannot automatically be counted as
time the user's application remains inactive. It does not prove the correct
window has become key or that pixels have updated.

The three new trials, with temporary instrumentation and the existing independent
sampler, produced these front-process interruption intervals:

| Trial | Interval, ms | 8 ms verdict | Functional recovery |
| --- | ---: | --- | --- |
| 1 | 5.280..6.596 | passed | passed |
| 2 | 10.652..20.168 | failed | passed |
| 3 | 5.187..8.846 | inconclusive | passed |

The original NSWorkspace detection-to-frontmost observations were 9.784, 23.970
and 25.824 ms. Correct-window verification and command resumption took 461.872,
692.301 and 463.673 ms. None of these different metrics should be substituted
for another. One interval below 8 ms is evidence of feasibility in that trial,
not a reliable bound or a demonstrated optimization.

## Reproduction and evidence

- [Raw live diagnostic trials](measurements/focus-cost-live-2026-09-10.json)
- [Control-adjusted phase summary and isolated reads](measurements/focus-cost-summary-2026-09-10.json)
- `/tmp/agentseat-focus-cost-diagnosis/temporary-instrumentation.patch`
- `/tmp/agentseat-focus-cost-diagnosis/window-stack.sample.txt`
- `/tmp/agentseat-focus-cost-diagnosis/*disassembly.log`
- `/tmp/agentseat-focus-cost-diagnosis/live-costs.trial-1.log` through `trial-3.log`

The live command was run from the temporary kit copy after adding only diagnostic
measurements:

```sh
python3 Scripts/measure-focus-latency.py --runs 3 \
  --output /tmp/agentseat-focus-cost-diagnosis/live-costs.json
```

Exit 1 means the budget was not met across the whole series; all three counted
functional tests executed and passed. No skips were counted as measurements.
The stack probe only read metadata and did not change focus or send input.
Disassembly used an owned helper with SkyLight loaded; it did not attach to or
execute private setters in other processes. Public API reference:
[Apple window information API](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)).
