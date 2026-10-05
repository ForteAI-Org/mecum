# Qt targets

`QtPlatform` is the explicit policy to pass to `AgentSeat.adopt` and `send` for
a Qt target. It uses the same window identity, capture and `CGEventPostToPid`
route as the other families. The policy prepares drags and bulk insertion; it
leaves clicks, single keys, typed text and scroll unprepared. Bulk insertion
waits 150 ms after preparation, drags 30 ms. Drag pacing, modifier flags and
held-key repeat pacing use the shared defaults. These are policy choices, not
evidence that every Qt widget has been qualified.

## Live target and limits

The measured targets are **DaVinci Resolve's Project Manager and the user's
disposable recent project, `New Project 1`**
(`com.blackmagic-design.DaVinciResolve`) on macOS build **26A428**. The build is
not in the compatibility ledger; the Live harness marks every receipt
`unvalidatedBuild`. The Project Manager tier is opt in with both
`AGENTSEAT_LIVE_TESTS=1` and `AGENTSEAT_QT_TESTS=1`, and requires DaVinci to be
open on Project Manager. It restores the Search control and opens then cancels
the New Project dialog. It never creates or deletes a project.

Run `make qt-live-tests` with DaVinci open on Project Manager. It runs each of
the seven rows in a separate test process and checks that each printed its
final summary. All seven passed together on 26A428 after the AX locator was
adjusted for an intermittently unnamed Search field, including the menu row.
This avoids accepting the macOS failure mode where repeated virtual
display creation ends a process with exit status zero before the suite ends.
The ordinary `make live-tests` reports these rows as skipped and needs the
consumer fixture and browser for its other rows.

With `New Project 1` already open, `make qt-editor-live-tests` runs two separate
processes. One switches Cut to Edit and back through measured Qt controls. The
other opens DaVinci's own Import Media panel, waits for exact owned-surface
containment, clicks Cancel through that panel's observation and verifies the
editor returned. Neither selects a file, changes clips or saves the project.
This tier uses `AGENTSEAT_QT_EDITOR_TESTS=1`; it is separate from the Project
Manager tier because they require different starting windows. Both editor rows
and all eight fixture rows passed together on 26A428 after the follower change.

`make qt-fixture-live-tests QT_PYTHON=/absolute/path/to/python` runs eight more
rows against an owned Qt 6 widget fixture. That interpreter must have
`PySide6-Essentials` installed. Each row launches its own fixture in the
background, reads target-side JSON counters and measured widget frames, then
closes the fixture. The fixture is in `Tools/Driver/QtProbe.py`; it creates no
projects or user files. On this host the official PySide6-Essentials 6.11.2
wheel was installed into a temporary virtual environment, outside the repo.

The fixture also has a checkbox, `Probe checkbox`, and a list of invented names,
`Probe people`, for the living memory's desktop cases (a control already in the
requested state, the same structure with other names). Their state is
independent of the other widgets: `checkbox` (0 or 1) and `checkboxToggles`;
`peopleSet` (`A` or `B`), `peopleNames`, `peopleCount`, `selectedPerson`,
`selectedPersonIndex` (-1 when nothing is selected) and `peopleSelections`, with
`checkboxFrame`, `peopleFrame` and one `peopleRowFrames` entry per row. The
command file also takes `setCheckbox` (with a boolean `value`), `toggleCheckbox`,
`renamePeople`, which shows the other set of names and clears the selection, and
`resetChoices`, which unchecks the box, shows set `A`, clears the selection and
sets both counters to zero. The other keys and commands are unchanged. These
controls are a test fixture: they produce no Watcher input and are not the
Driver's `AGENTSEAT_FIXTURE_APP`. On 2026-10-03 they were run once on this host
with PySide6-Essentials 6.10.3 (6.11.2 did not install on the system Python 3.9.6, the one interpreter then):
the state keys, the four commands and the perception of the checkbox and the names
passed. A new fixture process applies again the last command left in the command
file, so a clean reset removes that command first.

