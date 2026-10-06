# Expanded installed-app checks through Mecum

On 2026-10-03 the signed Debug Mecum app was exercised on Mac16,1,
macOS 27.0.1 (26A434), with exclusive desktop use authorized by the operator.
Stage Manager was enabled; its setting was not changed. These nine additional
installed apps extend the [initial application flows](ApplicationFlowChecks.md)
to fourteen installed apps plus the separate official CEF sample.

The checks use Mecum's conversation, discovery, Seat broker, perception,
Engine actions and Driver together. Setup and assisted cleanup use an
independent desktop controller. Such intervention does not turn a failed
Mecum flow into a pass. Synthetic documents and reversible controls keep the
requested effects independently inspectable.

The remaining failures and their closure criteria are tracked in
[stabilization rounds](StabilizationRounds.md). The first round adds an
initial-window identity guard. Its follow-up identifies containment recency and
verifies six successful Safari A/B openings with fresh observations and clean
closure. Safari input remains unresolved.

## Additional application matrix

| App and surface | Requested flow and observed effect | Verdict and limits |
| --- | --- | --- |
| Calculator 12.0, native | Four separate sessions calculate `7+8 = 15` and `9×6 = 54`, then clear to `0`. Raw Mecum observations contain both results; independent desktop AX reads confirm the final zero. | First cycle needed recovery after `geometryChanged`, before the clear took effect. The following two cycles and the repeat in the rebuilt app completed cleanly. Arithmetic passes; an app-wide reliability rate is not measured. |
| Safari 27.0.1, WebKit | Owned new window with local HTML probes for text, multiline text, checkbox, counter, scrolling, dropdown, file panel and drag/drop. | Text, counter click and scroll fail with `subtreeUnreadable`; the other five checks are blocked or not attempted. The first exact-title `open_session` returns another existing window's scene. That Seat was closed without input; a later exact-title call returns the correct fixture. Cause remains unestablished. |
| MarkEdit 1.35.0, native shell and WebKit editor | Replace with `Mecum MarkEdit é 🧪` plus LF and `Seconda riga`; Find `Seconda`; close Find; native Open/Cancel. | Unicode and both lines are observed, as are Find's one result, its withdrawal and the Open panel's withdrawal. Exact replacement remains inconclusive: native AX shows trailing blank lines, and the subsequently saved file contains one extra terminal LF. Save normalization is not distinguished from insertion. Autocomplete popups were explicitly dismissed. |
| Dictionary 2.3.0, native | Search `automation`, then inspect a definition, replace with accented text and clear. | The first search fails with `geometryChanged`. A reopen confirms an empty field, and a deliberate second attempt reproduces the failure. Observation then reports no assigned application while status retains a session ID. Definition, accented replacement and clear are unqualified. Both Seats close. |
| Clock 1.1, native | World Clock → Stopwatch → Timers → World Clock. | Pass for this navigation: distinct stopwatch and timer controls and the restored World Clock tab are observed. No stopwatch, timer or alarm was started, and no item was created. |
| Prism Launcher 11.0.2, Qt | Add Instance → New Instance dialog → Cancel → main window. | Pass for the dialog round trip. No instance, download or account change. This supplies a second installed Qt application's selected-flow evidence alongside Resolve; it is not a full Qt qualification. |
| Preview 11.0, native | Owned six-page PDF: Go to page 3, search `CampaignMarker5`, zoom and scroll. | The Go to Page sheet opens, but entering `3` fails with `targetActivated`; subsequent input is refused while the Seat waits. An independent controller cancels the owned sheet and verifies Page 1 with no modal. Navigation fails with assisted recovery; search, zoom and scroll are not executed. |
| Finder, native | Owned three-file folder: select `Beta.txt`, Get Info/close, Quick Look `Alpha.txt`/close. | Blocked at adoption. The requested 920×436 pt window is read by WindowServer at 128×97 pt. The tool reports return to its previous location. No requested file operation or transient window is created. |
| QuickTime Player 10.5, native | Launch; native Open or Open Location panel; Cancel without media, URL or recording. | Blocked at adoption. The requested 891×448 pt panel is read at 121×97 pt, and return cannot be confirmed. No requested functional row passes. The test-launched app is subsequently quit through the authorized desktop, with an independent inventory confirming exit. |

