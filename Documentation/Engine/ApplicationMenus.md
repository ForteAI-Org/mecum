# Native application menus

Window controls and application menu commands have separate routes. `act` and `select`
continue to target window UI. `menus` reads native AX menu paths without opening menus;
`resolve_action` compares a query with the current window and the current catalog. A match
in both routes is ambiguous. The caller chooses an explicit tool; failure never silently
falls back to another route or replays an uncertain native request.

The catalog reports enabled, disabled or unknown availability, submenu parents, marks and
shortcuts. Reads are bounded by depth, node count and elapsed time. Partial reads cannot
prove absence. Typography normalization preserves punctuation and digits, except that
ellipsis and three dots compare equally. Duplicate siblings remain ambiguous.

`menu` is one tool with two readback contracts. `path` accepts an array of full titles or
an existing `File > Save As...` string; arrays also preserve titles containing `>`.
A path ending on a submenu lists its entries without pressing. A general leaf command
observes the result and reports whether a complete application-window inventory changed.
Reordering alone, an unavailable inventory or an uncertain AX reply cannot confirm success.
General commands do not supply typed memory evidence.

Optional `expect_window` requests the stronger contract: a NEW window with this exact title.
An existing destination, disabled/unknown entry, ambiguous path or destructive command without
authorization refuses before delivery. Both contracts share `ApplicationMenuOperating` and
`SeatApplicationMenus`, including the final native identity/observation boundary. Paths are
re-resolved before one AXPress; delivery uncertainty never causes replay. Apple-menu, hiding
and Quit commands remain unavailable. An explicit native File > Close may close a document;
the keyboard shortcut Command-W remains refused because it does not identify a menu target.

For the app's Adobe UXP adapter, a general menu command whose availability is explicitly
false may refresh the application for 150 ms and restore the user's focus, then read again.
This is an explicit platform exception to background execution, not an input fallback.
Unknown availability does not trigger it. It happens before any press, never after uncertain
delivery. The strict expected-window route does not use this refresh.

`press` retains the explicit AX dialog-button route for a button that ordinary input could
not reach. It refuses duplicate or disabled buttons, does not silently replace a click, and
does not teach memory. An uncertain native reply remains unverified even if a window changes.

The ordinary `menu` action belongs to an application, but its context belongs to a window. The Seat
holds a Turn, validates its observation, stop gate and geometry, and compares the application's
focused AX window ID with the observed recipient. It does not raise the application or
change AX focus to force a match. New windows are followed through the existing Seat lifecycle.
Native requests do not fabricate mouse input receipts.

With `expect_window`, success requires two complete window inventories identifying a new, unique destination and
an attributable capture of that window. AXPress success alone is not evidence. Typed
`MenuEvidence` keeps the semantic path and verified opening; a single matching open-window
goal can teach `MenuStep`. Recall says the menu is not observed until read again. Stored paths
never carry coordinates, process/window numbers, AX handles or cached permission flags.

CLI examples, with a Pro Tools Edit window already open:

```sh
.build/debug/mecum menus "Pro Tools" "I/O"
.build/debug/mecum resolve "Pro Tools" "I/O..." --seat --allow-unvalidated-build
.build/debug/mecum menu "Pro Tools" "Setup" "I/O..." \
  --expect-window "I/O Setup" --seat --allow-unvalidated-build
```

The same tools are available to the CLI chat and app worker. Menu actions are not batch steps.
The standalone `mecum menu` command retains its explicit expected-window contract. General
commands can act through chat, but toggled marks, clipboard effects, export completion and
other semantic outcomes still need dedicated verification before becoming learned steps.

## Opening a recent document before a window exists

`menus` accepts exactly one of `session` or `app`. The latter reads a running application's
catalog without opening a Seat. Reading a menu does not imply that a suspended Seat is ready.
`open_session` refuses a first capture smaller than 120 pixels on either side and releases it.

`open_recent(app, path)` is a distinct application-scoped operation. Its path must be a freshly
read, enabled, unique `File > Open Recent > /absolute/document/path` leaf. It does not launch an
app, guess a destination title or route arbitrary commands around a suspended Seat. Close an
existing session first. The app host holds the broker's exclusive lease across native delivery,
window discovery and adoption; the CLI serializes the operation in its own host. Cancellation,
process lifetime and ownership are checked immediately before AXPress. Blocking modal windows
and sheets refuse before delivery. No activation, focus change or mouse fallback is requested.
An application may itself show a window on the user's desktop before it is adopted.

The full file path (optionally followed by ` *`) must appear in two consecutive complete window
inventories and the captured, adopted window before `found_acted`. A basename alone is not proof.
A stable new intermediate window, such as Link Media, is adopted and returned as
`acted_unverified` with a live session and scene. It is never automatically confirmed. After a
timeout, cancellation or uncertain AX delivery, inspect windows; never replay the command blindly.
English menu paths and full-path window titles are the initial supported contract. Other locales,
basename-only menu entries and AXDocument-only attribution remain unsupported. Startup outcomes
do not teach a reusable memory action yet; they are not ordinary MenuStep window-opening proofs.

```sh
.build/debug/mecum menus "Adobe Premiere" "Open Recent"
.build/debug/mecum open-recent "Adobe Premiere" File "Open Recent" \
  "/absolute/path/from/the/menu.prproj" --seat --allow-unvalidated-build
```

The CLI returns its window on exit. Chat keeps an adopted result, including an intermediate
dialog, in its persistent session so the agent can observe it without pressing the menu again.
