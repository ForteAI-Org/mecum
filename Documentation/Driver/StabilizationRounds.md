# Stabilization rounds after the installed-app campaign

This is the ordered list of remaining failures and qualification gaps from
[initial app flows](ApplicationFlowChecks.md) and the
[expanded campaign](ExpandedApplicationChecks.md). It records observed
problems and closure evidence, not an estimated reliability percentage.
Changes remain uncommitted. Each round uses an owned fixture, a regression
where the real contract is testable, and a repeat through the signed Mecum app.

| Round | Problem to resolve | Evidence required to close it | Current state |
| --- | --- | --- | --- |
| 1 | Opening a named window can return a different window's scene, seen in Safari. | Bind the first observation to the attested adopted identity; refuse a different identity before its scene or input is exposed. Test same-ID retitles and later deliberate window changes. Repeat opening both owned Safari windows in alternating order. | Resolved for the owned Safari A/B regression: initial identity is guarded; containment recency is excluded from selection. Six alternating initial opens and fresh observations pass, with clean session closure. Input remains a separate qualification. |
| 2 | Full-size native windows become thumbnails during adoption or return; geometry interruption can leave a session ID with no assigned app. | Reproduce Finder, QuickTime and Dictionary on owned windows with Stage Manager enabled. Verify fresh identity, real body, placement, assignment and handback together. An unrecovered failure must release the session and explain any remaining return obligation. | Partly corrected in controlled regressions: a stable thumbnail cannot confirm adoption; staged windows must reach the requested position; a lost assignment closes the worker session and retains cleanup warnings. Native app repetitions remain pending. |
| 3 | An owned modal takes foreground and leaves the Seat waiting, seen in Preview and Photoshop. | Open, edit and cancel an owned modal repeatedly through Mecum, with an observed effect and a verified return to its parent. No outside desktop recovery and no replay of unconfirmed input. | Partly corrected: positively identified native modal dialogs now join discovery beside an onscreen document. The real Photoshop Open panel is listed with its attested body; app cancellation and Preview repetitions remain pending. |
| 4 | Photoshop flow results remain uncertain: New Document cancellation created a document, name replacement retained a prefix, editing and undo/redo are unqualified. | Independently count owned documents before/after cancel and Return; verify exact name replacement, changed pixels, undo/redo, scroll/drag and switching between owned documents. Repeat from Mecum's UI. | Open. Driver-tier passes do not qualify the full application path or other UXP hosts. |
| 5 | Exact text and selection cannot always be established, including MarkEdit's terminal LF and TextEdit's missing selection range. | Distinguish insertion from save normalization with controlled Unicode/LF/CRLF fixtures; verify raw values or bytes and actual selection ranges. Make the tool's verdict match the evidence. | Open. Find and modal withdrawal work in MarkEdit; exact replacement remains inconclusive. |
| 6 | Menus and dropdowns intermittently refuse or retain their previous value in Chrome, GitHub Desktop and CEF. | Open, choose and dismiss each owned menu, verify its resulting control value and withdrawal, then repeat from Mecum. A delivered event alone is insufficient. | Open. `subtreeUnreadable`, `contextMenuNeverOpened`, missing/ambiguous controls and unchanged values observed. |
| 7 | Drag can be delivered without the intended drop; some native operations still depend on the physical mouse location. | Verify the target's received payload, count and state for HTML, Qt and native controls. Keep unsupported native drag explicitly unqualified until its actual effect is proven. | Open. CEF retained `Drops: 0`; Chrome has one observed HTML drop. |
| 8 | Selected-flow checks on one Debug build do not establish release or OS reliability. | Run Release repeats and mixed-app open/operate/close cycles; record every requested case, observed effect, interruption and cleanup. Repeat the supported OS/hardware matrix and qualify IME and multidocument cases separately. | Open. Current complete-path evidence is macOS 27.0.1 on Mac16,1. |

The Calculator guidance correction is already verified through a rebuilt app:
unclassified display changes keep an unknown outcome and require checking the
intended result before more input. They no longer assert a dead click or invite
replay. This closed correction does not close the remaining rounds above.

## Local release acceptance matrix

The requested 70–80% target means completed owned workflows on the rebuilt
signed Mecum app, not the percentage of passing unit tests. This matrix is
declared before the release repeats. It has 25 workflows, each repeated three
times: 75 planned attempts. At least 60/75 attempts must complete for the 80%
local target; 53/75 meets 70%. A failed, refused, blocked or independently
rescued attempt remains in the denominator. An unrun attempt is pending and
cannot be a pass. Every attempt must verify its effect and clean session
closure; silent window substitution invalidates the attempt.

| Family/app | Owned workflow | Attempts/results |
| --- | --- | --- |
| AppKit, Calculator | Clear, enter arithmetic, observe exact result, clear, close | Release `51666898`: 3/3, separately observed 0 → 15 → 0 and null status each time, no geometry interruptions. Earlier `cbee7cbb`: 1/3 followed by 2/3, with failures retained; `aa5790ad`: 3/3 retained. |
| AppKit, TextEdit | Replace Unicode text, select a range, undo/redo, inspect exact text | Pending ×3 |
| AppKit, MarkEdit | Find, cancel, replace multiline Unicode, save owned copy, inspect bytes | Pending ×3 |
| AppKit, Clock | Navigate World Clock, Stopwatch and Timers without starting a timer | Release `cbee7cbb`: 3/3 pass; distinct native selected tabs/controls, restored World Clock and null status; nothing started or created. |
| AppKit, Preview | Go to page 3 in owned PDF, verify page, return to page 1 | Pending ×3 |
| AppKit, Preview | Search marker, cancel, zoom and scroll owned PDF | Pending ×3 |
| AppKit, Finder | Open owned folder window, observe full body, close session and verify handback | Pending ×3 |
| AppKit, QuickTime | Open owned file picker, cancel, observe parent, close | Pending ×3 |
| AppKit, Dictionary | Search synthetic word, verify result and full body, close | Pending ×3 |
| WebKit, Safari | Replace owned field, click stateful button, verify values, close | Candidate `92f86789`: 3/3 pass. Earlier `1a0d7339`: 1/3, retained in history. |
| Adobe, Photoshop | Open New Document, cancel, independently verify document count | Candidate `6443dc84`: 3/3 pass; independent Window menu lists the same four owned documents before and after. Later candidates require fresh repeats. |
| Adobe, Photoshop | Create named owned document with Return, verify and close without saving | Release `6f6c08ac`: 0/3, document adoption passes but File > New... has no observed effect; all sessions close, no new document. Earlier `aa5790ad`: 0/3, refused before input because native Open 93277 was absent from discovery. Return remains unrun. |
| Adobe, Photoshop | Exact Unicode layer name, undo and redo, inspect name | Release `4e6b996e`: 0/3 complete; New Layer has no observed effect in three independent cycles. Name/undo/redo steps remain unrun. |
| Adobe, Photoshop | Change owned selection and pixels, undo and redo, inspect effects | Pending ×3 |
| Adobe, Photoshop | Scroll/drag owned document and switch between two owned documents | Pending ×3 |
| Qt, Resolve | Unicode search, open Import Media and cancel, verify parent | Release `8d996834`: 2/3 complete Search replacement, triple-click/Delete, Import Project File/Cancel and session closure sequences; the third stops before Delete because selection is unproven. These are partial checks of this workflow: Import Media in the editor remains unrun. Earlier `fca81324`: exact Unicode search passes 3/3 but selecting/clearing refuses its shared ID; Import Project File/Cancel separately passes 3/3. Earlier discovery failures retained. |
| Qt, Resolve | Edit owned project control, undo/redo and verify state | Pending ×3 |
| Qt, Prism | Add Instance dialog, exact text/control values, cancel and verify parent | Release `fca81324`: 3/3 complete using the native field ID: exact Qt1é🧪 / Qt2é🧪 / Qt3é🧪, toggles changed, Cancel returns to the parent and every status is null. Earlier `9e5e4f34`: 0/3 with a shared field/version-row ID; `cbee7cbb` label-based 3/3 and `4e6b996e` 0/3 remain in history. |
| Qt 6 fixture | Composition, control drag and native panel cancel with effect and cleanup | Pending ×3 |
| Chromium, Chrome | Replace Unicode and multiline fields, toggle, counter and scroll | Release `1418e2ef`, first round: 2/3 complete. Third attempt reaches inner scroll offset 204; another downward scroll moves the outer page without increasing the inner offset. All three sessions close with null status. A round with an observed inner-scroll reset is pending; this incomplete attempt is retained. Earlier `51666898`: 0/3, first insertion refuses with targetActivated; native fields are absent from every scene. |
| Chromium, Chrome | Choose dropdown and use context menu; verify actual values | Release `8d996834`: 2/3 complete; the third is interrupted by the user's pause during the context-menu operation and remains incomplete. Diagnostic `fb00894a`: 3/3 complete comparative workflows, separately recorded. Earlier Release `5e285dec`: 0/3 complete; Select All works in cycle 1, but subsequent keyboard input has no Chrome effect. Separate `9e5e4f34` dropdown selections Beta/Gamma/Alpha pass 3/3. Earlier failures remain in history. |
| Chromium, Chrome | Native file picker cancel, verify original document | Release `4c59af9c`: 3/3 complete, each Cancel withdraws the native panel, preserves the owned parent and zero selected files, closes with null status and permits the next adoption. A fourth input-free adoption/observe/close also passes. Earlier `1418e2ef` continuation failure remains recorded. |
| Chromium, Chrome | Owned HTML drag/drop, inspect received payload and counter | Release `1418e2ef`: first adoption refuses while Seat waits, no drag delivered; other two attempts unrun after that same gate. |
| Electron, GitHub Desktop | New Repository owned dialog, name/README/gitignore, cancel | Pending ×3 |
| CEF, official owned sample | Form values, dropdown, native picker cancel and payload-confirmed drag | Pending ×3 |

This is a local Mac workflow rate. It does not qualify other macOS versions,
other Adobe hosts, every installed application, or untested IME/localization
combinations. The wider failures and qualification gaps above remain tracked.

## Round 1: initial observation identity

The borrowed Engine target now receives the identity of the window the broker
actually adopted. Before its first observation it compares the selected window
with that complete identity: process lifetime, window number and owner
connection. It checks again after capture and before storing the frame or
forwarding it to the preview. A change refuses instead of retrying a different
window. A display crop must first establish the same opening identity.

The obligation ends after the first matching observation, so later window
following remains available. Same-identity retitles remain valid. This is a
boundary correction; it does not pin selection for the whole session or make
an ineligible window eligible.

The compiled regression failed before the correction with five assertion
issues: the different first window was accepted and forwarded. The retained
tests cover a selection change before borrowing, before observation and during
capture, a different process lifetime or connection using the same number,
and later deliberate window changes. The changed-capture test requires the
specific identity refusal and no forwarded observation.

