# Qt targets

`QtPlatform` is the explicit policy to pass to `AgentSeat.adopt` and `send` for
a Qt target. It uses the same window identity, capture and `CGEventPostToPid`
route as the other families. The policy prepares drags and bulk insertion; it
leaves clicks, single keys, typed text and scroll unprepared. Bulk insertion
waits 150 ms after preparation, drags 30 ms. Drag pacing, modifier flags and
held-key repeat pacing use the shared defaults. These are policy choices, not
evidence that every Qt widget has been qualified.

## Live target and limits

The measured target is **DaVinci Resolve's Project Manager**
(`com.blackmagic-design.DaVinciResolve`) on macOS build **26A428**. The build is
not in the compatibility ledger; the Live harness marks every receipt
`unvalidatedBuild`. The test is opt in with both `AGENTSEAT_LIVE_TESTS=1` and
`AGENTSEAT_QT_TESTS=1`, and requires DaVinci to be open on Project Manager.
The target is the existing application, so tests restore the Search control
and open then cancel the New Project dialog. They never create or delete a
project.

Run `make qt-live-tests` with DaVinci open on Project Manager. It runs each of
the six stable rows in a separate test process and checks that each printed its
final summary. All six passed together on 26A428 after the AX locator was
adjusted for an intermittently unnamed Search field. This avoids accepting the macOS failure mode where repeated virtual
display creation ends a process with exit status zero before the suite ends.
The ordinary `make live-tests` reports these rows as skipped and needs the
consumer fixture and browser for its other rows.

`make qt-fixture-live-tests QT_PYTHON=/absolute/path/to/python` runs five more
rows against an owned Qt 6 widget fixture. That interpreter must have
`PySide6-Essentials` installed. Each row launches its own fixture in the
background, reads target-side JSON counters and measured widget frames, then
closes the fixture. The fixture is in `Tools/Driver/QtProbe.py`; it creates no
projects or user files. On this host the official PySide6-Essentials 6.11.2
wheel was installed into a temporary virtual environment, outside the repo.

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
| `observe` / window capture | Shared | Qualified BGRA frame and reference for DaVinci's staged window; the Qt 6 menu's dedicated 128 by 26 frame was also captured. | Passed on measured surfaces |
| `send(.click(..., .left, count: 1))` | No preparation | DaVinci Search changed `0 → 1 → 0`; New Project and Cancel opened and closed a dialog. The Qt 6 fixture's button counter incremented. A prepared DaVinci Cancel click caused `activationUnverified`, so clicks remain unprepared. | Passed on measured controls |
| `send(.key)` | No preparation | Backspace removed one character and Right Arrow collapsed a selection in DaVinci. In Qt 6, `down`, three `repeated` key downs and `up` changed the target's key-down counter by 1, 3 and 0. Other virtual keys and modifier combinations need separate oracles. | Partial |
| `send(.text)` | No preparation | A typed `x` appended in DaVinci; Qt 6 accepted `é🧪` as two grapheme clusters and four events. Active IME composition remains untested. | Partial |
| `send(.insertText)` | Prepare, 150 ms | Atomic `qtbgprobe` insertion appeared in DaVinci Search and `qt6bulk` in the Qt 6 line edit. The unprepared AppKit recipe also worked on DaVinci's field. | Passed for simple text |
| `send(.drag)` | Prepare, shared pacing | DaVinci text selection changed from `{9, 0}` to `{0, 8}`; the Qt 6 slider changed from 0 to 81 along a paced drag between measured widget points. Cross-widget drag and drop remains untested. | Passed on measured drags |
| `send(.click(..., .right))` | No preparation | A Qt 6 line edit opened its menu, and the target's right-click counter incremented. One Qt 6 rerun missed the menu; the following rerun passed. DaVinci opened its menu once, then later diagnostic runs stalled. | Intermittent |
| `withContextMenu` / menu observation / item action | Shared | Qt 6 opened a menu wholly inside the virtual display, captured its own 128 by 26 surface, clicked the target-published action frame, incremented `menuChoices` and verified `chosenItem` closure. DaVinci's separate menu probe remains unstable: AX reading, capture and a later opening-only run stalled for over 30 seconds and were interrupted. | Passed on Qt 6, pending on DaVinci |
| `send(.click(..., count: 2))` | No preparation | Four events selected the whole DaVinci Search word, AX range `{0, 9}`; the Qt 6 line edit's double-click counter also incremented. | Passed on text |
| `send(.scroll)` | No preparation | Qt 6's scroll area changed its target-side offset from 0 to 60 after one wheel event. DaVinci's thumbnail slider stayed at `-50`; it is not a scroll offset oracle. | Passed on Qt 6 scroll area |
| Modified key / shortcut / held repeat | No preparation, shared flags and pacing | DaVinci's layout-resolved `⌘A` selected all nine Search characters. Qt 6 counted the `down → 3 repeat → up` sequence while the turn held the key. Other modifiers, shortcut destinations and repeat rates are pending. | Partial |
| Window watch / modal child / return | Shared | DaVinci's New Project opened window `8616`; the watcher adopted and staged it, then a Qt-policy click on Cancel closed it with the foreground app and cursor unchanged in a run with zero physical HID events. The Qt 6 fixture also opened its own modal child, followed window `14306` into the virtual display and cancelled it through a measured button. Qt kept the hidden dialog's WindowServer surface after Cancel, so its logical presence stayed unreadable; the consumer explicitly released that child with `.leaveOnVirtualDisplay` and returned the parent. Focus recovery was enabled for both rows. | Passed on both measured dialogs; explicit child release required on Qt 6 fixture |
| `release(..., .returnToUserSeat)` | Shared | Both Qt targets returned after the measured rows, with displays and fences removed. Stage Manager briefly publishes a full-size surface after DaVinci's AX body reaches home; the return path now allows eight observations without rewriting the already-correct AX position. A deterministic unit row verified it. When DaVinci's initial stashed AX body instead appeared at `(1082, 776)`, a separate run refused return with the body at `(1082, 1012)`; that geometry remains unsupported. | Partial across stashed placements |
| `useDropdownMenu` | Shared | The Qt 6 combo opened a 648 by 62 popup. A scoped Down and Return selected `Beta` in the target state and closed it as `chosenItem`. | Passed on Qt 6 combo |
| `useNativePopupMenu` | Shared | The fixture supplied a native `QComboBox.showPopup()` opener and a native choice callback through its local command channel. The scoped menu stayed on the virtual display, selected `Beta` in target state and closed as `chosenItem`. This qualifies the scope when a caller has a native Qt action; it does not imply the kit can invent that action for an external app. | Passed on fixture native action |

