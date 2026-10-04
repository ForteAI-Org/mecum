# ADR 0026: bind native facts to the captured window

Status: implemented; one signed-app native-field probe passes. Full workflows remain pending.

## Observed problem

On 2026-10-04, two owned Chrome windows of equal size are contained at the
same position during an application assignment. The Chromium fixture's
pixels are captured correctly, but native augmentation chooses windows by
frame alone. Both AX windows match, so the existing ambiguity guard returns
no window and the scene loses every native field.

The read-only production augmenter finds 20 native elements for the Rich Text
fixture and 45 for the Chromium fixture before assignment. During an adoption
with no input, both windows occupy 2192,1288,1200,828 and both return zero
native elements. All three Mecum observations have the same missing fields.
This establishes a geometry-only lookup defect independently of the separate
targetActivated input failures.

## Decision

Capture adapters carry the actual captured Window ID into ScenePipeline.Window.
SceneAugmenting has an identified-read requirement beside its existing
geometry-only read. An adapter that cannot fulfill the identified requirement
returns no native facts, rather than silently using geometry or focus.

AccessibilityAugmenter receives an explicit native Window ID resolver from
Integration and SeatBroker. The resolver runs on the main actor. It narrows
AX candidates to that Window ID before applying the existing frame matching
and ambiguity rules. An absent ID, failed resolution, stale frame or tied
remaining candidates yields no native facts. PerceptionCore has no Driver
dependency; the composition layer owns the WindowRelocator bridge.

AgentSession uses the window identity attested by the delivered capture's
geometry, including a host used to capture a sheet. SeatSceneProvider,
LiveSceneProvider and InteractionSceneReader also pass their actual capture
recipient. Cropped control-only scenes remain pixel-only.

The Seat still verifies process lifetime, ownership, capture coherence and
input admission. The new fact lookup neither changes target selection nor
posts input, replays commands or relaxes containment.

## Verification

Two compiled regressions fail before implementation with seven assertion
issues: identical frames lose the captured candidate, an absent identity can
select the other candidate, and ScenePipeline calls the unbound adapter.
After implementation they pass. Additional regressions verify that an adapter
without identity support cannot supply facts for an identified capture and
that the SeatSceneProvider forwards the actual captured recipient despite
another census row sharing its frame.

Evidence is under `/private/tmp/mecum-stabilization-round4-20261004` with the
`captured-native-identity` prefix. Native acquisition evidence is in
`chrome-owned-augmentation.txt`, `chrome-augmentation-during-adoption.txt`
and `release-chrome-augmentation-readonly`. Signed-app effect qualification
and required baseline results are recorded in StabilizationRounds.md as they
complete. The previous 0/3 Chromium input failures remain failures.