On the rebuilt signed Debug app, the owned Safari windows were requested in
the order A, B, A, B, A, B. Each opening found the other window selected and
returned an identity refusal. **Six safe refusals, zero functional passes**:
no scene was returned and no input was requested. Status after the campaign
was `session: null`. This established the original selection defect before the follow-up correction
below. The existing generic preexisting-window test did not reproduce that
installed-app result.

A separate Calculator session on the same rebuilt app completed `7+8 = 15`,
confirmed by a fresh observation, then cleared and closed. Independent native
AX reported `0`; final Mecum status was `session: null`. There were no input
interruptions or identity refusals in that control check. It does not qualify
Safari input or repair the six refused openings.

Verification on 2026-10-03:

| Command | Result |
| --- | --- |
| `swift build --product mecum` | Pass. |
| `swift test --no-parallel --filter 'BorrowedSeatTargetTests\|SeatSceneProviderTests\|BrokeredAutomationSessionTests'` | Pass: 37 tests in three suites. |
| `make test SWIFT=swift` | Pass: 2230 executed, 93 skipped, 2323 reported, 28 runs; `problems: []`. Host/live opt-ins remain skipped here. |
| `xcodebuild -project MecumApp/App/Mecum.xcodeproj -scheme Mecum -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/mecum-app-uxp-20261003/AppFlowDerivedData build-for-testing` | Pass: signed app and test build. |
| `xcodebuild -project MecumApp/App/Mecum.xcodeproj -scheme Mecum -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/mecum-app-uxp-20261003/AppFlowDerivedData test-without-building` | Pass: 320 tests in 59 suites, 56.818 seconds. |
| `git diff --check` | Pass. |

An earlier focused run without `--no-parallel` failed two timing assertions in
the existing Broker cancellation test. The serial focused run and the
repository's serial baseline passed. App tests logged Core Data diagnostics
for temporary test stores, including the passing unreadable-metadata case;
the final result was `TEST EXECUTE SUCCEEDED`.

Local logs and sanitized records are in
`/private/tmp/mecum-stabilization-round1-20261003`. The signed app executable's
SHA-256 is `14b28de8edb265e6915cb337cda202c56e2d78b37528c339694283c6e8dfd0cc`.
The tool evidence is scoped to the dedicated test worker, with personal
window census responses omitted.

## Round 1 follow-up: containment recency

A temporary diagnostic build identified front-order claims emitted while
containing preexisting windows. The native reader attributed those claims to
the application; they displaced the explicitly requested first window. The
retained correction excludes the identity currently being moved by an adoption
transaction from selection recency. It preserves visibility, modal and geometry
claims and clears the placement identity on every transaction exit.

Later real application recency for a held document also synchronizes the
registered session target with the selected capture. Auxiliary surfaces do not
gain this route merely by becoming eligible. The existing auxiliary-surface
regression continues to require the old target.

The new controlled regression failed before the correction on both opening
identity and the later registered target. After correction, 111 focused tests
pass. Through the rebuilt signed Mecum app, all six A/B/A/B/A/B openings return
the requested fixture heading and Seed A/B. A fresh observation of each returns
the same fixture, and every close leaves `session: null`. No input was requested
in these six checks. This closes opening identity for this reproduction, not
Safari input, all multidocument behavior, or the whole release matrix.

The first complete baseline ended before its SeatSession summary with no
reported assertion failure. The isolated last-started test passes; the complete
SeatSession bundle then passes 629 tests in 43 suites. A repeat of
`make test SWIFT=swift` passes 2231 executed, 93 skipped, 2324 reported, 28 runs,
with `problems: []`. The premature runner termination is recorded separately
from application outcomes and remains an intermittent harness limitation.
`swift build --product mecum` and the signed Debug build-for-testing pass.
All temporary diagnostic logging added for this investigation was removed.

Evidence for this follow-up, including sanitized tool records, scene checks,
the failing regression and passing reruns, is in
`/private/tmp/mecum-stabilization-round2-20261003`.

The follow-up host checks pass in isolation: one seat-cycle test and 29 display/
capture/facility tests. The first invocation while Mecum remained open refused
display creation; closing Mecum removed that competing display owner. App
`test-without-building` passes 320 tests in 59 suites (56.071 seconds). These
checks are separate from the six functional app openings above.

## Round 1 follow-up: the selected window's native hit test

With opening identity corrected, the owned Safari button still refused input.
A bounded diagnostic trace found that its point resolved to window B's AX
ancestor while window A was selected and captured. Both windows occupied the
same position after containment. The endpoint refused B, as required.

After containing preexisting siblings, the observation path now stages the
original selected standalone window only if that identity is still selected,
still held, and the existing follow scope/deadline admit the operation. A staging
failure returns no observation. Endpoint discovery and family qualification
remain unchanged. The regression first failed on the missing staging request;
122 focused selection/admission/multiwindow tests then pass. A further 72 tests
cover the staging refusal and the unchanged endpoint routing guards.
`make test SWIFT=swift` passes 2232 executed, 93 skipped, 2325 reported, 28 runs,
with `problems: []`.

Through signed Mecum, clicking `Button A` now changes it to `Pressed A`, with a
fresh scene and independent native AX agreeing. In that same attempt, field
replacement selected `Seed A` but stopped at an unclassified foreign endpoint
(number 89933; a separate capture listing recorded a hidden 14×14 frame). That
failed operation remains recorded. A fresh diagnostic session then replaced
the field and verified exact `Mecum-à-中-🙂`; the unknown classification did
not repeat, and no classification change was retained. The combined workflow
is not closed on this isolated later success. Three registered repeats on the
clean build follow. Evidence is in
`/private/tmp/mecum-stabilization-round3-20261003`; temporary logs are removed.

The retained staging build also passes 30 isolated host checks and the app's
320 tests in 59 suites. Its executable SHA-256 is
`1a0d733954e152d5aa004deb47cc3f8a4c2c8daafdb1f5856ce6bf31720c2449`.
The host and app logs are kept alongside the functional evidence.

The first registered Safari workflow round on candidate `1a0d7339` completes
1/3 attempts. Reload and opening succeed in each; attempts two and three fail
field replacement with new unclassified endpoint numbers (90794 and 90805).
They remain failed attempts. The first attempt's exact text and changed button
are verified by the action result and fresh observation. Later corrected
candidates receive a fresh full matrix; previous failures are retained as
history, never substituted by same-build retries.

## Round 1 follow-up: auxiliary widget versus the focused text control

A diagnostic repeat reproduced three replacement refusals with keyboard
endpoints owned by `ThemeWidgetControlViewService`, each a 14×14 window. Their
evidence was `remoteContentOfSurface`, inferred from the window subtree because
the focused control named no window; accessibility still reported Safari's PID.
The existing endpoint-family refusal remained correct for those destinations.

For a nonmodal keyboard endpoint inferred this way, the retained correction
asks for the existing complete own-content parent proof. If it succeeds, the
control's own surface is the recipient. Missing proof leaves the original
outcome unchanged; a directly named foreign focus and all modal cases bypass
this route. No backend qualification was added for the widget service. The
proof is repeated before posting and a changed proof posts nothing.

The compiled regression failed before correction with the same unclassified
family refusal. After correction, 81 focused tests in six suites pass. On
candidate `92f86789`, all three registered Safari workflows in one Mecum
process pass: reload establishes Seed A/Button A; replacement reports the exact
native field value `Mecum-à-中-🙂`; the click changes the button to Pressed A;
fresh observations retain the owned window and changed button; every session
closes and final status is null. Independent native AX after all three confirms
the exact final field value and Pressed A. OCR in the scene does not reliably
spell the CJK/emoji string; exact replacement is supported by the tool's native
value verification and final native AX, not by claiming exact OCR output.

The complete baseline again ended before its SeatSession summary, this time
during the borrowed-target capture-change test. No assertion failure was
reported. The test helper now starts its existing main-queue keepalive before
the first fake Seat's adoption or capture can pump, instead of waiting for a
later recovery-test wait. `make test SWIFT=swift` then passes 2236 executed,
93 skipped, 2329 reported, 28 runs, with `problems: []`. The inspected log is
`auxiliary-baseline-keepalive.log` alongside the functional evidence.

## Round 2: placement confirmation and terminal sessions

On 2026-10-04 a controlled regression held WindowServer at a 140×100 pt
thumbnail while AX retained the 700×500 pt body. The stage request returned,
but the thumbnail never expanded. The prior confirmation accepted two stable
thumbnail readings and registered the window. The regression failed on both
the extra adopted window and its registered session record.

Confirmation now requires the server size to agree with the attested body,
including after the one bounded stage request. Missing agreement resets the
stability pair and uses the existing confirmation deadline and rollback.
The naturally resized in-place modal still passes when fresh AX and server
readings agree. Identity, geometry tolerances and input admission are unchanged.
This closes a false confirmation, not the native staging failures in Finder
or QuickTime.

A separate regression reproduces the inconsistent worker status: after a
successful opening, `ObservationUnavailable.notAssigned` previously retained
the session ID, screen and queue lease. All five assertions failed. This
terminal observation now closes that worker session, finishes its existing
cleanup and gives the lease back. No-selected-target, suspension, capture
failure and capture deadline refusals keep the current session for recovery.
An idempotent close preserves a cleanup warning and never repeats a quit.

The observation captures its original session ID before awaiting perception.
A late refusal cannot close a replacement session, and a late successful
reading cannot publish the old scene under the new ID. Both races were
reproduced before their identity guards, with three and one assertion issues
respectively. The controlled tests verify the new session and its lease remain
intact in both cases.

The complete first baseline found one inconsistent fullscreen fake: its
ordinary move returned the normal size intended for an explicit fullscreen
exit, even though that row requested no exit. That fake now retains the body
being moved. The opposite regression refuses an unrequested size change
instead of relaxing production confirmation. The focused final check passes
64 Driver tests in three suites and 29 broker tests in one suite.

Verification on 2026-10-04, after both session identity guards:

| Command | Result |
| --- | --- |
| `swift build --product mecum` | Pass. |
| `make test SWIFT=swift` | Pass: 2252 executed, 93 skipped, 2345 reported, 28 runs; `problems: []`. |
| `make host-tests SWIFT=swift` | Pass: 1 seat-cycle and 29 facility/display/capture tests, in separate native processes. |
| `xcodebuild -project MecumApp/App/Mecum.xcodeproj -scheme Mecum -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/mecum-app-uxp-20261003/AppFlowDerivedData build-for-testing` | Pass: signed Debug app and test build. |
| `xcodebuild -project MecumApp/App/Mecum.xcodeproj -scheme Mecum -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/mecum-app-uxp-20261003/AppFlowDerivedData test-without-building` | Pass: 320 tests in 59 suites, 56.190 seconds. |
| `xcodebuild -project MecumApp/App/Mecum.xcodeproj -scheme Mecum -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /private/tmp/mecum-release-stability-20261004/DerivedData build` | Pass: signed Release app. |
| `codesign --verify --deep --strict` for both temporary Debug and Release bundles | Pass with normal trust-service access. The first sandboxed Debug verification returned `CSSMERR_TP_NOT_TRUSTED`; no certificate or trust setting was changed. |
| `make qt-geometry-live-tests SWIFT=swift QT_PYTHON=/private/tmp/mecum-qt-stability-20261003/bin/python` | Pass: one live Qt 6 geometry regression, 13.220 seconds; `problems: []`. |

