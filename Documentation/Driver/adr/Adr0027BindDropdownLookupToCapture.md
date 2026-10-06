# ADR 0027: bind dropdown lookup to its captured window

Status: implemented; controlled checks and three signed-app Chrome selections pass.

## Observed problem

Chrome's owned window has the WindowServer title `Mecum Chromium App Flow`
and the AX title `Mecum Chromium App Flow - Google Chrome`. The dropdown
selector passes the first title into a native lookup that requires the
second to be exactly equal. Two signed-app `select` calls therefore refuse
with `windowNotUnique` before requesting an opening. Both fresh observations
retain Alpha and no popup. A third attempt clicks the pixel caption instead
of using `select`; it is a separate ineffective variant, not a third
reproduction of the same native lookup failure.

The native-title difference is independently recorded in
`chrome-owned-geometry-after.txt`. The action evidence is in
`release-chrome-extended`, under the local stabilization evidence directory.

## Decision

The Seat dropdown path supplies DropdownOpening.Window with the actual
captured process, window number and frame. Integration supplies the native
ID resolver. AccessibilityWindowMatching narrows by identity before applying
its existing geometry contract. An absent, stale or ambiguous window refuses;
neither its title nor the focused window is a fallback. The existing
title-based overloads remain available to existing consumers.

Before/after full-window scenes also receive the capture identity and native
facts. Control-only crops and display crops of a popup remain pixel-only.
Native lookup accepts an exact title, value or description on a dropdown
role; it does not parse or guess a rendered compound label. Its walk reaches
the same depth limit as native augmentation.

Arrow routing starts from the control's native value when available.
Verification accepts a changed native popup/combo value at the original
control's position, or the existing visible pixel value there. A matching
value in a neighbouring control or text editor does not prove selection.
The Driver's menu ownership, action admission, cancellation and no-replay
rules are unchanged.

## Verification

The extracted former value predicate fails a compiled native-value
regression. The corrected predicate passes it and preserves negative cases
for an unchanged dropdown, another position and an editor's value, together
with the existing pixel-value case. Capture identity and geometry have the
existing matching regressions. Focused popup, scene and capture suites pass.

The sandbox cache refusals and intermediate import/geometry compilation
errors are retained as setup/build failures, not failing behaviour tests.
`dropdown-native-value-red-final.log` is the compiled behavioural failure;
`dropdown-capture-identity-green-final.log` passes 55 tests in six suites.
Required baseline and signed-app outcomes follow in
[StabilizationRounds.md](../reports/StabilizationRounds.md).


## Composition follow-up

The signed `4c59af9c` exact-name probe exposes a separate connection defect:
select's attached scene has 15 OCR-only elements, while ordinary observe has
48 including the actual AX popup and field IDs. Both brokered and direct
session adapters construct a text-only pipeline for select. They now supply
`ProductionPerception.pipeline()`, the complete factory already used by
ordinary observation. This connects the selector's capture metadata to a real
native augmenter. The native exact-name probe is the relevant failing loop;
the prior pure tests did not cover the session adapter's construction.
The failed combined menu campaign and separate context-menu residue remain
recorded in StabilizationRounds. Fresh signed-app results are pending.


The complete-pipeline repeat resolves the native control but observes Chrome's
contextual page menu instead of its values. Opening always requests AXShowMenu.
The retained action decision prefers AXPress on the uniquely scoped popup/combo;
Show Menu-only controls retain their prior route. It never attempts a second
action after a request. The compiled prior decision fails three assertions;
the final decision passes the primary-action, native-value and capture checks.
The complete-pipeline connection is observed, while real dropdown selection
still requires the fresh primary-action candidate's app repetition.


Release `9e5e4f34` selects Beta, Gamma and Alpha in three fresh Mecum sessions.
Each begins at a different native value, observes the exact requested value
at the same control after selection, verifies popup withdrawal and closes
with null status. No outside recovery or replay occurs. This qualifies the
reproduced dropdown behavior on the owned Chrome page. Other dropdown hosts
and the separate context-menu path still require their own evidence.
