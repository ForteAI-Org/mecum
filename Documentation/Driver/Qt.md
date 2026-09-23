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

`Passed` means an effect was observed on this target, not a Qt-wide guarantee.
`Pending` means no target-side oracle has yet qualified that function for Qt.

| Kit function | Qt policy | DaVinci Project Manager evidence | State |
|---|---|---|---|
| `adopt` and `stage` | `QtPlatform` | Exact AX and WindowServer identity matched; 910 by 640 window moved into the virtual display. | Passed |
| `observe` / window capture | Shared | Qualified BGRA frame and reference for the same window lifetime and staged geometry. | Passed |
| `send(.click(..., .left, count: 1))` | No preparation | Search checkbox changed `0 → 1 → 0`. New Project opened a Qt dialog; Cancel closed it. A prepared Cancel click caused `activationUnverified` with focus recovery enabled, so the unprepared policy is required on this path. | Passed on measured controls |
| `send(.key)` | No preparation | Backspace removed one character from Search after text entry; Right Arrow collapsed a text selection. Other virtual keys and key phases are pending. | Partial |
| `send(.text)` | No preparation | One typed `x` appended to the Search query. Multicluster and composing text are pending. | Partial |
| `send(.insertText)` | Prepare, 150 ms | Atomic `qtbgprobe` insertion appeared in Search. The unprepared AppKit recipe also worked on that field. | Passed for simple text |
| `send(.drag)` | Prepare, shared pacing | AX text selection changed from `{9, 0}` to `{0, 8}` by a paced drag between measured text points. Widget drag and drop is pending. | Partial |
| `send(.click(..., .right))` | No preparation | The diagnostic opened DaVinci's menu window on the virtual display in 67 ms once. Later runs stalled after opening Search, so this is not a repeatable pass. | Pending repeatability |
| `withContextMenu` / menu observation / item action | Shared | One scoped run opened a 184 by 164 menu within the virtual display and verified closure by a preparation cycle, with zero HID events. Reading the menu AX tree and observing its dedicated captured surface each stalled separate live runs for over 30 seconds. A subsequent opening-and-closing-only rerun also stalled. All were interrupted and Search restored; the diagnostic row requires `AGENTSEAT_QT_MENU_PROBE=1` and is excluded from `make qt-live-tests`. Menu item selection remains unqualified. | Pending repeatability |
| `send(.click(..., count: 2))` | No preparation | Four events selected the whole Search word, AX range `{0, 9}`. | Passed on text |
| `send(.scroll)` | No preparation | A background wheel event over the thumbnail slider left its AX value `-50`; the slider may not consume wheel input. A scrollable Qt container with a measurable offset is still needed. | Pending |
| Modified key / shortcut / held repeat | No preparation, shared flags and pacing | Right Arrow collapsed the Search selection and layout-resolved `⌘A` selected all nine characters. Other modifiers, shortcut destinations and held repeat are pending. | Partial |
| Window watch / modal child / return | Shared | New Project opened window `8616`; the watcher adopted and staged it, then a Qt-policy click on Cancel closed it with the foreground app and cursor unchanged in a run with zero physical HID events. Focus recovery was enabled for this row, though no restoration request was needed. The parent returned to its original AX position. | Passed on this dialog |
| `release(..., .returnToUserSeat)` | Shared | Project Manager returned to its former placement, display removed and fence released in the six-row suite. Stage Manager briefly publishes a full-size surface after AX has reached home and before its thumbnail appears; the return path now allows eight observations for this stashed-window case without rewriting the already-correct AX position. A deterministic unit row and repeated live returns verified it. When the initial stashed AX body instead appeared at `(1082, 776)`, a separate run refused return with the body at `(1082, 1012)`; that geometry remains unsupported. | Partial across stashed placements |

The checked-in suite is `QtDriverLiveTests`. Its six stable rows discover the
window, stage and return it, capture it, toggle Search, follow and cancel a
dialog, and drive text and selection. A seventh menu probe is diagnostic only.
The comparative research runs also tested the Chromium and AppKit
recipes against Search; the checked-in regression uses `QtPlatform` so it
qualifies the public Qt entry point directly. Qt file dialogs, custom
widgets, context menus and DaVinci's main editing workspace require separate
effect-based rows before their functions can be marked passed.

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
[Accessible QWidget](https://doc.qt.io/qt-6/accessible-qwidget.html).