The Qt fixture confirms the fresh 700×652 body before adoption, 12 actual
command effects, no physical-display input events, a verified return, three
consistent later body readings and released assignment. This is Driver-tier
evidence, not a Resolve or Mecum UI workflow pass. The Qt fixture was stopped.

The signed Debug executable SHA-256 is
`e8bd62dac40c9321b6d104f084f0cc7bd7984626d2fabdf79c37ee4c005009ba`;
its implementation library is
`aed20f4dc4c845711d31c3b1be09d7ee132292207dff7eda4c45c90dac259fe7`.
The signed Release executable is
`ef26d69e7640262c89a1ad9b9c4e5acea5b641db4b105b1ff19f9d29247ad25d`.
Build and test success alone do not close any pending acceptance workflow.

Local logs are under
`/private/tmp/mecum-stabilization-round4-20261004`, with prefixes
`thumbnail-confirmation`, `lost-assignment`, `late-observation` and
`geometry-assignment`. The original failed runs remain retained.

The temporary Photoshop model reader did not qualify editing: its initial
launch was blocked by AppKit's crash-restoration alert, then the new test
bundle identity lacked the Driver's Accessibility prerequisite. No model
snapshot or Return action ran. The desktop controller also refused capture
of the stashed Mecum window with ScreenCaptureKit errors -3811/-3812; one
launch lost the controller connection. The last dedicated-worker status was
`session: null` at order 3732. Only the attested temporary reader and idle test
Mecum process were stopped to free the host display. These are incomplete
setup attempts, not additional application passes.

Running the already approved fixture in the native test context subsequently
established its own foreground with the existing prerequisites. Its one
Photoshop read still produced no model file, and the controller refused its
post-return capture. A separate attested request for the Release Mecum window
returned success but left a thumbnail and a Siri-orb AX dialog. Success from
that request was therefore not accepted as a restored full body. Through the
controller, Mecum's own File > New Mecum Window command opened a complete,
readable window. Release workflow checks use that new window. This is a test
setup limitation; it does not establish a Mecum launch defect under ordinary
user activation or qualify a rescued workflow.

## Round 4: neighboring Photoshop button labels

Two app repeats reproduced a `Close` click creating another document. A bounded
point trace located the click inside `Create`: the pixel grouper had paired
each enclosed label with the neighboring button's border. The resulting
composite rectangle put Close's center at window-local x=991.44, within Create's
985–1063 border instead of Close's 897–975 border. Native AX pressing was false.

Centered text enclosed in a border of button height now names its own border
before an outside caption. Glyph-sized components and thumbnail borders keep
their existing grouping. The measured regression failed on the original code;
retained grouping, accessibility and pipeline tests pass (52 tests). The owned
1080×718 capture was inspected through the actual production perception pipeline:
Close and Create now have distinct normalized widths of 0.072 and separate centers.
Private captures and temporary diagnostic source remain outside the repository
or were removed.

On signed Debug candidate `6443dc84`, three complete Mecum UI attempts open New
Document and click Close once, return to Untitled-3, and release the session.
Each fresh observation confirms the parent; all final statuses are null. An
independent native Window menu lists Probe.png and Untitled-1/2/3 before and
after, with no extra document. This closes that cancellation reproduction;
it does not establish layer-name editing, Return creation or other UXP hosts.
Evidence is in `/private/tmp/mecum-stabilization-round4-20261004`.

## Round 4 follow-up: preserve the initial text selection

`insert_text` now delivers one bulk insertion at the existing focus and
selection, without a field click, selection gesture or activation. It uses the
same Engine and broker in Mecum and the CLI. An exact resulting value is
confirmed only by the focused native field and an explicit complete expected
value. An opaque field, a missing expectation, or a different value returns an
unknown effect. A batch stops there before Return; delivery is never replayed.

The compiled MCP regression first failed because the tool was missing. Engine
tests cover Unicode and newline payloads, partial selections, unavailable native
values, dry runs, empty text and delivery failure. The complete retained-source
baseline passes 2246 executed, 93 skipped, 2339 reported across 28 runs, with
`problems: []`. `swift build --product mecum`, 30 isolated host checks and the
signed app's 320 tests in 59 suites also pass. Those checks do not establish
Photoshop editing effects.

The app investigation retains five earlier failed keyboard/text approaches:
the opening shortcut produced no modal, and four menu-based comparisons left
the drawn layer name unchanged. Their Cancel and session cleanup succeeded.
An endpoint trace attested the modal's own WindowServer recipient and existing
key-window priming; it did not justify weakening endpoint checks. The app's
worker construction and the running binary confirm the brokered path.

A temporary pre-menu focus refresh then produced three drawn field changes,
with measured verified handbacks. After removing that experiment and all its
diagnostic logging, three separately declared control sessions also changed
the field and cancelled cleanly. Both ASCII names transcribed exactly; the
Unicode payload transcribed ambiguously. This comparison does not establish
that every enabled Adobe menu needs activation, so no such policy was retained.
The earlier failures remain history. The clean controls qualify the visible
insertion and cancellation on that prepared application state, not exact native
Unicode, Return, undo/redo, or the full acceptance matrix. Native model checks
and fresh complete workflow repeats remain required.

## Round 5 follow-up: a native display value omitted from the scene

Three declared Calculator workflows on Release `ef26d69e` reached `15`, removed
the result after All Clear, and released their sessions. None of their cleared
scenes exposed the literal zero. The worker's `3/3 PASS` summary therefore did
not establish the full declared acceptance condition. A scoped independent
native reading after the final close found `AXStaticText`, description
`Edit field`, value `0`, in the real display's 19×36 frame. The digit button is
a different `AXButton` at another position. The earlier arithmetic and cleanup
evidence is retained; the three exact-zero checks need fresh repeats.

The augmentation now retains short native static values as text, after
controls have taken their element budget. It does not use `Edit field` as the
display's value or treat it as an editable control. Interactive-control
descendants are excluded; existing window trust, scrolling clip, deadline and
depth guards still apply. Control and text ordinals are independent, so a
display `0` does not rename the digit button. The existing native-control
preference still resolves a click to the button.

The measured display regression and the control-budget regression failed
before the correction, with three assertion issues. The final focused check
passes 74 tests in five suites across perception, resolution, interactions and
Engine behavior. A read through the production `AccessibilityAugmenter` on the
actual Calculator window returns `text|0`, kind `text`, role `AXStaticText`,
label and native value `0`, with normalized bounds
`(0.873913, 0.218137, 0.082609, 0.088235)`.

`swift build --product mecum` passes. The complete `make test SWIFT=swift`
baseline passes 2256 executed, 93 skipped, 2349 reported, 28 runs and
`problems: []`. The 30 isolated host checks pass. The signed Debug
build-for-testing and app tests pass: 320 tests in 59 suites, 54.878 seconds.
The signed Release build and `codesign --verify --deep --strict` pass.
The new Release executable's SHA-256 is
`aa5790ad1b5117a0f488ad775f5dc6846e7f28abc46d8c5966079151c1ca2bb5`.
Three fresh complete Calculator attempts pass on that candidate. Each one
observes literal display `0` separately from the digit button, reaches `15`,
observes it afresh, clears to literal display `0`, then closes with
`session: null`. These are three qualified local attempts, not a percentage
for the incomplete 75-attempt matrix. Native-source attribution comes from
the independently inspected augmentation output; a bare `[text]` scene label
does not itself distinguish native text from OCR.

Logs, candidate hashes, the native read and scoped worker records remain in
`/private/tmp/mecum-stabilization-round4-20261004` under `native-display` and
`release-native-display-calculator` prefixes. This correction does not close
MarkEdit save normalization, TextEdit selection reporting or Adobe editing.

## Round 3 follow-up: a native modal missing beside its document

Three declared Photoshop Return workflows on Release `aa5790ad` refused before
input: the requested document was 49839, but observation selected 93277. A scoped
native reading identified 93277 as the preexisting Open panel, `AXDialog`,
`AXModal` true and `AXMinimized` false, with a complete owned identity and an
891×448 native body. Its server rectangle was an offscreen 124×104 thumbnail at
layer zero. After Mecum closed, the same panel was onscreen at AppKit's modal
panel level. Neither condition means the modal has withdrawn. The worker's
claim that no modal was open was contradicted by this native evidence.

Discovery now supplements ordinary windows with positively identified native
modal dialogs, preserving existing identities and rejecting duplicate or
foreign entries. It requires `AXDialog`, explicit modality and nonminimized
state, matching server owner, an allowed layer, and an attested usable native
body. The modal scan permits AppKit's modal panel level; ordinary-window layer
limits remain unchanged. Its metadata scan limits AX messaging and elapsed
scan time. Missing readings do not authorize an inferred dialog. Main-window
selection still prefers standalone windows; the first-observation identity
guard still refuses a different surface. An explicit Open selection is the
route to the blocking panel.

The three compiled behavior regressions initially failed with four assertion
issues. The focused broker-related run then passed 237 tests in nine suites.
The final baseline passes 2259 executed, 93 skipped, 2352 reported, 28 runs and
`problems: []`. The 30 isolated host checks pass. Signed Debug build-for-testing,
signed Release build and Release signature verification pass. A read through
the production `TargetEnumerator` lists both 49839 and Open 93277; the panel
frame is the full 891×448 native body.

The first app-suite run failed with a crash in
`CrossRowSelectionTests.keyboardSelection`, while `PreparedBlock.attributed`
applied an NSFont attribute. Ten repetitions of each of the three selection
tests then pass, 30 executed cases in the result bundle. This does not close
the intermittent crash. The crash log and the original failed app-suite
result remain separate from later repetitions. Photoshop app cancellation and
Return effects still require verification on the rebuilt Release candidate.

A fresh full app-suite repetition passes 320 tests in 59 suites (55.413
seconds), with `TEST EXECUTE SUCCEEDED`. The initial crash remains an open
reliability finding; the passing repetition is not a claimed crash correction.

Through Release Mecum, explicit Open adoption returns the expected 891×448
panel. One Cancel withdraws it. The action cannot read a following scene;
the next observation reports no assigned application and ends the session.
Fresh app discovery and an independent native reading both confirm that 93277
is absent and document 49839 remains. Final status is null. This qualifies the
discovery correction and one diagnostic cancellation, not a complete modal
workflow: the parent is not observed in that session, Photoshop becomes the
foreground app, and the test controller needs the approved foreground fixture
to make Mecum visible again. Terminal-session guidance still asks for another
observation despite the ended assignment and remains a separate correction.

