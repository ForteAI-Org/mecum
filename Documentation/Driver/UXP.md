# Adobe UXP background input

Photoshop's document, native filter dialogs, displacement-map chooser and UXP
New Document modal have different recipients. Classify the fresh observation
before input. The ordinary UXP family prepares nothing. A separately attested
recipient can require only its make-key pair and a 300 ms settle, with no
application activation record. See [ADR 0016](adr/Adr0016UXPModalKeysWithStaleFocus.md).

## Mecum app integration

Mecum's Xcode project links the repository's local `SeatBroker` product.
`AppModel` owns that broker, and each worker's `BrokeredAutomationSession`
uses it to adopt and drive windows through `SeatDriver` and `AgentSeat`.
The broker requires UXP framework evidence before selecting the measured
single left document click and editing-shortcut recipe for `com.adobe.Photoshop`.
Select All, Deselect, Invert, Undo and Redo use their layout-resolved character
origin and measured modifier combinations. Return, text, double clicks, tab
navigation and modal-opening shortcuts retain the ordinary policy. Other UXP hosts keep
the ordinary family policy until separately qualified.

`AgentSeat` removes document preparation from attested modal surfaces, then
selects recipient-only priming where their focus proof requires it. An explicit
override that requests full AppKit preparation on a UXP modal refuses before
delivery. The live editing rows use the adopted document recipe without a
per-command preparation override. Native JSX catalog and editing readers stay
test fixtures; the app receives no scripting or physical-input fallback.

On the same host, the integrated app recipe passed all seven non-drag live
rows for one fresh cycle each. No per-command document preparation override
was used. The exact seed catalog was restored after every owned document
close, all seven display/fence teardowns completed, and the input isolation
checks recorded zero physical events with foreground and cursor preserved.
The separate mandatory scrollbar-drag failure below remains unresolved; this
subset is not a pass of the complete eight-row Adobe matrix.

The original checkout that the Xcode app links also passed
`swift build --product mecum` and `make test SWIFT=swift`: 2,200 executed,
85 intentionally skipped, 2,285 reported across 28 runs, with no tier problems.
`make host-tests SWIFT=swift` passed its separate one-test and 29-test processes;
`python3 Tools/Driver/Scripts/test-run-tier.py` passed 15 checks. These are build
and infrastructure evidence, not additional Photoshop effects. The actual
Mecum Xcode app also passed `build-for-testing` and `test-without-building`
with `CODE_SIGNING_ALLOWED=NO`: 320 tests in 59 suites. Its local package
reference resolves to this same checkout.

The app recipe is deliberately narrower than the original full-key
calibration. A prepared double click or prepared text/Return prevented the
zoom field from committing, and preparing Cmd+Shift+N disturbed New Layer's
initial field. Ordinary double click, text, Return and modal-opening shortcuts
passed those controls. Only the measured single left click and semantic
editing shortcuts are prepared automatically; attested modals drop that
document recipe before recipient routing.

## Repeatable matrix

`make uxp-live-tests SWIFT=swift` runs eight rows in separate processes. Each owns
one Host lifecycle and up to three repeated cycles, stopping its own row on
failure. The target continues the remaining rows and returns an aggregate failure.
A synchronous native entry point loads the same built Swift Testing bundle;
reported counts still gate completion. It requires a trusted test machine,
coordinated exclusive desktop use, Accessibility, Screen Recording and Post
Event permissions. Photoshop must be running in English, in the background,
in Pro Editor mode, with only the named disposable RGB PNG open. Preflight
refuses an already held physical modifier or mouse button, then
checks its AX document URL and a fresh vendor-model snapshot with the exact URL,
document ID and active ID. AI Assisted Editor imports are not this fixture.

```sh
AGENTSEAT_UXP_DOCUMENT=/absolute/path/to/disposable.png make uxp-live-tests SWIFT=swift
```