The oracle for an input command is a change in DaVinci's own AX value, focus or
selected range. A posted-event receipt alone is not a pass. The oracle for
capture is a qualified `SeatFrame` and observation reference bound to the
attested WindowServer identity. The virtual display and HID fence are removed
at the end of every Live row. A User Seat change during a run makes its
isolation result inconclusive; it must not be attributed to Qt without the
fence's physical-input evidence.

Stage Manager may keep Project Manager as an offscreen thumbnail. In a later
reading its on-screen WindowServer inventory was empty while AX still exposed
the window and `WindowServerProbe.geometry(of:)` resolved its exact ID. The
Live test therefore starts from AX, requires the matching WindowServer
identity, and lets the seat stage the exact window. It does not infer a Qt
window from an on-screen row alone.

## Function matrix

`Passed` means an effect was observed on the named target, not a Qt-wide guarantee.
`Pending` means no target-side oracle has yet qualified that function for Qt.

| Kit function | Qt policy | Measured evidence | State |
|---|---|---|---|
| `adopt` and `stage` | `QtPlatform` | DaVinci's exact AX and WindowServer identity matched; its 910 by 640 window and the owned Qt 6 window moved into the virtual display. | Passed on both targets |
| `acquire`, `release(Turn)`, `confirm`, `concludeObservation` | Shared | Every input row acquired one Turn, confirmed the target-side effect of each posted command, concluded its observation and released the Turn. Held-key phases were completed before releasing their Turn. | Passed in measured rows |
| `switchTarget` | Shared | The Qt 6 fixture opened a second top-level window; the watcher adopted its exact WindowServer and AX identity. An explicit switch to it and back to the parent changed the observed target, and a routed click incremented each window's own counter once. The secondary was closed and explicitly released, then the parent returned. | Passed between two Qt 6 windows |
| `observe` / window capture | Shared | Qualified BGRA frame and reference for DaVinci's staged window; the Qt 6 menu's dedicated 128 by 26 frame was also captured. | Passed on measured surfaces |
| `send(.click(..., .left, count: 1))` | No preparation | DaVinci Search changed `0 → 1 → 0`; New Project and Cancel opened and closed a dialog. The Qt 6 fixture's button counter incremented. A prepared DaVinci Cancel click caused `activationUnverified`, so clicks remain unprepared. | Passed on measured controls |
| DaVinci editor page controls | `QtPlatform` click | In the disposable `New Project 1` project, background clicks changed Cut `1 → 0`, Edit `0 → 1`, then restored Cut `1` and Edit `0`. The main window returned; no media or project contents were changed. | Passed on Cut and Edit |
| `send(.key)` | No preparation | Backspace removed one character and Right Arrow collapsed a selection in DaVinci. In Qt 6, `down`, three `repeated` key downs and `up` changed the target's key-down counter by 1, 3 and 0. Other virtual keys and modifier combinations need separate oracles. | Partial |
| `send(.text)` | No preparation | A typed `x` appended in DaVinci; Qt 6 accepted `é🧪` as two grapheme clusters and four events. Active IME composition remains untested. | Partial |
| `send(.insertText)` | Prepare, 150 ms | Atomic `qtbgprobe` insertion appeared in DaVinci Search and `qt6bulk` in the Qt 6 line edit. The unprepared AppKit recipe also worked on DaVinci's field. | Passed for simple text |
| `send(.drag)` | Prepare, shared pacing | DaVinci text selection changed from `{9, 0}` to `{0, 8}`; the Qt 6 slider changed from 0 to 81 along a paced drag between measured widget points. Cross-widget drag and drop remains untested. | Passed on measured drags |
| Custom painted `QWidget` | `QtPlatform` | A fixture-owned canvas handled its own mouse, wheel and key events. Routed commands produced two presses, eight drag moves, two releases, one wheel event and one `k` key press in target-side state, with zero physical HID events and an unchanged User Seat. | Passed on this custom canvas |
| `send(.click(..., .right))` | No preparation | A Qt 6 line edit opened its menu, and the target's right-click counter incremented. One Qt 6 rerun missed the menu; the following rerun passed. DaVinci's Search field opened a 184 by 164 menu in four consecutive runs after the locator accepted its uniquely unnamed AX text field. | Passed on measured controls; one earlier Qt 6 miss |
| `withContextMenu` / menu observation / item action | Shared | Qt 6 opened a menu wholly inside the virtual display, captured its own 128 by 26 surface, clicked the target-published action frame, incremented `menuChoices` and verified `chosenItem` closure. DaVinci's 184 by 164 menu was opened and captured in four consecutive runs after the Search locator correction. Its `Select All` label was identified in the image, clicked through the dedicated menu observation, closed as `chosenItem`, and selected all nine temporary Search characters. The query was cleared and Search closed. Earlier DaVinci attempts had stalled. | Passed on both measured menu item actions |
| `send(.click(..., count: 2))` | No preparation | Four events selected the whole DaVinci Search word, AX range `{0, 9}`; the Qt 6 line edit's double-click counter also incremented. | Passed on text |
| `send(.scroll)` | No preparation | Qt 6's scroll area changed its target-side offset from 0 to 60 after one wheel event. DaVinci's thumbnail slider stayed at `-50`; it is not a scroll offset oracle. | Passed on Qt 6 scroll area |
| Modified key / shortcut / held repeat | No preparation, shared flags and pacing | DaVinci's layout-resolved `⌘A` selected all nine Search characters. Qt 6 counted the `down → 3 repeat → up` sequence while the turn held the key. Other modifiers, shortcut destinations and repeat rates are pending. | Partial |
| Window watch / modal child / return | Shared | DaVinci's New Project opened window `8616`; the watcher adopted and staged it, then a Qt-policy click on Cancel closed it with the foreground app and cursor unchanged in a run with zero physical HID events. The Qt 6 fixture also opened its own modal child, followed window `14306` into the virtual display and cancelled it through a measured button. Qt kept the hidden dialog's WindowServer surface after Cancel, so its logical presence stayed unreadable; the consumer explicitly released that child with `.leaveOnVirtualDisplay` and returned the parent. Focus recovery was enabled for both rows. | Passed on both measured dialogs; explicit child release required on Qt 6 fixture |
| Qt widget `QFileDialog` | `QtPlatform` and shared watcher | The owned Qt 6 dialog was an adopted 654 by 491 window on the virtual display. Cancel was addressed from the widget's measured button frame; the target reported the dialog closed and `fileDialogAccepted == false`. Its child record was released, the parent returned and the User Seat stayed unchanged with zero physical HID events. | Passed on fixture widget dialog |
| Native `QFileDialog` and DaVinci Import Media | Qt opener, shared surface route | The owned Qt 6 target and DaVinci each exposed a separate native panel, initially on the physical display despite a virtual parent. A bounded Qt post-click follow tail now adopted both automatically before Cancel was sent; the target rejected its file dialog and DaVinci returned to the editor without an import. The fixture's first physical surface to confirmed containment measured 251 ms in one run. DaVinci's corresponding confirmation took 506–587 ms across three runs; those figures include stable-record confirmation, so they are not exact visibility durations. An instrumented DaVinci run found AX frame read at 1 ms, `AXPosition` returning immediately, full virtual containment 192 ms after the write, and two-reading confirmation at 396 ms. The initial physical presentation remains visible and does not meet a strict invisible-background guarantee. | Functional cancellation on both; physical exposure pending |
| `release(..., .returnToUserSeat)` | Shared | Both Qt targets returned after the measured rows, with displays and fences removed. Stage Manager briefly publishes a full-size surface after DaVinci's AX body reaches home; the return path now allows eight observations without rewriting the already-correct AX position. A deterministic unit row verified it. When DaVinci's initial stashed AX body instead appeared at `(1082, 776)`, a separate run refused return with the body at `(1082, 1012)`; that geometry remains unsupported. | Partial across stashed placements |
| `releaseAssignedApplication` / `releaseAssignment` | Shared | The Qt 6 command row explicitly ended the assignment after returning its window. The native-popup row used coordinated `releaseAssignment`: outcome `released`, the window `returned`, zero obligations. | Passed for one-window Qt 6 assignments |
| `useDropdownMenu` | Shared | The Qt 6 combo opened a 648 by 62 popup. A scoped Down and Return selected `Beta` in the target state and closed it as `chosenItem`. | Passed on Qt 6 combo |
| `useNativePopupMenu` | Shared | The fixture supplied a native `QComboBox.showPopup()` opener and a native choice callback through its local command channel. The scoped menu stayed on the virtual display, selected `Beta` in target state and closed as `chosenItem`. This qualifies the scope when a caller has a native Qt action; it does not imply the kit can invent that action for an external app. | Passed on fixture native action |

