# ADR 0028: restore the consumer through its own AppKit window

Status: implemented; controlled checks and three native cancellation cycles pass.

## Observed problem

Two Chrome file-picker cancellations through signed Mecum withdraw the
panel and expose the parent with zero selected files. After the second,
Chrome is foreground and the next adoption refuses because the Seat is
waiting, although the worker has no session. No drag is delivered.

The owned Session log records target activation shortly after both Cancel
posts. The first recovery reports a restored destination; the next has no
destination or prepared action and waits for the user. This establishes a
focus/continuation failure, not its complete native cause. Evidence is in
`release-owned-seat-stream.log` and `release-chrome-extended`.

The ordinary restoration path uses the private front-order request even
when the destination is the consumer itself. Only primed restoration asks
AppKit to make the exact local window key and activate its own application.

## Decision

Every prepared destination in the consumer process uses the same exact
AppKit request. A missing, invisible or non-keyable local window refuses;
there is no fallback to the private request or another local window.
External processes retain the existing private request and their configured
key-record policy. The preparation proof, recovery destination rules,
deadlines and physical input guards are unchanged.

This corrects a difference between ordinary and primed consumer handback.
The fresh signed-app campaign closes the reproduced continuation failure:
three consecutive cancellations and a fourth input-free adoption succeed
without outside recovery. Other external-activation cases remain separate.

## Verification

The compiled ordinary-route regression previously calls the remote request
and fails two assertions. The corrected exact-window request has no priming
switch. Tests verify local window numbers across successive handbacks, local
refusal without a remote fallback and unchanged external routing.
`ordinary-own-focus-red.log` retains the failure. The combined focused run
in `dropdown-own-focus-green.log` passes 127 tests in nine suites.
Required baseline, host and native results follow in
[StabilizationRounds.md](../StabilizationRounds.md).


Release `4c59af9c` completes three file-picker open/Cancel/parent/close cycles
and a fourth input-free adoption/observe/close. Native tool observations show
zero selected files and no remaining picker. The independent 0.5-second
foreground watcher records Mecum active in all 600 samples; the Session log
shows all Cancel-triggered recoveries returning to ready at the same local
window. Sub-cadence foreground transients are not excluded. This qualifies
the reproduced continuation behavior on the current Mac, not all recovery
situations. Evidence is linked in the stabilization round above.