| Row and flow | Independently required effect |
| --- | --- |
| Displace | Numeric fields change through `.text` and `.insertText`; Escape or measured Cancel removes the dialog |
| Displacement-map chooser | Return opens a different Window ID titled "Choose a displacement map"; Escape or Cancel removes it |
| Duplicate Layer | Escape or measured Cancel removes the explicitly selected dialog, including AXModal=false |
| New Document cancellation | Escape removes the UXP modal |
| New Document Return | The modal disappears; the vendor model contains one new active unsaved ID beside the unchanged seed |
| Two document tabs | Ctrl+Tab selects each exact model ID, checked independently from AX titles |
| Document view controls | Measured zoom field reaches 100%; wheel changes the independently read scrollbar value |
| Document scrollbar drag | A separate mandatory row must reach the measured track destination within 0.02 of normalized travel; currently failing on the named Photoshop build |
| Close created document | Layout-resolved Cmd+W closes the exact owned ID; the complete model returns to the single original ID and URL |
| Selection | Cmd+A must produce exact canvas bounds; Cmd+D must clear them |
| Pixel editing | Cmd+I must exactly reverse the native histogram; Cmd+Z must restore it |
| Layer editing | Cmd+Shift+N, exact Unicode name and Return must add one layer; Cmd+Z / Cmd+Shift+Z / Cmd+Z must undo, redo and restore |
| New Layer modal | Explicit menu setup, Unicode bulk insertion and Return create the exact owned layer; Cmd+W and measured Don’t Save close only the owned document |
| New Layer typed text | A separate row uses `.text` with accents, a composed emoji and a combining mark; Return must create the exact native layer name |

Followed surfaces must be contained in the Virtual Display and provide a fresh
captured Frame with the selected Window ID. `currentTarget` can still name the
document while observation selects an app-modal dialog; it is not the input
recipient. After closure, observation must return to the original document
within five seconds, including production withdrawal grace. Modal capture also
allows five seconds of fresh observation while rendering settles. Waiting never
replays input.

AX menu presses are setup, not background-shortcut evidence. A positively
disabled menu can use [ADR 0013](adr/Adr0013BriefActivationForStaleMenus.md)'s
`bringTargetBrieflyInFront` with verified handback before input. An open modal,
unreadable readiness or failed handback refuses. After Return, Photoshop may
retain a retired New Document WindowServer proxy. The consumer explicitly
releases that already closed surface with `leaveOnVirtualDisplay`; offscreen
geometry alone is never closure proof.

The test reads Photoshop's `app.documents` and `app.activeDocument` through a
scoped JSX fixture, opened with LaunchServices. Each complete snapshot has a
fresh nonce, footer, unique IDs, exact names and saved paths. The native path is
retained verbatim for cleanup: Foundation may normalize `/private/tmp` to `/tmp`.
A title or a single AX window cannot attest how many tabs exist. The fixture
refuses more than two documents. Script opening can activate Photoshop; the Seat bounds that explicit
fixture activation and verifies foreground handback. A timed-out read permits
one fresh read after handback; input and mutation are never replayed. A separate
500 ms admission wait handles only `noUserWindow` refusals before any activation
request or script launch, while the foreground and Photoshop lifetime remain
unchanged. Once a launch exists, no admission retry is allowed. Every other
refusal remains final.

Editing snapshots also attest the exact owned ID, layer count/name, canvas and
selection bounds, all 256 native histogram bins and active history name/count.
The test reads its baseline before focusing the canvas, and avoids wheel
scrolling in editing rows so the measured canvas point remains over the image.
Each shortcut measures foreground, cursor and physical input before the
explicitly activated model read. No subsequent canvas click may stand in for
Cmd+D or Undo.

New Layer can be an opaque AXLayoutArea with no title and AXModal=true. Only one
new, independently identified own-process modal is accepted, with a positive
absence of exposed children; unrelated AX errors refuse. Unicode text remains
an unknown effect until Return produces the exact native layer name. The
closure row normalizes typographic apostrophes when matching Don’t Save, then
clicks its measured frame and verifies the complete native catalog. Capture and
input failure share the same cleanup boundary. A scoped live fault injection
forced the Seat into `failed` with its owned Save prompt open. Native Cancel
withdrew only that prompt; an independent native fixture then read the complete
catalog and closed only the exact owned unsaved document. Both native requests
verified the original foreground and cursor. The injected row failed as intended,
restored exactly the seed and recorded zero physical input. The injection was
removed and the experiment repeated after the fixture refactoring.

Native Cancel requires one exact enabled button, the owned AX element, full
Window ID/process identity, and independently observed AX removal and
WindowServer withdrawal. Native document cleanup retains both IDs and names,
the exact seed URL and the owned document's lack of a native path. A failed
Seat cannot authorize any input. Its fixture activation uses a separate
`UserFocusRestorer`, reattests the original destination, waits at most two
seconds for output and verifies handback for 250 ms. It posts no keyboard or
pointer command and replays no created LaunchServices request.