Three fresh named-Return attempts on `6f6c08ac` all adopt the requested document
49839, then fail because File > New... leaves the scene and window list
unchanged. The Window menu retains the same four owned document entries. Each
session closes with null status. No name insertion or Return commit is reached;
these are 0/3 complete workflow passes, retained separately from the old
identity refusals. The menu command reads enabled, so the existing refresh for
disabled Adobe menus never runs. An enabled item's AX acknowledgement alone
cannot establish vendor dispatch readiness.

Evidence is in `/private/tmp/mecum-stabilization-round4-20261004` under
`modal-discovery` and `transcript-selection-repeat` prefixes. The Release
executable's SHA-256 is
`6f6c08acfc188c9c8f3b0af2b87170308cd418d03374035654a14267d08ca9d1`.

## Round 4 candidate: enabled Adobe menu preparation

The candidate in [ADR 0020](adr/Adr0020PrepareEnabledAdobeMenuCommands.md)
prepares an admitted enabled Adobe command before its first and only dispatch.
It resolves the item again after verified readiness and handback; a refusal or
a newly disabled item posts nothing. Menu listings and refused paths do not
request foreground. The existing disabled-item refresh remains bounded to one
request, with no replay of an unconfirmed command. Other platform policies keep
their existing default.

The compiled menu regressions first failed with 18 assertion issues. The final
focused run passes 86 tests across broker/discovery and MCP/menu suites. The
terminal-observation regressions first fail with five assertion issues, then
pass: a lost assignment closes the session and says it ended; tool and batch
guidance ask for status and discovery when no session remains, while transient
observation refusals retain their ID and observation guidance. Earlier effects
are preserved and no input is replayed. The first terminal test invocation was
a compile failure caused by the test's recorder initializer, not behavior
evidence; the later compiled red result is retained separately.

`swift build --product mecum` passes. The final baseline passes 2265 executed,
93 skipped, 2358 reported, 28 runs and `problems: []`. Signed Debug and Release
builds pass; Release signature verification passes. The first app-suite run
fails five comparisons in the existing CLI/app instruction test because its
canonical expected text lacks the intentional terminal-session guidance. That
expected text is updated to match the shared instruction contract; the failed
run remains retained. Fresh app-suite and Photoshop effect verification are
still required before this candidate's qualification.

The final app-suite repetition passes 320 tests in 59 suites (55.461 seconds),
with `TEST EXECUTE SUCCEEDED`. The 30 isolated host checks pass with no skipped
rows or tier problems. The earlier NSFont crash remains open; no font behavior
was changed by this candidate.

The new Release executable's SHA-256 is
`76dda26df5ad8cb4c10ef6e4b9ddb971bde3ad86aa35e8c921d940b6a9e994e9`.
Evidence is in `/private/tmp/mecum-stabilization-round4-20261004` under
`adobe-menu` and `terminal-guidance` prefixes.

One separate Release `76dda26d` diagnostic still has no observed File > New...
effect after enabled-command preparation. No preparation refusal is returned;
fresh scene/discovery retain only the parent and the same four document entries.
The session closes with null status. This candidate does not close the command
dispatch failure and is not a complete acceptance pass. Further diagnosis must
distinguish menu preparation from invocation while preserving one dispatch and
verified foreground handback.

The native log for that diagnostic reports readiness after 100.1 ms despite
Mecum retaining foreground. Brief activation now evaluates readiness only
while the attested target is observed foreground, and rechecks the deadline
after waiting. Destination key preparation is confined to the brief target
request and its handback; ordinary recovery retains its configured route.
Three compiled regressions fail before these corrections, then the focused
run passes 99 tests in four suites. The rebuilt-app command repeat remains
outstanding and the original failed diagnostic remains in the evidence.

Candidate `3aa20a1c` passes `swift build --product mecum`, the complete baseline
(2268 executed, 93 skipped, 2361 reported, 28 runs, no tier problems), all 30
host checks, signed Debug/Release builds and the app suite's 320 tests in 59
suites (54.986 seconds). Release signature verification passes with system
trust access; the sandbox-only invocation reports `CSSMERR_TP_NOT_TRUSTED`.
Its full executable SHA-256 is
`3aa20a1c5539894a099496acb32fa48154b29ef6e3cd501acbba070fbd9dfe32`.

One fresh app diagnostic still has no New Document effect, unchanged four
owned documents, and null status after close. Mecum stays visible without a
foreground rescue. The native log reports target readiness after 115.9 ms,
but only Mecum's process returns, without verification of expected window
97473. That unverified return was incorrectly accepted as readiness. A new
compiled regression fails on this case, then passes after the correction;
100 focused tests pass. If the target retains foreground, ordinary recovery
still owns it; another foreground is left with the person's choice.

Further regressions fail with four assertion issues for a server witness
preceding workspace activation, a predicate finishing after the deadline,
and a different foreground during an otherwise positive predicate. Readiness
now requires agreeing server/workspace activation before and after the
predicate, a live deadline, and verified handback. These corrections still
require their own complete checks and signed-app repetition. No diagnostic
failure is promoted to a completed workflow.

The final focused run passes 102 tests in four suites. In the first repetition,
the assertion for a positive predicate followed by the person's foreground
choice expected an unverified handback. The new post-predicate check instead
invalidates readiness before any handback: `notReady`, with no new restoration
request. The assertion is corrected to require that exact outcome for both
predicate values. The failed intermediate run is retained.

Candidate `f73b09bd` passes `swift build --product mecum`, the complete baseline
(2271 executed, 93 skipped, 2364 reported, 28 runs, no tier problems), signed
Debug/Release builds and the app suite's 320 tests in 59 suites (55.932 seconds).
Release signature verification passes. Its executable SHA-256 is
`f73b09bd2e3bf83fc5d9b1418eaf5148455727b2d6a7ae80fbb5d3acd46d234c`.
Host and fresh app-effect qualification are recorded separately as they finish.

The 30 host checks also pass. One fresh app diagnostic now refuses File > New...
before dispatch: its handback to Mecum's window is not verified. The native
log reports readiness after 97.5 ms and a 250 ms verification limit; fresh
observation retains the parent, the same four owned documents remain, and
close leaves null status. This qualifies the removal of the false ready
outcome, not successful menu operation.

The next candidate in [ADR 0021](adr/Adr0021ReadConsumerFocusLocally.md)
reads an own-process foreground window from AppKit's local
key window, avoiding an AX request back to the consumer's UI thread. An absent
local key window refuses without AX fallback; external applications retain the
50 ms AX reading. Both routes require matching server owner and window number,
and the existing physical-visibility and lifetime checks still apply. The
compiled controlled regressions fail with four assertion issues before this
route is selected. The first invocation was a compilation error in the
extracted function reference, retained separately from the compiled failure.
Native handback qualification is still required.

A separate Cmd+N control on `f73b09bd` also has no effect: a fresh scene and
discovery retain only the document, the same four owned documents remain, and
the session closes with null status. No Escape is sent because New Document
does not appear. Earlier cold-start success is not reproducible here. The
UXP document recipe currently excludes this shortcut while preparing editing
commands. A candidate extends calibration only to layout-resolved Command-N
on an attested document; Return, text, navigation, hold phases, other modifier
combinations and modal policies retain their existing preparation. The
compiled policy regression fails before the extension. This calibration must
be withdrawn if the rebuilt app cannot attest the dialog's effect.

The focus route's controlled run passes 95 tests in four suites. The combined
UXP calibration/focus/platform run passes 97 tests in six suites. Candidate
`ead47edb` passes `swift build --product mecum`, the complete baseline (2275
executed, 93 skipped, 2368 reported, 28 runs, no tier problems), signed
Debug/Release builds, signature verification and the app suite's 320 tests in
59 suites (57.191 seconds). Its executable SHA-256 is
`ead47edb9c4e2b34a4351672d20ccb4fe7be23929c8e8bd0ef8e1708a256444c`.
Native calibration and handback effects remain pending until the app repeat.

All 30 host checks pass. The fresh `ead47edb` Cmd+N diagnostic still has no
observed effect, unchanged discovery and four owned documents, and null status
after close. No Escape is sent because no dialog appears. The Command-N
calibration is withdrawn from the retained policy and its expected test set;
the failed candidate and its checks remain in the evidence. No menu shortcut
route is substituted for a failed or unconfirmed AX invocation. The local
focus-reading candidate still needs its independent handback qualification.

The independent `ead47edb` menu diagnostic still refuses before dispatch. Its
native log reports readiness after 254.4 ms, followed by an unverified 250 ms
handback to window 99043. The same four owned documents remain and final status
is null. Reading the key window locally does not close this native failure.
The next diagnostic reports the final focus reading and its existing eligibility
result, rather than increasing the deadline without identifying the mismatch.

Candidate `25a4fcd4` passes the complete baseline (2275 executed, 93 skipped,
2368 reported, 28 runs, no problems), all 30 host checks, signed builds,
signature verification, and all 320 app tests in 59 suites (56.056 seconds).
Its fresh native diagnostic reaches readiness after 126.0 ms, but the final
handback reading is no focused window and no workspace foreground process.
File > New... refuses before dispatch; the four documents remain unchanged
and final status is null. A later independent reading finds Mecum active and
Photoshop inactive. This is not a completed workflow.

[ADR 0022](adr/Adr0022RequestConsumerHandbackLocally.md) selects AppKit for a
brief handback to the exact attested window in the consumer's own process.
An absent local window refuses without a remote retry. External requests and
ordinary recovery retain their policies; the verification deadline and all
identity and visibility checks remain. The focused run passes 69 tests in four
suites, including three routing definitions with four cases. Signed-app
handback and command effects remain outstanding until the fresh repetition.

Candidate `5a1204ec` passes the CLI build, complete baseline (2278 executed,
93 skipped, 2371 reported, 28 runs, no problems), signed Release build,
signature verification, Debug test build and 320 app tests in 59 suites
(56.752 seconds). Its native diagnostic still refuses before dispatch.
The final reading now names the expected window, its owner, physical body,
eligible state and Mecum workspace foreground. The same four documents remain
and final status is null. A complete identity match and two timely agreeing
readings have not yet been established.

A separate read-only probe measures five reads of that exact Mecum window.
The first geometry costs 86.726 ms in its new probe process. The following
four two-geometry/order readings cost 0.656–0.755 ms and retain the same
identity. This is scoped diagnostic timing, not a production performance
qualification or proof of the request's handback latency.

A compiled regression separately demonstrates that a second matching geometry
read finishing after the handback deadline was still accepted as ready. The
test fails with `ready(afterMilliseconds: 0)` where `handbackNotVerified` is
required. The correction checks the deadline and cancellation after the native
reading, before counting agreement. The failed native diagnostic remains
open; its next repeat records identity agreement, reading count and timing.

