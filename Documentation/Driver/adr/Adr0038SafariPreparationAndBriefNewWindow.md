# ADR 0038: Safari is prepared like a renderer, and opens its new window in front

Status: candidate, 2026-10-09. Measured through the app path (`BrokeredAutomationSession`
over a real `SeatBroker`) on macOS 27.0.1 (26A434) with Safari 27.0.1, in one dedicated
window of the owner's, with Safari inactive. Ticket 6a, phase 2. `unvalidatedBuild`
stays attached to every receipt; this is evidence about Safari and these pages.

## Evidence

Phase 1 drove the dedicated window through the app, 5 repetitions per case, on a local
fixture and on Wikipedia and Hacker News (read only there):

| Case, Safari inactive | Base `5c1b4eb` (AppKit, no preparation) | With the renderer's preparation |
| --- | --- | --- |
| button click | 0 of 5 | 4 of 5 |
| link click | 0 of 6 | 4 of 4 |
| text drag | 0 of 5 | 5 of 5 |
| scroll | 10 of 10 | 10 of 10 |
| keys and text (Tab, Shift-Tab, arrows, `type_text`, `insert_text`) | 0, `subtreeUnreadable` every time | not asked |

Safari never became frontmost in 12 prepared sessions. The CLI drives an adopted
application with `.universal`, which is `ChromiumPlatform`, so it never showed the
difference.

## Decisions

**Safari is driven with the renderer's preparation.** `TargetPlatform.chosen` answers
`.webKitBrowser` for the exact bundle identifier `com.apple.Safari`, after the
embedded renderer, Qt and UXP evidence and before the Apple prefix, and the seat is
handed `ChromiumPlatform`: a left click, a drag and a bulk insertion are prepared, a
right click, a key press, a typed string and a scroll are not. WebKit is not a
Chromium renderer and no renderer helper is looked for. Safari Technology Preview
and other WebKit shells are not covered until each is measured, and native
composition stays qualified for Chrome alone. No new platform type was written: the
policy is the same three Commands, and a second struct would have copied the same
switch.

**Keys without a focused control** are ADR 0014's follow-up of the same date, because
`AXFocusedUIElement` answers `-25212` on every reading of an inactive Safari, even
right after a click the seat posted. Its boundary also accepts the focus a prepared
Command exposes, which is what `insert_text` needs.

**File > New Window opens in front.** A menu command of Safari is read and pressed in
the brief activation of ADR 0013, 0020 and 0029
(`BrokeredAutomationSession.preparesMenuInFront`). `AgentSession.open` of a running
Safari with no window named has no seat window to activate, so
`BrowserOpening.openWindow` takes a front request of its own: `LaunchFocusComeback`,
armed on the person's window before anything is pressed, brings Safari's focused
window in front through a restorer of its own, key window included, the item is read
until it is enabled (at most two seconds) and pressed once, the front is kept until
the new window is listed, and the person's window is asked back with the existing
bounded restore. A read that found no enabled item presses nothing and is repeated; a
press that failed is final. With no way back to the person's window the browser is
not brought forward and the open refuses with the sentence it always had. Arming
reads the person's focused window with the 0.1 s timeout it always had, and asks once
more after `cannotComplete`: Claude's own window answered that way on the first read.

**Adoption waits for the window to reach the origin it was sent to.**
`confirmPlacement` accepted two agreeing readings 20 ms apart as settled, without
asking whether the window was where it had been sent. Safari moves a window in steps
after an accessibility write, each holding for 300 to 450 ms (reading the window
server every 15 ms), so in 4 of 17 phase 1 sessions the accepted frame was a step on
the way: the relocation targets were `(2031, 1225)`, `(1971, 1190)`, `(1890, 1142)`
and `(1560, 1012)` while the window ended at `(2036, 1228)`, and the first Command
read `geometryChanged` and was refused while a recovery relocated the window back to
the wrong step. A window that is stable short of its requested origin is now taken
there only after it stays put for one second, and at the end of the two second budget
when its last readings were stable, as before. A window its application holds
elsewhere pays that second once. This is a change to the shared placement rule and it
is separable: restoring the immediate return is one line
(`offOriginSettleNanoseconds`).

## Live results, final build (9 October)

Each row is an independent effect, not the tool's message: the fixture's server log
(page `keydown`, `focusin`, the field value, `selectionchange`, `scroll`, `input` of
the range), Safari's `AXURL` and the web area's scroll position. After every call the
frontmost application was read (workspace), and Safari was frontmost only in the File >
New Window run, which asks for it. A series stopped once because the person changed
application (Slack to Claude) and once for the alert below; each was re-run from the
start. Counts are repetitions.