The checked-in suite is `QtDriverLiveTests`. Its six stable rows discover the
window, stage and return it, capture it, toggle Search, follow and cancel a
dialog, and drive text and selection. A seventh menu probe is diagnostic only.
The comparative research runs also tested the Chromium and AppKit
recipes against Search; the checked-in regression uses `QtPlatform` so it
qualifies the public Qt entry point directly. Qt file dialogs, custom
widgets, DaVinci context menus and DaVinci's main editing workspace require separate
effect-based rows before their functions can be marked passed.

The Qt 6 fixture rows add a scroll offset, slider value, text and key counters,
a measured context-menu action, both routed and native combo choices, and a
modal child with a target-side open/closed flag. They verified every `InputCommand` case on
at least one Qt 6 widget, including right click, held-key phases and
multi-cluster text. This does not remove DaVinci's menu failure or prove those
effects on other Qt widget implementations.

The target sometimes publishes Search's text field without an AX description.
The live locator accepts the only `AXTextField` in Project Manager while Search
is open; it does not choose an arbitrary field when several exist. Each row
checks the target's own effect, closes its temporary Search state and verifies
that the parent window was returned. User Seat comparisons begin after the HID
fence starts, so cursor movement during host startup is not assigned to a
driver command.

Qt's own documentation distinguishes native and widget file dialogs, and
documents accessibility support for built-in widgets separately from custom
widgets. That is why an AX-visible Search control cannot stand in for every
Qt control: [QFileDialog](https://doc.qt.io/qt-6/qfiledialog.html),
[Accessible QWidget](https://doc.qt.io/qt-6/accessible-qwidget.html). Qt's
[PySide6 setup guide](https://doc.qt.io/qtforpython-6/quickstart.html) describes
the virtual-environment installation used for the owned fixture.