The timed candidate `d00ee49d` passes the focused 70 tests, all 30 host checks,
complete baseline (2279 executed, 93 skipped, 2372 reported, no problems),
signed Release build/signature and Debug test build. App-suite results are
recorded separately as the run finishes. Three native diagnostics still refuse
before dispatch, retain the four documents and close with null status. One
reads the correct complete identity at 263.4 ms, beyond the 250 ms deadline;
another resumes after 343.8 ms after one 0.2 ms read. The correctly armed
profile captures native AppKit/ViewBridge work during a 342.9 ms failed
verification. The earlier profile starts after the operation and cannot explain
it. Native failures are retained, and no unit pass qualifies their workflows.

[ADR 0023](adr/Adr0023BriefHandbackVerificationLimit.md) separates a one-second
brief-handback limit from ordinary recovery's unchanged 250 ms policy. A
compiled controlled regression fails under the old limit at a 300 ms first
identity reading. Two agreeing identity/foreground/visibility readings remain
required before the new deadline, and a reading finishing too late still
refuses. The candidate's signed-app effect remains pending.

The final controlled run passes 111 tests in six suites. Its first invocation
passes the focus and menu suites, but a broker cancellation test checks its
queue before the request has entered and records two issues. That test now
waits for its actual queue entry within two seconds before the same queue,
activity and cancellation assertions. The failed invocation is retained.
The timed candidate's app suite also passes 320 tests in 59 suites
(56.148 seconds).

Release candidate `ef3b05dc` is built and signature-verified. Its first fresh
diagnostic discovers New Document window 100903 before any command in that
cycle. Opening the named parent refuses the different initial identity and
sends no input; the worker then explicitly adopts the discovered dialog and
Escape withdraws it, with the same four documents afterwards. Its creation
time and cause are unknown, so this is cleanup evidence, not a successful
new-document opening or proof about a previous invocation.

The following File > New... invocation verifies handback to the expected Mecum
window in 369.7 ms, after menu readiness at 1051.2 ms. This establishes one
native handback effect for the new request and limit. The menu's AX press
returns `acted_unverified`: fresh scene and discovery do not show a new modal,
the four documents remain and final status is null. Command effect is still
open. Additional document/menu/modal checks are recorded separately rather
than promoting this diagnostic to a completed workflow.

The three subsequent document-switch attempts all stop at Window > Probe.png:
each press returns unverified, the active title remains Untitled-3 and no new
dialog appears. Their handbacks are verified at 226.1, 371.8 and 352.4 ms.
The requested New Layer/name steps are unrun in those cycles, not passes.
An independent direct New Layer attempt on the owned current document also
leaves fresh scene and discovery unchanged. All four owned documents remain
and each session closes with null status. The separate candidate in
[ADR 0024](adr/Adr0024DispatchAdmittedAdobeMenuBeforeHandback.md) moves a single
admitted Adobe AX menu command before handback, with explicit partial-effect
handling and unchanged refusal boundaries. Its native qualification is pending.

The final scoped-command controlled run passes 118 tests in six suites:
71 focus/window tests, three restorer definitions, 29 broker tests and 15 menu
tests. The compiled ordering regression fails before correction with two
issues. Intermediate compilation failures are not regression evidence. A first
combined run also exposes the captured adopted-window set becoming stale after
readiness; handback now re-reads the current adopted set and the same test
passes. Full baseline, host, app-suite and signed native results follow below.

### Scoped Adobe command candidate: native result

Release `4e6b996e` passes the CLI build, complete baseline (2287 executed,
93 skipped, 2380 reported, 28 runs, no tier problems), all 30 isolated host
checks, signed Debug/Release builds, signature verification, and all 320 app
tests in 59 suites (56.193 seconds). Its executable SHA-256 is
`4e6b996e5f57e3fa04a976ad4b4229d479e4c8380dc37f8ff9821d4de7cfed56`.

Three independent cycles through this Release each press Window > Probe.png
once and Layer > New > Layer... once. Both commands return unverified in all
three cycles: fresh scene and discovery retain Untitled-3 @ 50%, and no New
Layer dialog appears. Four owned documents remain and each close leaves null
status. The name, Return, undo and redo steps are unrun. This is zero completed
layer workflows, not a successful foreground-dispatch qualification.

Captured native records verify selected handbacks at 239.4–414.8 ms. The
rolling log was overwritten during collection, so it cannot establish timing
for all six commands. Tool records retain all six outcomes. The later bounded
log query contains no operation records and supplies no additional evidence.

Independent native AX menu controls, including ordinary activation of the
owned Photoshop target, likewise show no modal. A five-second sample then
finds Photoshop's main thread in NSMenuTrackingSession's menu event loop,
entered from NSMenuItem's accessibility action. Samples after native Escape,
AX menu cancellation and normal deactivation retain that stack. Cancellation
can collapse the AX menu without ending the sampled loop. No sample predates
these independent controls, so this does not establish the cause or onset of
the earlier Mecum failures.

An approved temporary fixture requests normal Photoshop termination once.
The request is accepted, but the process remains and no Save Changes prompt
appears. A subsequent independent Mecum diagnostic clicks the observed zoom
field once without typing or changing its value, then presses New Layer once.
Fresh observations again show no modal, the same four documents, and null
status after close. The directed mouse precondition does not repair the menu
effect. The pending quit request, menu tracking and Adobe workflow failures
remain open; no document was saved, discarded or force-closed.

Scoped evidence is retained locally under
`/private/tmp/mecum-stabilization-round4-20261004`, with `scoped-adobe-command`,
`release-scoped-adobe-menu`, `adobe-native-control` and
`release-adobe-zoom-prime` prefixes. Independent desktop controls are assisted
diagnostics and do not count as Mecum workflow passes.

### Qt installed-app repeats and field targeting

On the same Release, three Resolve cycles stop before adoption: scoped
discovery lists a running process without windows, and opening waits 20 seconds
then refuses without retaining a Seat. A separate read-only native controller
reports Project Manager. The mismatch is open; the native reading is not a
successful Mecum adoption and does not justify relaxing identity or geometry
requirements. No project was opened or edited.

Three Prism cycles launch the app, open New Instance, change one reversible
toggle and cancel back to the parent, all with observed effects. They each fail
name replacement: the chosen visual target Name: 26.3 is at normalized
0.04,0.10; another control labeled 26.3 is at 0.23,0.11, beside the native Name
caption. One insertion per cycle leaves the name unchanged. All three sessions
close with null status; the test-launched app exits. No instance, download or
account operation occurs. These are three failed complete workflows, despite
the passing dialog and toggle steps.

The field candidate makes native text-entry roles visible as `[field]` in both
scene tiers, with the existing element ID. For typing, a shared label prefers
positively identified native text-entry candidates; two such fields remain
ambiguous, and explicit IDs and section filters retain their scope. This does
not infer a label-to-field relationship from distance, authorize an unknown
recipient, or retry an earlier insertion. Multiline AXTextArea now also retains
its interactive role when merging a matching pixel caption; harvesting alone
had left that element as text.

Two compiled regressions fail before these changes with four assertion issues
for missing field references and the lost multiline role. The focused final
run passes 108 tests in six suites, including an Engine test that checks the
actual field click point, one Unicode insertion, exact readback and refusal
without input when two native fields remain. Full checks and fresh native
workflow results are recorded as they complete. The previous six failures
remain retained under `release-qt-installed-repeat`; candidate checks use the
`native-field` prefix in the same local evidence directory.

Release `cbee7cbb` passes the CLI build, complete baseline (2291 executed,
93 skipped, 2384 reported, 28 runs, no tier problems), signed Debug/Release
builds, signature verification, and the app suite's 320 tests in 59 suites
(55.273 seconds). The Driver is unchanged from the preceding 30 passing host
checks. Its executable SHA-256 is
`cbee7cbb709f28a187cc223eb33bcc98dfc8ce9e1006908e8a6b4dc7354fb14e`.

All three fresh Prism workflows now pass through Mecum. The observed native
field at 0.23,0.11 is marked `[field] 26.3`; typing its current label selects it
instead of the version row. Each single insertion returns the exact native
value Mecum Qt é 🧪, and a fresh observation retains that value. Snapshots,
Betas and Alphas respectively change to on; Cancel returns the parent and
each close leaves null status. This closes the reproduced Prism field-target
failure. It does not close Resolve discovery, every Qt editor, IME, or the
remaining exact-text checks. Evidence is scoped to
`release-native-field-prism-repeat`; the earlier three failures remain.

On this same Release, Calculator completes one of three registered repeats:
the first two first-clear deliveries interrupt with geometryChanged, while
the third separately observes literal 0, 15 and 0. All three close cleanly.
Clock completes all three navigation repeats with distinct Stopwatch/Timers
controls and native selected-tab states, then returns to World Clock and
closes with null status. No timer, stopwatch, alarm or clock is started or
created. Scoped records are under `release-appkit-core-repeat`. The new
Calculator interruptions remain open; earlier passing builds do not erase
them.

A scoped read-only Resolve probe distinguishes failed AX reads from missing
windows: at 50 ms some reads time out; at one second it attests Project
Manager, AXWindow/AXUnknown, nonminimized and nonmodal. The server's 100×105
Stage Manager thumbnail corresponds to a complete same-owner identity and
910×640 AX body. It is also present in the onscreen enumeration, and the
production WindowRelocator frame read succeeds in this separate client.
Thus neither the subrole nor the thumbnail alone establishes why Mecum
excludes it. No discovery relaxation is retained on that incomplete diagnosis;
the temporary in-process trace is removed after its scoped reading.


## Round 2: requested placement during Stage Manager movement

A read-only in-process Resolve discovery probe finds the full native body and
adopts Project Manager. With the temporary probe removed, Release `cbee7cbb`
also discovers and adopts it in all three repetitions. Two reversible Search
on/off control cycles pass; the second stops at its first input with
geometryChanged. These are partial Project Manager checks, not the registered
Unicode search / Import Media workflow. The earlier three discovery failures
remain, and their original cause is not established.

A separate, read-only watcher of the owned Calculator window measures a
full-size intermediate Stage Manager position at 2459,1374, followed by the
requested position 2677,1498. The Seat reports ready between these readings,
and its first input later refuses with geometryChanged. The 230×408 body and
identity do not change. A second three-cycle arithmetic probe completes two
flows; the first stops at that refusal. Scoped evidence is in
`release-resolve-discovery-repeat`, `release-calculator-geometry-probe`,
`calculator-geometry-watch.txt` and `calculator-geometry-live-session.log`.

The retained correction requires the requested position, with the existing
cross-source tolerance, for a window observed as a thumbnail before movement
or requiring staging during confirmation. Two agreeing
full-size readings at an intermediate position no longer complete adoption.
Ordinary full-size and in-place adoption retain their existing contracts;
no input is posted or replayed
to compensate for a later geometry refusal. A window that never reaches its
requested position still times out and rolls back. Two compiled regressions
fail before the change with four assertion issues. Focused, full and native
checks are recorded below as they complete.


