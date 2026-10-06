# Prepare TextEdit menu commands

Status: candidate, 2026-10-04. Qualification is recorded in
[the stabilization rounds](../reports/StabilizationRounds.md).

## Evidence

Release `60979ddf` completes three TextEdit Unicode replacements and three
single-character selection replacements through Mecum. Independent scenes
preserve two leading spaces, the final LF and UTF-16 selection. In each fresh
session, Edit > Undo Typing and Edit > Redo read disabled; both refuse, and the
text remains unchanged. This does not establish that other native hosts need
the same preparation.

## Decision

The broker uses the existing bounded menu-command foreground scope for the
positively identified `com.apple.TextEdit` bundle, as well as Adobe UXP. It
reads readiness while both foreground witnesses agree, resolves the menu
again and dispatches once before verified handback. Missing, destructive or
listing-only paths never activate; cancellation, changed identity and failed
handback retain the existing refusal and uncertain-effect semantics.

Ordinary text insertion and key delivery keep their existing route. Other
AppKit hosts retain their existing menu path until separately qualified.

Native qualification on `10989743` observes Undo restoring the exact text,
but Redo refuses before dispatch: its cold `Redo` title validates into
`Redo Typing` during activation. A bare terminal English `Undo` or `Redo`
therefore admits exactly one current title with that verb and a word-boundary
suffix. An exact title always wins, including a disabled exact item. Multiple
matching titles refuse as ambiguous; all other commands retain exact matching.
This qualification does not extend to localized dynamic titles.

## Verification

The existing menu and brief-activation tests cover dispatch ordering, current
item identity, deadline, refused readiness, no replay and failed handback.
Signed Release `3512aee9` completes three fresh TextEdit sessions through
Mecum. Each replaces the text with two leading spaces, Unicode and a final LF,
selects the first UTF-16 unit, inserts Z, restores the original text and
selection with Undo, then restores Z and the caret with bare Redo. Independent
observations establish every text effect. All three sessions close with null
status. Menu verdicts remain conservative when the window signature is
unchanged; their attached scenes are not replaced by an assertion of success.

The dynamic-title regressions fail before the correction and pass afterwards;
the clean complete offline baseline passes 2332 executed tests, 93 skipped,
2425 reported in 28 runs. This qualification does not repair Photoshop's
independently observed outstanding native menu tracking loop.