A cancellation may leave AXMainWindow, AXFocusedWindow and AXFocusedUIElement
all reporting typed `noValue` while the exact PNG remains the sole AX window.
Preflight admits this case only with the exact seed URL, a nonmodal standard
window and full WindowServer identity. Its native activation explicitly includes
the destination-bound make-key pair and verifies restored main-window identity,
foreground and cursor before adoption. Unknown reads, another window or a modal
refuse. The directed-input endpoint checks are unchanged. Merely requesting
foreground without the make-key pair timed out and was not qualification.

Failed or incomplete cleanup fails the row. No top-level native menu is opened
as a catalog oracle: that experiment left Photoshop in AppKit menu tracking and
invalidated its subsequent input comparisons. Capture directories are created
before writing their PNGs; failure to write artifacts remains a test failure.

## Modal settlement

A Save prompt's smaller server frame was previously mistaken for a Stage
Manager thumbnail. The attempted old-size stage and rollback met read-only
AXSize and failed the Seat. In-place adoption now accepts a settled new body
only through bracketed AX/WindowServer identity and geometry proof, with the
existing tolerances and two stable rounds. A disagreeing full AX body still
requires thumbnail staging. Its operational size, staged classification and
return destination use the same confirmed body; a physical window retains its
original return obligation. The pure regressions first reproduced adoption and
release failures, then all 55 follow/adoption/rollback checks passed. See
[ADR 0017](adr/Adr0017InPlaceWindowSettlement.md).

## Recipient proof

A UXP leaf is its own recipient. A complete own-window dialog subtree can qualify
when global AX focus is absent or names another adopted window of the same
process. This requires an application-modal relation or an explicitly selected
standalone dialog, including AXModal=false. Remote, windowless or unreadable
modal descendants refuse.

A selected standalone document can qualify its AXMainWindow subtree when AX
explicitly reports no focused control and AXFocusedWindow is a different
same-process proxy with a positive Window ID, AXLayoutArea, AXUnknown,
AXModal=false and a successful zero-child reading. No blocking modal, attached
sheet or named host may exist. This proof does not claim a focused control.

A geometrically contained window can still be blocked by the selected modal.
Stage Manager's thumbnail made this case observable after a window resize:
stale global focus named the blocked document, whose small bounds fit inside
New Document. Such a candidate now refuses as `recipientModallyBlocked`, in
both endpoint resolution and command-boundary revalidation. The own modal
proof may then qualify its exact make-key recipe; containment never overrides
modal eligibility.

Both subtree proofs have a 300 ms budget, 1,024-node limit and depth 64. Identity
and focus readings bracket the proof, which is repeated at the operation boundary
and after priming before the first post. Overrides cannot omit the exact
recipient's pair, choose another window or activate the application.

Rows require zero physical input, preserved foreground/cursor, verified cleanup
and complete display/fence teardown. Unreadable effects fail closed. Cleanup
only touches the row's own dialogs and Untitled tab; the preflight PNG is never
saved or closed. The named editing rows qualify only their specific commands;
view controls do not qualify pixel tools, IME,
other Adobe hosts, versions, localizations or operating systems.

## Timing and evidence

`AGENTSEAT_UXP_CYCLES` accepts 1 through 20. `AGENTSEAT_UXP_ARTIFACTS` names an
existing temporary directory for PNGs; inspect them before claiming perception
coverage. `AGENTSEAT_UXP_SETTLE_MS` accepts 0 through 1,000 for explicit modal
calibration; negative platform waits clamp to zero. Default priming is 300 ms.
Full AppKit preparation remains explicit calibration through
`preparingLeftClicks` and `preparingKeys`; the app uses the narrower
`preparingDocumentShortcuts` instead of preparing every key. The default and attested modal recipes
retain their own policies. Logs retain wall intervals, preparation and
intentional wait. They include setup/polling and are not microbenchmarks.
Counts must match; exit status alone cannot establish completion.

On 2026-10-03, Photoshop 27.10.0, macOS 27.0.1 (26A434), Mac16,1, the clean
retained-source matrix passed seven of its eight rows, each for three repeated
cycles: 12 modal flows, document creation/tab switching/view controls/close,
selection, pixel inversion with undo, layer creation with undo/redo/restore,
New Layer bulk text and the separate New Layer typed Unicode row. Typed input
posted 40 events in each cycle; the native model verified the layer name only
after Return. Both New Layer rows adopted, captured and closed all three Save
prompts at their settled 260 × 276 server size.