The first broad condition also applied to ordinary full-size windows. The
initial full baseline exposed placement refusals in existing panel, handback
and borrowed-identity tests and was stopped; it is not a completed baseline.
The condition is narrowed to positively observed thumbnail/staging cases.
The first parallel focused run also fails four capture-deadline checks under
MainActor contention; the prescribed serial 99-test run passes. The expanded
serial regression set and a fresh full baseline validate the final scope.
See [the placement decision](adr/Adr0025ConfirmStashedPlacementPosition.md).


The final expanded serial command
`swift test --no-parallel --filter
'WindowAdoptionTests|AppWindowFollowTests|SeatGuardTests|SeatWindowSessionTests|GestureEndpointRoutingTests|BorrowedSeatTargetTests|AssignedApplicationHandbackTests|BriefActivationTests|CaptureSourceCoherenceTests|FocusedDescendantKeyboardRoutingTests'`
passes 162 tests in ten suites (136 SeatSession tests in nine suites and
26 SeatCore tests). Evidence: `placement-origin-green-scoped.log`.


The final placement candidate passes `swift build --product mecum`,
`make test SWIFT=swift` (2293 executed, 93 skipped, 2386 reported,
28 runs, status passed and no tier problems), `make host-tests SWIFT=swift`
(1 + 29 executed, no skips or tier problems), Debug `build-for-testing`,
Release `build`, `codesign --verify --deep --strict` on the signed Release,
and `git diff --check`. App-suite and fresh native results follow below.
Evidence uses the `placement-origin` prefix. Release executable SHA-256:
`51666898e2f692fc59f1f754bcfcfcab7b9e077d61b70821f6ef9b2d3c38bfa4`.


Debug `test-without-building` passes all 320 app tests in 59 suites in
56.445 seconds, with no test runner restart. Evidence:
`placement-origin-app-tests-final.log`. This passing run does not by itself
close the older intermittent attributed-font crash without a causal fix.


On Release `51666898`, all three registered Calculator arithmetic workflows
now complete, each with fresh observations of 0, 15 and 0 and a final null
session. Single clicks remain unknown when their only change is pixel-based;
the independently observed intended result permits the next step, without
replaying the input. No geometry interruption occurs in these three cycles.
Scoped evidence: `release-placement-origin-repeat`, records 4926/4936/4940,
4952/4962/4966 and 4978/4988/4992; null statuses 4944, 4970 and 4996.


All three fresh Project Manager Search on/off repeats on Release `51666898`
also pass: on exposes the native field, off withdraws it, each session closes
and leaves null status, and no geometry interruption occurs. Records are
5002/5004/5008, 5014/5016/5020 and 5026/5028/5032 in
`release-placement-origin-repeat`. No project or text input is performed, so
these remain partial checks beside the registered Resolve workflows.

A fresh independent native Window menu still lists only the four known owned
Photoshop test documents (Probe.png, Untitled-1/2/3). Selecting Probe.png once
again leaves Untitled-3 current. The proposed test-process restart was not
performed: automatic approval review rejected Computer Use access to Activity
Monitor without a detailed reason. No forced termination or alternate
termination route follows that refusal. The same four owned documents remain
and Adobe qualification stays open while other app checks continue.


The first current-release Chrome core campaign is blocked before adoption: the
requested Chromium fixture was no longer open; discovery only lists the owned
Rich Text fixture. Three requested cycles remain blocked, not passes. Setup
through that owned window then reproduces a separate toolbar input failure:
the native Address and search bar is readable, but one type_text leaves its
old local file path unchanged in both command readback and fresh observation.
Return is not sent and the session closes with null status. No coordinate or
layout-dependent shortcut is substituted. Evidence: `release-chrome-core-repeat`
and `release-chrome-fixture-setup` (5052/5055, null status 5060). This single
case is an open omnibox failure; its cause has not yet been established.


The current-release Chrome File > Open File setup opens both a new New Tab
host (103866) and an attached Open sheet (103871). The menu's subsequent
observation refuses the sheet because its host is not held; direct adoption
of Open also fails. A separate attempt to adopt the named New Tab host
refuses with three plausible targets and an unresolved modal relation.
The panel remains after null session status: this is a failed cleanup, not
a completed picker workflow. Evidence: `release-chrome-file-setup` and
`release-chrome-panel-cleanup`.

Independent native UI then selects the owned New Tab window and presses its
observed Cancel button, withdrawing Open. This rescue does not qualify Mecum.
The empty owned tab is used to prepare an exact copy of ChromiumAppFlow.html
in the existing temporary campaign folder, opened with the native file panel.
No omnibox Return or network navigation follows the unsuccessful URL setup.
The native Go to Folder shortcut instead navigates to iCloud Drive under
Dvorak; no shortcut replay follows, and the temporary folder is selected
from the observed Where menu. This independent setup behavior is not a
Mecum keyboard-layout result.

On Release `51666898`, all three Chrome core workflow repeats adopt the exact
Chromium fixture but stop at the first Probe Text insertion with
targetActivated. Every scene has only pixel-derived labels for the form,
without native fields or their values. No input is replayed and no dependent
steps are performed. All sessions close, with null status at 5124, 5136 and
5149. Evidence: `release-chrome-core-ready`, failed inputs 5117, 5130, 5143.
The copied local fixture is byte-identical to its source; its path change is
setup, not a claimed cause. Native augmentation and activation remain open.


## Round 6: captured identity in native augmentation

A read-only production augmenter finds 20 native elements for the owned Rich
Text Chrome window and 45 for the Chromium window before assignment. During
an exact Chromium adoption without input, both equal-sized windows occupy
2192,1288,1200,828. Frame-only lookup then rejects the tie and yields zero
native elements for both. All three Mecum observations lack fields; the
session closes with null status. Evidence: `chrome-owned-augmentation.txt`,
`chrome-augmentation-during-adoption.txt` and
`release-chrome-augmentation-readonly`.

The retained correction carries the actual captured Window ID into
ScenePipeline and native augmentation. The composition layer provides the
native ID resolver; the core applies the identity predicate before its
existing geometry matching. No absent or stale recipient falls back to
geometry or focus. An old adapter without identity support supplies no facts
for an identified capture. The captured host's geometry provides the ID for
a hosted sheet, rather than inventing a separate sheet picture. See
[ADR 0026](adr/Adr0026BindNativeFactsToCapturedWindow.md).

Two compiled regressions fail before the correction with seven assertion
issues. The final focused command
`swift test --no-parallel --filter
'AccessibilityAuditTests|ScenePipelineTests|ScenePipelineConcurrencyTests|SeatSceneProviderTests|BorrowedSeatTargetTests'`
passes 43 tests in five suites. The CLI product build passes. Final baseline
and signed-app results follow as they complete. Evidence has the
`captured-native-identity` prefix; earlier targetActivated failures remain
failed and do not establish their own cause.


The final native-identity baseline passes `make test SWIFT=swift`: 2297
executed, 93 skipped, 2390 reported across 28 runs, status passed and
problems empty. `git diff --check` passes. The 93 opt-in host/live/provider
checks are skipped, not native qualification. No Driver implementation is
changed in this round. The earlier placement round's host result remains
separate evidence.


The native-identity candidate passes the final CLI product build, Release
`xcodebuild ... -configuration Release ... build`, and signed-bundle
`codesign --verify --deep --strict` with the system trust store accessible.
The restricted first signature check reports CSSMERR_TP_NOT_TRUSTED and
remains an environment-limited check, not a passing verification. The final
Release executable SHA-256 is
`3e3936fb697dd900f0053b8685b85a6efd422c8775bbe50983bcc4edc5c25890`.


Debug `build-for-testing` and `test-without-building` pass on the identity
candidate: 320 app tests in 59 suites, 58.152 seconds, no runner restart.
Evidence: `captured-native-identity-app-build.log` and
`captured-native-identity-app-tests.log`. The temporary-store Core Data
diagnostics occur in the same passing app suite; they do not qualify desktop
flows. The older intermittent attributed-font crash remains open.


The first signed Release `3e3936fb` native-identity probe exposes both fields
with their native IDs and performs exact replacements through Mecum: Probe
Text reads Capturedé🧪 and Multiline Editor reads alphaé\nbeta🧪 in fresh
observations 5185 and 5190. The session closes and status is null at 5194.
No activation or geometry interruption occurs in this partial probe. It
qualifies field acquisition and these two inputs once, not the full registered
toggle/counter/scroll workflow or the original activation failure's cause.
Evidence: `release-chrome-captured-identity`.

The same native scenes expose a separate viewport problem: several offscreen
Chrome controls and static values are reported at the bottom edge with a
one-point extent, including Increase Counter and Scroll offset. The
production read-only augmenter measures the same one-point proxy frames.
Those controls are not used in the field probe. A separate regression and
correction will exclude unusable visible slivers before broader app flows.


## Round 6: native viewport slivers

The native harvest now requires at least two visible points on both axes
after intersection with its container and the captured window. A one-point
Chrome viewport proxy supplies neither an actionable control nor a visible
static value. This applies to native elements only; pixel detection and
window matching keep their existing rules. The same element can become
eligible after an observed scroll exposes a usable frame.

A compiled regression fails before the correction with the hidden button,
static counter, narrow field and clipped sliver still in the harvest. The
final focused set passes 49 tests in four suites, including the new identity
regressions and ordinary frame/clipping contracts. Commands and output:
`swift test --no-parallel --filter
'AccessibilityAuditTests|AccessibilityAugmentationTests|AccessibilityFrameTrustTests|ScenePipelineTests|SeatSceneProviderTests'`,
`native-viewport-sliver-red.log` and `native-viewport-sliver-green.log`.
Baseline and current-app repeats follow below; the prior field probe remains
partial evidence from Release `3e3936fb`.

The viewport candidate passes `make test SWIFT=swift`: 2298 executed,
93 skipped, 2391 reported across 28 runs, status passed and problems empty.
`swift build --product mecum`, the Release app build and
`codesign --verify --deep --strict` pass. The signature check has access to
the system trust store. Release executable SHA-256:
`1418e2ef93aeb029d4345bc002f02c1fd203e14ca634c3c5f5286e06ca3df3a2`.
Evidence: `native-viewport-sliver-baseline.log`,
`native-viewport-sliver-cli.log` and `native-viewport-sliver-release.log`.
The 320 app tests above belong to the preceding identity candidate and are
not a new app-suite run for this binary.

Through signed Release `1418e2ef`, the first two complete Chrome workflows
pass: distinct exact Unicode and multiline replacements, toggle inversion,
counter 0 → 1 → 2 and inner scroll offset 0 → 120 → 204. The third completes
both replacements, toggle and counter 2 → 3, but scrolling down at offset
204 moves the outer page and leaves the inner offset unchanged. It remains
an incomplete attempt, with the scroll boundary hypothesis unverified.
Each session closes with null status (5236, 5272 and 5308). No one-point
counter or scroll-value proxy remains in the initial view; observed document
scrolls reveal usable controls before input. Evidence:
`release-chrome-visible-controls`. A fresh round will establish an observed
inner-scroll reset before asking for an increase in each cycle.

