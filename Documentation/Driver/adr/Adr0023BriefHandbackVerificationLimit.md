# Allow native handback to settle after brief activation

Implemented for qualification on 2026-10-04 and extended on 2026-10-05 as
recorded in the follow-up below. The current brief-handback verification limit
is two seconds, retaining identity and foreground requirements. Ordinary focus
recovery retains its 250 ms verification policy.

## Evidence

Release `d00ee49d` refuses File > New... before dispatch after its brief
Photoshop activation. One diagnostic performs one 0.2 ms focus reading, then
resumes after 343.8 ms with its 250 ms deadline already elapsed. Another reads
the correct complete identity, eligible physical window and Mecum foreground
at 263.4 ms. The post-reading deadline correction correctly refuses that late
sample. An armed profile covers a third diagnostic with two readings and
342.9 ms elapsed; AppKit/ViewBridge process key-window resignation and native
cross-process drawing synchronization during the activation cycle.

These observations show that 250 ms cannot contain the observed native
settling interval. They do not establish a general rendering bottleneck, a
self-AX deadlock or a qualified latency bound. The first profile starts after
the critical operation and is retained as inconclusive for its cause.

## Initial decision, 2026-10-04

Brief handback has a separate one-second verification limit. Its expected
activation lifetime and polling cap use that same limit. No further activation
request is made while waiting. Two agreeing readings must name the complete
expected identity, the workspace foreground and an eligible physical window,
and both must finish before the live deadline. Cancellation still refuses.
An unverified return still prevents menu dispatch and never permits replay.

This is a bounded settling allowance for the observed native transition, not a
change to ordinary focus recovery's window, closure protection or preparation
lifetime. A different foreground chosen by the person retains its existing
authority.

A controlled regression with a 300 ms first identity reading fails under the
old limit. The late-reading regression separately requires refusal after the
new limit. Neither controlled result establishes the native command's effect.

## Qualification limit

Signed-app repetitions must verify both handback and the requested command's
effect with clean closure. A returned foreground alone does not qualify New
Document or other Adobe workflows. All failed diagnostics remain recorded.

Release `ef3b05dc` verifies the expected Mecum handback in 369.7 ms, following
Photoshop menu readiness at 1051.2 ms. Its single subsequent menu press still
has no observed new-modal effect, and closure leaves null status with the
same four owned documents. This is one native handback qualification; command
effect and repeated workflow qualification remain open.

Three later Window > Probe.png attempts verify handback at 226.1, 371.8 and
352.4 ms, but none changes the active document. A separate New Layer attempt
also has no observed modal effect. [ADR 0024](Adr0024DispatchAdmittedAdobeMenuBeforeHandback.md)
records the subsequent primary-route candidate; unlike this preparation-only
policy, it preserves a possible command effect when handback fails.


## Follow-up, 2026-10-05

The one-second qualification bound is insufficient in P10-7 on macOS 27.0.1
build 26A434. The complete expected identity and eligible physical window first
match at 829.5 ms; the next reading finishes at 1010.4 ms. The late-reading guard
correctly refuses that reading. New was dispatched once and its modal effect
was observed, so the result remains `acted_unverified` and is never replayed.

Brief handback now allows at most two seconds, still measured after its one
native return request. The expected-activation lifetime and finite poll cap
use the same limit. Ordinary recovery's 250 ms policy and target/menu readiness
bound remain unchanged. A controlled pair of identity readings at 829.5 ms
and 1010.4 ms fails under the one-second policy and passes under the new bound;
the existing post-deadline test still requires refusal beyond the new limit.
This is an empirical settling allowance, not a measured universal latency bound.

The foreground witness is also read after destination geometry and visibility.
A regression changes foreground during the second validation: the old ordering
incorrectly reports ready; the new ordering refuses confirmation and preserves
the chosen foreground. It sends neither another command nor another return
request. Complete identity, physical eligibility, two timely matching readings
and cancellation remain necessary. The old generic T4 readiness refusal and
the S6/F1 document/tool changes are not attributed to these handback changes.

M6 and M3 diagnostic repetitions preserve all observed document/tool state and
finish their menu handbacks inside the old one-second bound. The first timing
probe separates scheduler waits (up to 373.6 ms) from a focused-window read
(up to 496.9 ms); it does not isolate that read's internal cause when Mecum
itself is the destination. The second probe observes Codex as destination:
AX briefly times out while native focus settles, then two valid readings confirm
return. These are distinct observations, not evidence of a self-AX deadlock.
The temporary probes are removed from the retained source.
