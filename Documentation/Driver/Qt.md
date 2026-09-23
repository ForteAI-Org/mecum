# Qt targets

`QtPlatform` is the explicit policy to pass to `AgentSeat.adopt` and `send` for
a Qt target. It uses the same window identity, capture and `CGEventPostToPid`
route as the other families. The policy prepares left clicks, drags and bulk
insertion; it leaves right clicks, single keys, typed text and scroll
unprepared. Bulk insertion waits 150 ms after preparation, the other prepared
commands 30 ms. Drag pacing, modifier flags and held-key repeat pacing use the
shared defaults. These are policy choices, not evidence that every Qt widget
has been qualified.

## Live target and limits

The measured target is **DaVinci Resolve's Project Manager**
(`com.blackmagic-design.DaVinciResolve`) on macOS build **26A428**. The build is
not in the compatibility ledger; the Live harness marks every receipt
`unvalidatedBuild`. The test is opt in with both `AGENTSEAT_LIVE_TESTS=1` and
`AGENTSEAT_QT_TESTS=1`, and requires DaVinci to be open on Project Manager.
The target is the existing application, so tests restore the Search control
and never open, create or delete a project.

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
| `send(.click(..., .left, count: 1))` | Prepare, 30 ms | Search checkbox changed `0 → 1 → 0` with a second click. The unprepared AppKit recipe also worked on that control. | Passed |
| `send(.key)` | No preparation | Backspace removed one character from Search after text entry. Other virtual keys and key phases are pending. | Partial |
| `send(.text)` | No preparation | One typed `x` appended to the Search query. Multicluster and composing text are pending. | Partial |
| `send(.insertText)` | Prepare, 150 ms | Atomic `qtbgprobe` insertion appeared in Search. The unprepared AppKit recipe also worked on that field. | Passed for simple text |
| `send(.drag)` | Prepare, shared pacing | AX text selection changed from `{9, 0}` to `{0, 8}` by a paced drag between measured text points. Widget drag and drop is pending. | Partial |
| `send(.click(..., .right))` | No preparation | No Qt contextual menu effect or cleanup oracle yet. | Pending |
| `withContextMenu` / menu observation / item action | Shared | The kit's `menuSurfaceStill` ability is not qualified; no Qt item action can be claimed. | Pending |
| `send(.click(..., count: 2))` | Prepare, 30 ms | No reversible double-click effect measured on Project Manager. | Pending |
| `send(.scroll)` | No preparation | No scrollable Qt control with a measurable offset has been exercised. | Pending |
| Modified key / shortcut / held repeat | No preparation, shared flags and pacing | Search Backspace was unmodified; modifier and repeat semantics remain unmeasured. | Pending |
| Window watch / modal child / return | Shared | Only the initial Project Manager was adopted and returned; no new Qt window or sheet was opened by the test. | Partial |
| `release(..., .returnToUserSeat)` | Shared | Project Manager returned to its former placement, display removed and fence released. One long rerun overlapped physical cursor and foreground-app changes, so that run's User Seat equality is inconclusive. | Passed for window return |

The checked-in suite is `QtDriverLiveTests`. Its five rows discover the
window, stage and return it, capture it, toggle Search, and drive text and
selection. The comparative research runs also tested the Chromium and AppKit
recipes against Search; the checked-in regression uses `QtPlatform` so it
qualifies the public Qt entry point directly. Native Qt dialogs, custom
widgets, context menus and DaVinci's main editing workspace require separate
effect-based rows before their functions can be marked passed.

Qt's own documentation distinguishes native and widget file dialogs, and
documents accessibility support for built-in widgets separately from custom
widgets. That is why an AX-visible Search control cannot stand in for every
Qt control: [QFileDialog](https://doc.qt.io/qt-6/qfiledialog.html),
[Accessible QWidget](https://doc.qt.io/qt-6/accessible-qwidget.html).