The checked-in Project Manager suite is `QtDriverLiveTests`. Its seven rows discover the
window, stage and return it, capture it, toggle Search, follow and cancel a
dialog, drive text and selection, and choose `Select All` from Search's menu.
The comparative research runs also tested the Chromium and AppKit
recipes against Search; the checked-in regression uses `QtPlatform` so it
qualifies the public Qt entry point directly. `QtEditorLiveTests` adds two rows
for the real editing window and its Import Media dialog. DaVinci's other
custom panels and editor actions still require separate effect-based rows.

The Qt 6 fixture rows add a scroll offset, slider value, text and key counters,
a measured context-menu action, both routed and native combo choices, a
modal child with a target-side open/closed flag, a painted canvas, a second top-level window
for target switching, and both widget and native file dialogs cancelled
without selecting a file. The native file-dialog row refuses to click until
the panel is contained by the virtual display. They verified every `InputCommand` case on
at least one Qt 6 widget, including right click, held-key phases and
multi-cluster text. The menu choices cover one effect in each target; other
commands exposed by a menu need their own semantic oracle.

The other public seat controls (`inputPauseReasons`, `coherentState`, state
subscriptions, `report`, and `stopAdmittingCommands`) operate on seat state,
not on a Qt input route. `textCommands` only splits text into atomic commands;
each resulting command still needs its own observation and Qt-policy `send`.
The old `sendText`, `sendSequence`, and `useContextMenu` overloads are marked
unavailable in the API and have no Qt implementation to qualify. A cancelled
Qt 6 modal child kept a hidden WindowServer surface, so
`logicalSurfacePresence` returned `unreadable` on this unvalidated build;
`reconcileLogicalClosure` cannot treat that as proof of closure. The consumer
released the child explicitly.