The observed-reset round `release-chrome-core-reset` also completes 2/3.
Its first setup scroll decreases 204 → 44 but does not reach the required
zero, so that attempt ends before field input. The next two setups reach
44 → 0 and 120 → 0; both full workflows then pass exact Unicode/LF,
toggle inversion, counter 3 → 4 → 5 and inner scroll 0 → 120. All three
close with null status (5326, 5362 and 5399). These additional passes do
not replace either incomplete attempt. The downward gesture works from
zero in both valid cases; the precise maximum scroll extent has not been
independently measured.

## Round 6: dropdown identity and consumer focus restoration

The extended Chrome round retains two native-dropdown refusals, one
ineffective caption-click variant, two observed file-picker cancellations
and the subsequent waiting-state refusal. No context-menu or drag step is
qualified. The worker's inference that HTML exposes no popup is unsupported:
the inspected dropdown opener refuses on an AX/title mismatch before it can
try to open one. WindowServer and AX titles are independently recorded.

[ADR 0027](adr/Adr0027BindDropdownLookupToCapture.md) binds native dropdown
queries and full-window before/after scenes to the actual capture. Native
values now drive row routing and effect verification; stale identities and
geometry still refuse. [ADR 0028](adr/Adr0028RestoreConsumerThroughAppKit.md)
uses the exact local AppKit window for ordinary consumer handback as well
as primed handback. External restoration remains unchanged. The latter is
a candidate correction for the continuation failure, whose native cause
is not yet fully established.

Compiled regressions retain one assertion issue for native-value
verification and two for ordinary consumer routing. The combined focused
set passes 127 tests in nine suites. The final command is
`swift test --no-parallel --filter
'UserFocusRestorerTests|UserFocusRecoveryTests|AppKitStatePreparationTests|InputPlatformTests|NativePopupMenuTests|CaptureSourceCoherenceTests|DropdownValueVerificationTests|PopupRowPickTests|AccessibilityAuditTests|ScenePipelineTests'`.
Evidence: `dropdown-native-value-red-final.log`, `ordinary-own-focus-red.log`
and `dropdown-own-focus-green.log`. Baseline, host and signed-app results
follow below. Earlier failed and unrun attempts remain in their rounds.

`make test SWIFT=swift` passes for the combined candidate: 2302 executed,
93 skipped, 2395 reported across 28 runs, status passed and problems empty.
The Release app build and `codesign --verify --deep --strict` pass, with
system trust-store access. Its executable SHA-256 is
`4c59af9c2285fb2e6450c4f770e3e693196a7b2974e9ea7c5a7a13917b525ba5`.
Evidence: `dropdown-own-focus-baseline.log` and
`dropdown-own-focus-release.log`. The host, app-suite and live outcomes
remain separate checks below.

The final CLI product build, Debug `build-for-testing` and app
`test-without-building` pass: 320 tests in 59 suites, 56.335 seconds
(58.343 seconds for the Xcode operation), no
runner restart. `make host-tests SWIFT=swift` passes its isolated one-test
seat cycle and 29-test display/facility run, with zero skips and problems
empty in both summaries. `git diff --check` passes. Evidence:
`dropdown-own-focus-cli.log`, `dropdown-own-focus-app-build.log`,
`dropdown-own-focus-app-tests.log` and `dropdown-own-focus-host.log`.
The older attributed-font crash remains open; these passing repetitions
are not a causal correction for it.


The signed Release `4c59af9c` file-picker repeat completes 3/3 workflows.
Each observed picker has Cancel and a disabled Open; one Cancel withdraws it,
the original owned Chrome page returns with `Files selected: 0`, and each
session closes with null status (5525, 5542 and 5558). Consecutive adoptions
succeed without outside recovery, followed by a fourth input-free adoption,
observation and closure (5561–5567). No file is chosen or uploaded.

The independent foreground watcher records 600 samples at a 0.5-second
cadence across this campaign: the exact Release Mecum application is active
and NSWorkspace agrees at every sample; owned Chrome is inactive. This does
not exclude sub-cadence transients. The Session stream records all three
Cancel-triggered recoveries restoring the same exact Mecum destination and
returning to ready. This closes the reproduced continuation failure for this
campaign, not every external activation or the separate menu-created host
failure. Evidence: `release-picker-own-appkit-tools.json`,
`release-picker-own-appkit-foreground.log` and
`release-own-appkit-seat-stream.log`, in the round-4 evidence directory.


The first `4c59af9c` combined dropdown/context-menu workflow fails at cycle 1;
cycles 2 and 3 are unrun because a menu remains open. The worker passes the
rendered name plus value (`Probe Choice = Alpha`) to select; that variant
reaches `contextMenuNeverOpened`, keeps Alpha and opens no dropdown. The
independent context-menu step opens a real menu, but choosing Select All and
then Escape both return `subtreeUnreadable` for the parent. A subsequent
read-only adoption still observes the menu. Native cleanup selects Select All
on the owned fixture after both Mecum sessions close; it is outside recovery,
not qualification. Evidence: `release-chrome-dropdown-own-identity`.

A separate single diagnostic select passes exactly `Probe Choice`, requests
Beta once and receives `honest_miss`. Its attached 15-element scene contains
only OCR text. The immediately following ordinary observe contains 48 elements
and the actual native dropdown, still Alpha. The composition inspection finds
both session adapters constructing select's pipeline with only
`VisionTextRecognizer`; their ordinary observation uses `ProductionPerception`.
Both select adapters now use that existing complete factory. No capture,
identity, action-admission or menu-ownership guard is weakened. The native
repeat is the red-capable loop for this assembly defect; existing pure value
and capture tests alone did not exercise the missing connection. Fresh native
results are required. Evidence: `release-dropdown-exact-name-probe`.


The complete-pipeline candidate `5a68db8d` repeats the exact-name diagnostic.
The selector now sees the same 48-element native scene as ordinary observe
and resolves Probe Choice. It opens Chrome's contextual page menu, whose
observed rows are Back, Forward, Reload and Inspect, rather than Alpha/Beta/
Gamma. Beta is not chosen; the menu is withdrawn and status is null. The
assembly correction is connected, but dropdown selection is still failed.
Evidence: `release-dropdown-native-pipeline`, especially result 5646.
A separate native primary-action check opens the actual Alpha/Beta/Gamma menu
and chooses Alpha to leave the fixture unchanged; this is diagnostic evidence,
not a Mecum workflow pass.

The opening code always selects AXShowMenu when that action is exposed.
It now prefers AXPress for the already uniquely identified popup/combo, retaining
Show Menu only when no primary action exists. Unsupported actions still refuse;
there is no replay after a request. The extracted prior decision fails three
compiled assertions, including both action-name orders and a Press-only control.
The corrected decision passes 59 focused tests in seven suites:
`swift test --no-parallel --filter
'DropdownOpeningTests|DropdownValueVerificationTests|NativePopupMenuTests|CaptureSourceCoherenceTests|PopupRowPickTests|TargetResolutionTests|ScenePipelineTests'`.
Evidence: `dropdown-primary-action-red.log` and
`dropdown-primary-action-green.log`. Fresh native selection is pending.

The complete-pipeline candidate's first baseline ends without the SeatSession
bundle summary: 1648 executed, 93 skipped, 27 of 28 summaries, status failed.
No failed assertion is reported. The isolated SeatSession bundle then passes
654 tests in 44 suites (104.782 seconds). A full baseline repeat passes
2302 executed, 93 skipped, 2395 reported across all 28 runs, problems empty.
The runner interruption remains a recorded failure rather than a pass.
Evidence: `dropdown-production-pipeline-baseline.log`,
`dropdown-production-pipeline-seat-repeat.log` and
`dropdown-production-pipeline-baseline-repeat.log`. CLI and Release builds
and strict signature verification pass for `5a68db8d`. These results precede
the primary-action correction; its final baseline follows separately.


Release `9e5e4f34` completes the dropdown subpath in three separate Mecum
sessions: Alpha → Beta, Beta → Gamma and Gamma → Alpha. All three selects
report the exact native value at the original control, fresh observations
agree, and each popup withdraws before close/null (5677, 5691 and 5705).
No replay, alternate action, outside recovery or input to another control is
used. This closes the reproduced dropdown defect on the owned Chrome page;
the registered combined dropdown/context-menu workflow remains incomplete
until its distinct menu step is repaired. Evidence:
`release-dropdown-primary-action`.

The final primary-action candidate passes the CLI build, signed Release build
and strict signature check, plus `make test SWIFT=swift`: 2305 executed,
93 skipped, 2398 reported in 28 runs, problems empty. Release SHA-256:
`9e5e4f342d30f0cc4d89e13b5d29c98de0dd81290fd4a6df3b5a58f856724220`.
Evidence: `dropdown-primary-action-cli.log`,
`dropdown-primary-action-release.log` and
`dropdown-primary-action-baseline.log`. The prior 320 app tests are for
`4c59af9c`; a final app-suite check remains separate.

The first Qt 6 fixture inspection is blocked before any action: Computer Use
rejects the exact Python 3.14 app with `Computer Use was not approved to use
Python`, providing no additional reason. The existing fixture remains open
and unchanged. No fallback route controls that same rejected app. Qt repeats
continue on the already qualified installed Qt apps; this Qt 6 attempt is
blocked, not a pass. Evidence phase: `release-qt6-first-app-flow` (no worker
input is sent to Python).

## Round 5 follow-up: text entry using a shared native ID

Release `9e5e4f34` refused all three Prism Name replacements before input.
The Name field and a version-list row both carried `control|263`; the text-field
preference narrowed label matches but returned early on the ID branch. Toggle,
Cancel and session cleanup worked, but these were **0/3 complete workflows**.
The correction applies the same native text-field preference to shared IDs and
labels. Section scope is preserved; two genuine fields remain ambiguous, and
ordinary click resolution is unchanged. It does not invent a new ID or select
by position.

The parameterized regression failed with six assertions before the correction
(one resolution and one retained-ambiguity failure per native field role).
Afterwards, 40 focused target-resolution/action tests pass. `swift build
--product mecum`, the signed Release build and strict signature verification
pass. `make test SWIFT=swift` reports 2306 executed, 93 skipped, 2399 reported,
28 runs, `status: passed`, `problems: []`.

Release `fca8132475073bf7d8d3f6a5f301dde8f86d0da6a8fdb60d03c8b329d9a86b87`
then completes the original three Prism workflows from Mecum's UI. Requests
5792/5814/5834 use the actual field ID; fresh observations 5796/5817/5837
independently read exactly Qt1é🧪 / Qt2é🧪 / Qt3é🧪. Snapshots, Betas and Alphas
respectively change from off to on; each Cancel withdraws New Instance and
returns Prism Launcher 11.0.2. Every session closes and status
5808/5828/5848 is null. No OK, download, account or instance creation occurs.
No outside recovery or alternate target route is used.