The earlier matrix records TextEdit, Photoshop, Resolve, Chrome, GitHub
Desktop and the CEF sample. Those results remain scoped: Photoshop editing
and reliable New Document cancellation, browser menus, Electron dropdowns
and CEF drop effects still have failures or missing evidence.

## Correction from the Calculator checks

Several numeric and operator clicks changed Calculator's display while the
tool called them dead clicks and proposed another click. Stable element IDs
and numeric display changes do not necessarily produce a classified
structural effect. An unchanged window census cannot establish that nothing
changed inside the window.

The Engine now retains `acted_unverified` and an unknown confirmation, but
describes the missing effect classification and asks for a fresh observation
before deciding on further input. It explicitly rejects repeating a click
solely because of that verdict. Neither success classification nor automatic
retry behavior is broadened.

`ActionEngineTests.displayUpdateRemainsUnverified` exercises the actual
`clickVerified` path with two numeric display changes. It failed before the
correction, with six assertion issues, then passed. It checks the unknown
outcome, returned display, single delivered gesture and absence of misleading
failure/replay advice. Existing census expectations are adjusted to its
observable scope.

After rebuilding and restarting the exact signed app, a live Calculator
repeat returns `15` and `54` in fresh observations and clears to `0`. Raw
`acted_unverified` responses contain the corrected advice. That repeat has
no geometry interruption; final `status` reports `session: null`. This fixes
guidance that could cause duplicate input, not the separate geometry,
window-selection, focus or subtree failures.

## Validation and retained evidence

- `swift build --product mecum`: passed.
- `make test SWIFT=swift`: passed, 2,224 executed, 93 skipped, 2,317 reported,
  28 bundles, `problems: []`.
- Focused ActionEngine, ElsewhereGuide and ActVerification suites: passed,
  33 tests across three suites; the new regression was first observed failing.
- Signed app build and `build-for-testing`: passed.
- `xcodebuild -project MecumApp/App/Mecum.xcodeproj -scheme Mecum
  -configuration Debug -destination 'platform=macOS' -derivedDataPath
  /private/tmp/mecum-app-uxp-20261003/AppFlowDerivedData test-without-building`:
  passed, 320 tests in 59 suites. The first sandboxed attempt could not write
  Xcode's caches; the authorized run with normal cache access passed.
- `git diff --check`: passed.

The rebuilt Debug executable's SHA-256 is
`d92259f776693c2709cdb1a8992232ad4cb9ace1ee35460a9d31e8546a2be369`.
The app's version is 1.0. Detailed test logs, scoped tool records, app metadata,
synthetic fixtures and the byte comparison are retained locally under
`/private/tmp/mecum-broad-campaign-20261003`. Tool records were read only for
the dedicated test worker and the campaign interval. Personal window titles,
account names and document contents are omitted from this report.

Final Mecum status is idle with no Seat. Dictionary, Clock, Prism and QuickTime
test-launched processes have exited. The owned Safari window, PDF, Markdown
document and Finder window are closed. MarkEdit's saved synthetic file was
moved from the initially selected iCloud location to the local evidence
directory; the cloud source is absent. No user document was saved or discarded.
Existing unrelated checkout changes are preserved; no commit or push was made.

## Launch assessment

These checks do not establish a percentage of successful workflows. They
cover selected flows on one Mac, one OS build and a Debug app. Blocked adoption
and interrupted modals prevent whole sequences, and manual recovery must
remain visible in the results. Automated baseline success does not qualify
the skipped live rows or erase these application failures.

Before claiming that ordinary flows run with few errors, the remaining
priorities are:

1. Establish and enforce the selected window's identity across opening and
   first observation. Reproduce Safari's exact-title mismatch with an owned
   multiwindow fixture and verify refusal before input to a different window.
2. Reproduce the full-size/thumbnail disagreement and loss of assignment on
   owned native windows. Check adoption, focus transitions and return together;
   the current geometry refusal is evidence, not permission to loosen checks.
3. Recover owned modal focus transitions without outside intervention, then
   repeat Preview and Photoshop effects with independent document state.
4. Qualify the remaining editor, menu, dropdown, drag, IME and multidocument
   flows, followed by Release-build repetition and the supported OS matrix.

The initial 65/100 maturity estimate must not be interpreted as 65% or 70%
measured reliability. This broader campaign supplies concrete counterexamples
to describing all ordinary flows as already dependable.