The target sometimes publishes Search's text field without an AX description.
The live locator accepts the only `AXTextField` in Project Manager while Search
is open; it does not choose an arbitrary field when several exist. Each row
checks the target's own effect, closes its temporary Search state and verifies
that the parent window was returned. User Seat comparisons begin after the HID
fence starts, so cursor movement during host startup is not assigned to a
driver command.

## Native panel visibility

A posted Qt click now keeps the window follower awake for at most one second.
During that bounded interval it scans every 60 ms, up to 20 passes; other
platforms retain their prior 120 ms cadence and ten-pass cap. This catches a
native panel published after the opening Command's first scan, without making
the watcher poll at rest. Placement confirmation also takes four early 20 ms
readings before returning to 100 ms polling; it still requires two agreeing
WindowServer frames of the same identity inside the virtual display.

These changes reduce avoidable delay, not the native panel's own presentation
or DaVinci's WindowServer movement animation. An external follower receives
the panel only after it exists on screen, so it cannot promise that the person
never sees it. A Qt application under the consumer's control can request a
widget file dialog with `QFileDialog::DontUseNativeDialog`; the owned widget
dialog was born in the virtual display. This option cannot be imposed on
DaVinci's existing native Import Media panel by the BG driver. The product
must surface this case as a visibility limitation until an application-level
offscreen creation path is available.

Qt's own documentation distinguishes native and widget file dialogs, and
documents accessibility support for built-in widgets separately from custom
widgets. That is why an AX-visible Search control cannot stand in for every
Qt control: [QFileDialog](https://doc.qt.io/qt-6/qfiledialog.html),
[Accessible QWidget](https://doc.qt.io/qt-6/accessible-qwidget.html). Qt's
[PySide6 setup guide](https://doc.qt.io/qtforpython-6/quickstart.html) describes
the virtual-environment installation used for the owned fixture.