Every native snapshot verified the exact seed and created IDs; each successful
close returned to the sole unchanged seed. Foreground and cursor were preserved
with zero physical input in all eight rows, and all eight display/fence
teardowns completed. The mandatory scrollbar drag still failed at its first
cycle, then independently restored exactly the original native document model.
The aggregate matrix remains failed. Inspected PNGs included Displace's fields,
New Layer and the Save prompt; these captures establish visible surfaces, while
native model checks establish the editing effects.

An earlier attempt named a nonexistent capture directory. Its owned modal was
cancelled, but cancellation left typed absence of all main/focus AX attributes.
That attempt and a foreground-only refresh timeout are not qualification.
The retained fixture creates capture directories and admits only the bounded,
identity-bound native preflight described above. A separate Displace row passed
from the absent-main state before the clean matrix was rerun.

An earlier repetition was contaminated by Command already held in HID state:
Displace displayed Default instead of Cancel. Zero new physical events did not
establish an idle initial keyboard. After a separate diagnostic release and
own-dialog cleanup, the clean matrix above passed its modal/document rows. The
fixture now refuses held modifiers/buttons before adoption and never releases
user keys itself.

Earlier document runs relied on AX titles and window counts, and captures
revealed extra tabs. Those results do not qualify complete document cleanup.
Hardcoded key 13 also produced comma on this installed layout; the current
Cmd+W row resolves `w` from the layout with an empty Unicode payload. Input
comparisons made while the native menu-tracking experiment remained active
are inconclusive.

After a tab switch, the consumer waits for the same attested keyboard evidence
to remain stable for 300 ms before resolving the next command. A title change
had preceded an AX focus-proxy transition; the Driver's boundary refusal remains
intact. Vendor-model inspection and cleanup are fixture operations, outside the
claimed directed input path.

The native entry point fixes a separate runner failure: Swift async main could
exit during native capture with no completion summary. Both Host processes now use synchronous main with their same built tests;
the seat cycle remains separate from the other 29 checks. This runner change is test infrastructure, not
application input evidence and not Ledger promotion.

After the settlement and fixture changes, the retained source passed the
following serialized checks on that host:

| Command | Outcome |
| --- | --- |
| `swift build --product mecum` | Passed |
| `make test SWIFT=swift`, with Host/Live opt-ins unset | 2,195 executed, 82 skipped, 2,277 reported across 28 runs; passed |
| `make host-tests SWIFT=swift` | One native seat-cycle check and 29 other checks; all 30 passed with no skips |
| `swift test --filter 'AppWindowFollowTests\|WindowAdoptionTests\|WindowReleaseTests' --no-parallel` | All 55 tests in two matching suites passed, including natural settlement, no-write release, thumbnail staging and rollback |

The 82 skips retain their explicit opt-in or environment requirements. None is
Live qualification. The Photoshop matrix command above returned failure because
its separate mandatory drag row failed; the seven passing rows are not an
aggregate pass.

## Document menu shortcuts

Full preparation of a key alone can restore Photoshop's zoom field as first
responder. In the measured failure, AXFocusedUIElement was AXTextField with
value 100%; preparing Cmd+A did not select the canvas. A measured left click
on the selected document using `UXPPlatform().preparingLeftClicks` establishes
the canvas responder. The original calibration then used `UXPPlatform().preparingKeys`;
the integrated app now prepares only the measured editing shortcuts described
above. Both are ordinary observation-bound `Seat.send` calls. No post-send hold,
extra click between Cmd+A/Cmd+D or Undo/Redo, native mutation or physical
foreground change qualifies these effects.

Three cycles independently attested exact canvas selection/clear, reversed
histogram/original histogram after Undo, and the exact Unicode layer followed
by Undo/Redo/Undo with native layer count and history. The default UXP policy
remains unchanged. Do not prepare a blocked document while a modal is open:
a prior full preparation on Duplicate Layer's host crashed Photoshop.

Separate foreground controls with PID keyboard posting qualified the same
selection and Undo oracles before this recipe passed. An owned AppKit fixture
also executed Select All with full preparation while preserving the physical
foreground. These controls explain the diagnosis; they do not qualify another
Adobe host or a generic AppKit matrix.