| Case | Before (phase 1, base build) | After (this build) |
| --- | --- | --- |
| arrow without focus | `subtreeUnreadable` 100% | 5 of 5, `ArrowDown` on `BODY` |
| Tab from the body | `subtreeUnreadable` 100% | 5 of 5 delivered (first from `BODY`, then name, color, the toolbar, name) |
| Tab with a field focused by a seat click | `subtreeUnreadable` 100% | 5 of 5 in two runs, `keydown` on the field and `focusin` color |
| Shift-Tab with a field focused by a seat click | `subtreeUnreadable` 100% | 5 of 5 (4 with the page's `keydown`, 1 seen only as the page regaining focus) and 4 of 5 (1 refused before posting, `seatNotReady(starting)` while the seat adopted a new overlay window) |
| `type_text` into Name | `subtreeUnreadable` 100% | 5 of 5, the field reads `hello1` to `hello5` |
| `insert_text` into Name | `subtreeUnreadable` 100% | 5 of 5 (`Z1` to `Z5` appended); 0 of 5, `focusedNodeChanged`, before the boundary accepted an exposed focus |
| button click | 0 of 5 unprepared, 4 of 5 prepared | 5 of 5, the page's press count 1 to 5 |
| link click | 0 of 6 unprepared, 4 of 4 prepared | 7 of 7: five Wikipedia anchors (`AXURL` fragments `Features`, `Criticism`, `Architecture`, `See_also`, `External_links`), the fixture's link, Hacker News `new` (`/newest`) |
| text drag | 0 of 5 unprepared, 5 of 5 prepared | 5 of 5 on the fixture (`selectionchange`); 5 delivered on Wikipedia, whose selection `AXSelectedText` did not read back |
| scroll | 10 of 10 | 10 of 10 (`scrollY` 200 to 1000 and back); Wikipedia scroll up 5 of 5, scroll down at the end of the page changes nothing |
| range slider | never moved | 5 of 5 repetitions of two drags (`input` events), through a label drawn over the slider; see the limit below |
| File > New Window | opens nothing in the background (benchmark, CLI) | once: Safari in front 1.75 s, window listed 614 ms after the press, front handed back to the person's window, the new window closed by the session's teardown. Four earlier attempts refused before pressing anything: arming read the person's window with `cannotComplete` (fixed above) and left no log line, which `LaunchFocusComeback` now writes. The run was on the build before the last whitespace and comment edits |
| first Command after adoption | `geometryChanged` in 4 of 17 sessions | 0 of 19 sessions, on the builds with the placement change |

The first fixture run stopped when a system alert panel naming the new test host
(`UserNotificationCenter`) took the front for 1.6 s. It was not touched, and the host
was rebuilt at the path that phase 1 had used, after which it did not appear again.

## Findings without a change

**The stray popup.** A prepared click in a text field left a 280 by 168 untitled
Safari window on the person's screen in phase 1, which the next session adopted and
reported "returned on another desktop". It did not reproduce in the final runs. What
those runs show about Safari's own extra windows: the 66 by 20 traffic light overlay
(level 0, `AXDialog`, alpha 1, on screen above the window for the whole session) is
already classified a decoration, a new one appears when the window is raised and
adopting it briefly leaves the seat `starting`, and the URL field's suggestions popup
(784 by 626, level 0, `AXScrollArea`, "not a member yet") is adopted as a window of
the application and left where it is when the session ends. Neither is a document
window, but nothing read separates a popup from a dialog the person operates, so
adoption was not changed. The key route of ADR 0014 ignores what the seat reads as a
decoration or a tooltip and refuses while any other visible window of the process is
above the surface.

**The range slider.** The scene of this build carries no `AXSlider` at all
(`AccessibilityAugmentation` harvests no slider role), so the control has no name to
resolve (`no element 'Range'`, 10 of 10) and the drags above reach it through a
label drawn over it, which measures delivery to the slider and not its resolution.
The phase 1 scene had it labelled `Range`; that path did not reproduce. Perception is
not this ticket's layer.

**Shift-Tab leaves the page.** From the first form field it moves the focus to the
toolbar's address field and opens its suggestions; the next key goes there. That is
Safari's tab order, not a routing fault, and it is why a window above the surface
refuses keys for as long as the popup is up.

## Limits

- File > New Window through the menu tool is covered by the same brief activation as
  Photoshop's and TextEdit's and by a unit test of the decision, not by a live run:
  a second window would have been left open without input to close it.
- The base build was not run on the app path for that case.
- Arming needs the person's focused window to be readable; Safari is then not brought
  forward and the open refuses.
- A person's other visible Safari window above the surface refuses keys.
- The new window opens where Safari places it, over the person's window, for the time
  the seat takes to move it.

## What this does not authorize

No AXPress fallback for clicks, no AX attribute is ever written, nothing is typed on a
page of the person's. Safari being active is never requested for a Command.
