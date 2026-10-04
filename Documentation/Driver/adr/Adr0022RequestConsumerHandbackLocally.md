# Request the consumer's brief handback through AppKit

Implemented for qualification on 2026-10-04. This changes the request for an
own-process destination, after its existing participant attestation. It does
not change external activation or the verification required for readiness.

## Evidence

Signed Release `25a4fcd4` reaches Photoshop foreground readiness after 126.0 ms,
then refuses File > New... before dispatch. At the end of the 250 ms handback
verification it reads no focused window and no workspace foreground process.
A later independent reading finds Mecum active and Photoshop inactive. The
same four owned documents remain and session closure leaves null status.
This diagnoses a failed handback observation, not successful menu behavior.

The current request uses the private remote-process path even when restoring
the consumer itself. The candidate uses AppKit for that consumer request. Its
effect must be verified in the signed app; neither its request code nor the
controlled routing tests prove native activation.

## Decision

Only a brief-activation request with an attested destination in the consumer's
own process selects the local route. Resolve that exact number through the
consumer's `NSApplication`; require an existing visible window that can become
key, request it as key and request application activation. Do not order all
windows forward, discover another destination or retry the remote route after
an absent local window. Ordinary recovery and all external destinations keep
their existing remote requests and key-record policies.

AppKit activation is asynchronous and may refuse. The same identity,
workspace foreground, physical visibility, exclusion from the virtual display
and two agreeing observations within the live deadline still verify the handback. Failure
still refuses the menu before dispatch. No automatic replay is introduced.
The original limit is 250 ms; the later separate allowance is recorded in
[ADR 0023](Adr0023BriefHandbackVerificationLimit.md).

## Qualification limit

Native repeats must establish the handback and the intended command's effect
separately. A verified return cannot qualify New Document, Return, editing or
other UXP hosts by itself. Failed candidates remain in the stabilization record.

Release `5a1204ec` still refuses before dispatch. Its final reading now sees
the expected window number, owner, physical body, eligible state and workspace
foreground, but the required two complete, timely identity matches are not yet
verified. The same four documents remain and the session closes with null
status. The local request does not by itself close the failure.