## Known drag failure

The mandatory `documentDragInBackground` row currently fails: the exact canvas
scrollbar does not reach the measured destination after a paced directed drag.
The oracle derives the target normalized value from the measured handle/track
and allows 0.02 tolerance, with a substantial change from the initial value.
A small click-induced nudge cannot qualify the intended drag. Its start and end
come from measured AX handle/track frames and fresh, identity-bound geometry;
its oracle reacquires the window and scrollbar. Independent captures show the
handle still at the bottom. The matrix therefore does not qualify Adobe drag
and `make uxp-live-tests` cannot be reported passed while this row fails.

A passive `CGEventTapCreateForPid` probe observed all ten events at Photoshop's
process boundary: down, eight dragged events and up. The routed window number,
owner connection and record-local points still matched the measured window and
handle/track. Combined/HID button state remained false throughout. This proves
arrival at the process tap, not consumption by Photoshop's scrollbar code. A
local `NSEvent(cgEvent:)` conversion in the runner is not target-side geometry
proof because the runner does not own Photoshop's window.

A scoped physical comparison on the same blank document passed with HID posting:
value about 0.497 to 0.005, system left-button state true during the press, and a
moved physical cursor. Direct PID posting failed with and without window routing.
An annotated-session PID/PSN comparison also failed, preserved the cursor and
left combined/HID button state false during the press. A separate `CGEventPostToPSN` comparison also failed and left
combined/HID button state false, with independently verified native cleanup.
A session-tap comparison passed with combined button state true and HID state false, but
moved the physical cursor just like the HID control. Neither passing global
route satisfies User Seat preservation. Preparation, source-state,
pacing, timestamp and geometry variations did not establish a passing directed
recipe.

A later paired comparison failed in all three directed conditions: the staged
inactive document, the foreground physical document, and the inactive physical
document. Each started at 1.0 and remained at 1.0 for a destination near 0.007.
The HID control on the same owned document reached about 0.0084; its 11 physical
events were counted and cursor/foreground restoration was verified. It is a
diagnostic control, not a passing background row.

A passive one-second sample during that successful HID press placed the main
thread in `NSScroller.mouseDown`, Photoshop's tracking function and its own
`NSApplication.nextEvent` wrapper. Read-only inspection of the ARM64 executable
connected that sampled tracking function at image offset `0x295d824` to repeated
`+[NSEvent mouseLocation]` calls. The class reference at `0x109d5a9e0` binds to
AppKit's `NSEvent`; the selector reference resolves to `mouseLocation`. The loop
subtracts those screen points to derive normalized knob travel. Its event wrapper
also receives drag/up events, but their delivered local points do not supply
that displacement calculation. The inspected Photoshop 27.10.0 executable has
SHA-256 `4423f5dbf1d389f65f5c3f0f17d3e260e340dc97de30849dfc3676151564f79b`.
Apple's [mouseLocation documentation](https://developer.apple.com/documentation/appkit/nsevent/mouselocation)
explicitly defines this reading independently of current or pending events.
The current process-directed recipe preserves that system position. Changing
only its event fields or preparation therefore does not supply the location
this named tracking loop reads. The Driver provides no process-private
replacement for that query; a solution needs a separately established capability
or host cooperation before this row can qualify.