Local logs are `shared-field-id-{red,green,cli,release,baseline}.log`;
`release-prism-shared-id-tools.json` retains scoped application evidence in
`/private/tmp/mecum-stabilization-round4-20261004`. These repetitions qualify
this Prism workflow, not Qt Quick, IME, cross-control drag or all Qt applications.

## Round 6 follow-up: scoped contextual menu composition

The Chrome contextual-menu request on Release `4c59af9c` opened a menu and
then failed with `subtreeUnreadable`. Its generic parent keyboard route could
not choose Select All or dismiss the modal tracking loop. A later adoption
still saw the menu; independent desktop cleanup was required and is not a
workflow pass. The original request and observation records are retained in
`release-chrome-dropdown-own-identity-tools.json`.

Both direct and brokered automation sessions now route `context_menu` through
`SeatContextMenuSelector` and `AgentSeat.withContextMenu`. One parent
observation admits the opening click. The menu's own identity-bound observation
admits one item click; the Driver revokes the menu context before verifying
cleanup. Neither ordinary parent typeahead nor Escape is sent by the consumer
while the menu is tracking. Existing destructive-action policy, section scope
and Qt's text-field-only restriction are preserved. The production perception
factory is used in both runtime paths.

Missing, ambiguous or disabled items close without a choice. Capture or delivery
failure preserves uncertainty and verified cleanup, without replay. A delivered
choice and a withdrawn menu remain `acted_unverified`: the caller must inspect
the actual command effect. The adapter does not infer Select All or Copy effects
from delivery or from a changing scene token. Turn release retains a primary
failure if cleanup also fails.

Focused controlled checks pass: 60 tests in five suites, including scope-bound
menu input, no-choice cleanup, policy refusal, capture qualification refusal
and item delivery refusal. The initial build lacked the explicit SeatCapture
import and failed before tests; after the import correction, the focused run
compiles and passes. The original application's failure is the RED evidence;
no missing old composition seam is represented as a compiled unit-test RED.
Native repeats and the final release checks remain pending at this entry.

## Round 5 follow-up: selecting a Qt field through the same ID

The next three Resolve workflows on Release `fca81324` successfully replace
the native Search field by ID with Resolve1é🧪 / Resolve2é🧪 / Resolve3é🧪,
verified in independent observations. A subsequent triple click by that same
`control|search` ID refuses three candidates: the field and two Search toggles.
No selection or Delete is delivered. All three search workflows are incomplete.
Each independent Import Project File / Cancel round trip works and leaves the
parent with null session status; this is a native panel check, not Import Media
in the editor. Requested project editing is still unrun.

Triple click now applies the text-entry preference used by typing, while normal
click ambiguity and two real fields remain refusals. The compiled regression
fails with nine issues before correction and then passes for native text-field,
text-area and combo roles. 41 focused action/resolution tests pass. Native
selection/deletion repetitions on the rebuilt candidate remain pending.

## Round 6 native repeat: menu effect and subsequent keyboard isolation failure

Release `5e285deccbf08281438849c4b63d79c6ebb3e3a20b93409413c164b7a13a7e58`
passes CLI build, signed Release build and strict signature verification. The
complete baseline reports 2313 executed, 93 skipped, 2406 reported, 28 runs,
`status: passed`, `problems: []`. These checks do not establish input isolation.

For the native repeat, the disposable HTML fixture gains a visible selection
range oracle fed by the real input's select/input/selectionchange events. The
original HTML is retained locally; no network, uploaded content or personal
document is involved. Root desktop setup reloads this fixture before the
Mecum attempt. A stale menu index was rejected by automatic approval while
Mecum exposed a Siri orb; fresh AX proved its actual Window menu and selected
the named worker through that menu. No Siri input occurred. This is setup,
not a test recovery.

In cycle 1, type_text succeeds and fresh observation reads Menu1é🧪 and caret
8-8 of 8. The scoped context_menu finds Select All, sends one item click and
reports chosenItem withdrawal. Independent observation reads 0-8 of 8 with no
menu, proving the intended selection. The following insert_text has no effect
on Chrome; the value and full selection remain. Cycles 2 and 3 fail at their
initial replacements: mouse clicks move the caret but the value stays Menu1é🧪.
No dependent dropdown request runs and no input is replayed. Every session
closes with null status. **0/3 complete workflows**; one menu selection effect
is proven. Scoped records are `release-scoped-context-menu-tools.json`.

A fresh native Mecum AX read after the campaign exposes Menu3é🧪 in its test
worker composer, although the composer was empty after submitting the test
prompt. Chrome still reads Menu1é🧪. This is an input-recipient isolation
failure requiring investigation; an input-method explanation is unproven.
Further live keyboard tests are suspended while the destination is diagnosed.
Only synthetic test text was involved and it was not submitted as a message.
Temporary diagnostics record event type, process IDs and correlation tags,
without character payloads, and are to be removed before final handoff.

### Controlled comparison of the input recipient

Diagnostic Release `1765409b`, with the previously approved AppKit anchor
verified as the foreground app, completes three distinct single diagnostic
sequences through Mecum. ASCII replacement, Select All, Delete and insertion
read DgBeforeA, selection 0-9 of 9, an empty field and DgAfterB. The equivalent
Unicode sequence reads DgPrimaé🧪, 0-10 of 10, empty and DgDopoé🧪. A direct
Unicode replacement of the live menu selection, without Delete, reads
DgSelé🧪, 0-8 of 8 and DgSosté🧪. Independent observations confirm the values,
every session closes with null status, and native Mecum AX reads an empty
composer after each sequence. These are comparative diagnostics, not three
repetitions of the acceptance workflow. Records are
`release-input-recipient-diagnostic-tools.json`,
`release-input-unicode-anchor-tools.json` and
`release-input-selected-unicode-anchor-tools.json`.

After normal Quit flushes the diagnostic log, it contains 68 submitted event
records and no received keyboard event in Mecum's local monitor. Submitted
events name the owned Chrome PID; their target-PID metadata is zero even in
successful sends. This alone does not identify the failing route or justify
changing that metadata. The earlier isolation failure is still open.

A separate public-activation anchor could not be bound: automatic approval
rejected Computer Use for Mecum Native Foreground Anchor. Its owned process
was stopped without UI interaction. No other method controls that rejected
app. The already approved anchor is subsequently closed normally. Mecum's
own temporary native startup activation is being checked before the next
comparison; a cutoff without a prompt is not an attempted workflow.

Diagnostic Release `fb00894a`, with native startup activation of its own
Mecum window independently verified, also completes the direct Unicode
selection replacement: FgPrimaé🧪, selection 0-10 of 10, FgDopoé🧪,
caret 9-9 of 9 and null session status. Mecum's installed local event monitor
receives no keyboard event and its native composer is empty. This comparison
does not establish the cause of the previous failure.

The full combined Chrome workflow is then repeated three times on that same
diagnostic candidate. Each fresh session reads Menu1é🧪 / Menu2é🧪 / Menu3é🧪,
the actual Select All range 0-8 of 8, direct replacement Picked1é🧪 /
Picked2é🧪 / Picked3é🧪 with caret 10-10 of 10, and dropdown Beta / Gamma /
Alpha. Independent observations confirm every value, menus withdraw and
all sessions close with null status. **3/3 complete diagnostic-candidate
workflows**, no replay or outside recovery. The native Mecum composer is
empty afterwards. Records are `release-menu-combined-native-foreground-tools.json`.
The old 0/3 and recipient failure remain in history; a repeat on a candidate
without diagnostic code is still required. Temporary code has now been removed
from both InputEngine and SeatReleasingDelegate, and final checks are running.

Final candidate without diagnostics:
`8d99683410213996759ba7d3be926b86a8be898bad337b67b0293d9d31adc10d`.
`swift build --product mecum`, the signed Release build and strict signature
verification pass. `make test SWIFT=swift` passes: 2315 executed, 93 skipped,
2408 reported, 28 runs, `problems: []`. The Debug `build-for-testing` and
`test-without-building` pass: 320 tests in 59 suites, 57.359 seconds. Test
database fault injection deliberately logs Core Data errors on owned temporary
WorkspaceTests stores; these are not errors in the user's workspace. No new
font crash occurs in this run; the earlier intermittent crash is not thereby
closed. `git diff --check` passes. Native repeats on this final candidate follow
these checks and are recorded separately from the diagnostic candidate.

## Pause and handoff on 2026-10-04

The user requested a pause. Verified changes remain on `elio/mecum-app`,
uncommitted, with unrelated existing changes preserved. No commit, staging,
push or branch switch occurred. The test worker is stopped and the owned
Mecum candidate is quit. The approved foreground anchor is closed; the idle
owned Qt fixture is terminated, with its launching session ending at exit 143.
Fresh native Chrome observation shows no tracking context menu. Cleanup is
not an acceptance pass. No background test or scheduled continuation is set.

On final Release `8d996834`, Resolve completes two Search replacement,
triple-click/Delete, Import Project File/Cancel and clean-close sequences.
Independent observations confirm exact Unicode values and clearing. In the
third sequence the triple click is delivered with an identical scene; the
worker stops before Delete because selection is not established, then closes
with null status. The synthetic Search value ResolveClear3é🧪 remains.
Import Media and project editing are still unqualified. Records are
`release-final-qt-triple-field-tools.json`.

Chrome completes two combined Unicode replacement, Select All, direct
selection replacement, dropdown selection and clean-close sequences on that
same final Release. The user stops the third sequence during `context_menu`.
That interrupted request records `contextMenuNotClosed` for menu 107251,
PID 99818, and a subsequent `turnNotHeld` release error, generation 23. It is
neither a complete pass nor an ordinary completed failure. The owned Mecum
candidate is quit normally; fresh independent Chrome AX shows Menu3é🧪,
caret 8-8 of 8, Gamma and no context menu. No input is replayed. Records are
`release-final-menu-combined-tools.json`.

The acceptance matrix has 22 completed cases across historical candidates
against 75 planned cases, about 29% completed coverage. Resolve's partial
search/panel checks and diagnostic-candidate comparisons are excluded from
that total. This is not an application stability percentage, and it does not
establish a 70–80% completion rate on the final candidate. Adobe's modal hang,
editing qualification, the earlier input-recipient failure and the remaining
family/OS matrix are still open.

The latest native exact-value and selection-range experiment is parked outside
production source at
`/private/tmp/mecum-stabilization-round4-20261004/PausedNativeSelection.patch`.
The compiled exact-value regression fails with nine issues before its fix;
the compiled selection regression fails with ten before its fix. After setup
import repairs and corrections, 74 focused tests pass. There is no complete
baseline, app build or native acceptance repeat for that experiment. Its
source changes have therefore been removed while the preceding verified
implementation remains. The final checks above apply to the retained
candidate, not to this parked experiment.

Automatic approval previously rejected Computer Use for Activity Monitor,
Python and Mecum Native Foreground Anchor because those apps were not approved
for Computer Use. No alternate UI route bypasses these rejections. Photoshop
remains running with its owned test documents; it has not been forcibly quit,
saved or discarded during cleanup. Work resumes only when the user requests it.
