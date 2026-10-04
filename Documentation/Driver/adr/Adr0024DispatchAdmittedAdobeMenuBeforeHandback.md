# Dispatch an admitted Adobe menu command before handback

Implemented for qualification on 2026-10-04 within the owner's authorized
Adobe stabilization work. The candidate changes the primary Adobe menu route;
it never retries an unverified background invocation.

## Evidence

Release `ef3b05dc` verifies four handbacks to the expected Mecum window at
369.7, 226.1, 371.8 and 352.4 ms. File > New... and three independent
Window > Probe.png commands are acknowledged after those handbacks without
the requested new dialog or active-document title. An independent
Layer > New > Layer... command likewise leaves the scene and discovery
unchanged. Four owned documents remain and each session closes with null
status. These measurements isolate command effect from the earlier handback
failure; they do not prove that every Adobe command requires foreground.

## Decision

The broker selects a bounded, explicit menu-command scope only for its Adobe
UXP classification. Listings, missing paths and policy refusals do not request
foreground. After readiness, the selected adopted identity, both foreground
witnesses, deadline, cancellation, Seat state and absence of a blocking dialog
must still agree. The command resolves its admitted path again and presses the
fresh enabled AX item once, before requesting the person's attested window.
Readiness predicates remain read-only.

The existing two-second readiness and one-second handback bounds apply.
The callback is synchronous and is not retained after the scope returns.
New modals are followed after the scope ends. A command's possible effect is
retained when handback fails: the outcome is unverified, carries the focus
failure and instructs observation before more input. No background replay,
key-equivalent fallback, clipboard operation or other foreground input route
is added. Other families keep their existing menu route.

This extends the limited exception in ADR 0013 and supersedes ADR 0020's
post-handback dispatch for the Mecum broker. Its package-only Seat entry point
does not turn the public readiness operation into an input callback.

## Qualification

A controlled regression first executes the scoped callback after handback and
fails its target-foreground and ordering assertions. Moving it before handback
must pass alongside cancellation, identity loss, policy refusal, single press
and partial-effect regressions. Signed Mecum repetitions must independently
verify menu effects, exact text, modal withdrawal, document counts and clean
closure. Until those repetitions finish, this remains a candidate, not Adobe
workflow qualification or qualification of another UXP host.

On Release `4e6b996e`, all three independent Window > Probe.png and New Layer
cycles still return unverified with no intended effect. The four owned
documents remain and session cleanup succeeds. An independent native AX
control also has no effect; a subsequent sample finds an AppKit menu tracking
loop. Its onset is unknown because no earlier sample exists. A later Mecum
zoom-field click does not release the failure. This candidate therefore has
passing controlled checks but no native command-effect qualification. It must
not be used as evidence that Adobe is stable or that foreground dispatch fixes
the observed failure. See the dated results in
[stabilization rounds](../StabilizationRounds.md#scoped-adobe-command-candidate-native-result).