A separate Photoshop function reads combined-session button state; it was not
present in the sampled scrollbar stack and is not established as this failure's
cause. A separate owned native AppKit NSScroller consumed the same ordinary PID drag
while its target-side logs reported zero pressed buttons, inactive application
and preserved User Seat. That diagnostic does not qualify a generic AppKit matrix. Apple's
[pressedMouseButtons documentation](https://developer.apple.com/documentation/appkit/nsevent/pressedmousebuttons)
distinguishes that state from the delivered event stream.

Canvas drag was also checked separately on the same owned blank document at
100%, with the Rectangular Marquee tool and zero native feather. Ordinary
preparation produced no selection. Full AppKit preparation produced a 129 by 89
selection for a 160 by 120 path; changing pacing produced a different incorrect
rectangle. Explicit movement deltas and the mouse-down global position did not
correct it. Pointer-window metadata, omission of the opening move, zero drag
click count, noncoalesced flags and mouse-touch subtype also retained the
incorrect rectangle. A separate native setup verified Snap disabled, then
restored its prior checked value; the same incorrect rectangle remained. An
AppKit NSEvent factory and an initial stationary drag sample also did not fix
it. A diagnostic shift of only the mouse-down record-local point by
31 pixels produced exactly 160 by 120. AX, public WindowServer and the existing
private bounds reading agreed; no geometry-derived production correction has
been established. Omitting the local point did not select and caused a window
resize/staging refusal. The owned document was closed without saving; native
window zoom restored the fixture's usable physical-display geometry before the
final matrix above. An AX size setter had reported success without resizing.

A later paired canvas diagnostic measured 161 by 121 for that 160 by 120
path in all four conditions: staged directed, physical directed with Photoshop
active or inactive, and the HID control. A subsequent fresh-document repetition
again produced 129 by 89 at its first cycle, including with a passive process
tap. Omitting only the make-key pair passed once at 161 by 121, then failed on
the second new document at 129 by 89. None is a repeatable canvas recipe.

A passive sample during a one-second directed press reached Photoshop's
`TNonPollingImageTrackerMgr::LoopTilDone`, unlike the scrollbar's NSScroller
loop. Read-only code inspection found its conditional `CWatchForMouseUp`
precheck leading to the combined-session button sampler above. This establishes
that the canvas path can consult that sampler; the diagnostic did not attest
its flags or prove that branch caused the 31-pixel error. The longer diagnostic
press itself produced a different invalid selection, so it provides stack
evidence only. All diagnostic timing and preparation changes were removed.

On the scrollbar, the same local-point calibration moved the value only from
1.0 to about 0.969, far from the destination near 0.007. Holding preparation for
300 ms did not pass the stricter oracle. All offsets, event-field and timing
injections were removed from production sources. These diagnostic effects do
not qualify canvas drag, scrollbar tracking or a portable UXP recipe.

HID was a diagnostic positive control, followed by cursor, window and foreground
restoration. It is not a background fallback: it changes the User Seat. Production
posting and the private event source retain their existing routes. Pixel/layer
tools outside the named editing rows, IME, localizations and other Adobe hosts
remain unqualified. A passing modal or view-control row cannot close this failure.

## Inventory and qualification

The 4 October follow-up fixes a pixel-grouping defect in New Document: Close's
label had named the neighboring Create border. Three signed Mecum UI repeats
on candidate `6443dc84` cancel without creating a document; independent native
Window menu inspection confirms the same four owned documents before and after.
See [stabilization rounds](StabilizationRounds.md#round-4-neighboring-photoshop-button-labels).

The signed Mecum application flow on 3 October 2026 reached Photoshop 27.10.0's
New Layer and New Document dialogs through the app's tool path. It exposed
additional integration limits: replacing the layer name left existing text,
opaque fields prevented exact Unicode readback, and background Undo/Redo menu
items remained disabled after the modal. The created test layer was not
removed by that flow. Its claimed New Document cancellation was incorrect:
independent WindowServer title and Window menu inspection confirm an additional
`Untitled-1` alongside the owned seed. Scene metadata now reads the current
title of the exact captured window instead of its adoption title; that corrects
the stale document evidence, not the modal action itself. The
[application flow checks](ApplicationFlowChecks.md) retain these failures.
They do not extend the direct Driver rows or qualify the complete workflow.

A later offscreen repeat found two discovery defects: the broker admitted only
onscreen/fullscreen candidates, and the `windows` tool read a separate onscreen
inventory. Nonminimized standard AX windows now have a native fallback with
matching server identity and attested body geometry, and the tool delegates to
that discovery. The rebuilt app lists
the same owned Photoshop window without manual foreground activation. Its
separate adoption succeeded, but the first New Layer shortcut was refused with
`geometryChanged` before delivery; no modal appeared. Canvas controls were not
unambiguously named, so the subsequent editing sequence was not attempted.

AXWindows requests Window IDs; WindowServer independently attests geometry and
owner lifetime. Refused facilities, unavailable lists, malformed geometry and
failed attestation retain their cause. None becomes successful absence. Partial
inventory refuses. Auxiliary rows do not become application windows merely
because their PID matches Photoshop.

Missing ledger qualification does not block runtime-checked, permission-granted
operation. Readiness and Receipts retain `unvalidatedBuild`; debug and release
use the same policy. See [ADR 0015](adr/Adr0015UnqualifiedBuildsRemainUsable.md).
Local results do not promote the ledger or qualify a different environment.
