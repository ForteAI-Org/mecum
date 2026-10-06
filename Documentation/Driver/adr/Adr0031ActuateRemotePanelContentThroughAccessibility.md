# Actuate remote panel content through accessibility

Status: implemented, 2026-10-05. Offline seam tests only; the app path has no
live run yet.

## Evidence

A file panel opened by any host, as an AppKit sheet or as the application-modal
`runModal` Qt and Adobe UXP use, draws its content in
`com.apple.appkit.xpc.openAndSavePanelService`, one process per host. The seat
addressed that content as `InputEndpointRelation.remoteContent` and posted
routed mouse events to it (ADR 0014 records why its endpoint is discovered).

A probe using exactly that route, on 27 and 2026-10-05, found:

- a routed click into the content activated the host application in 75 to
  525 ms: DaVinci Resolve's sidebar row 3 of 3, the Where popup 3 of 3 in a
  modal and 3 of 3 in a sheet. On a sidebar row the click was also eaten, the
  first click on an inactive window: the selection did not change, while the
  same click with the host already active worked. The seat read that as the
  application taking the person's focus, recovered it, found no effect, and
  the agent retried into a second activation and a `waiting` seat;
- opening the panel did not activate the host (an AXPress menu item and a
  click on Resolve's Qt Import button, 0 activations);
- accessibility did the work with the host in the background and no
  activation, 3 of 3 each: AXPress on a popup opens its menu and on a menu item
  picks it; `AXSelected` on a sidebar row navigates; `AXSelectedTextRange` on
  the Save As field selects (an `AXFocused` write does not take);
  `AXSelectedText` replaces the selection as typing does; AXPress on Save or
  Cancel completes, answering -25204 because the panel closes first. All of
  these elements answer in the host application's own tree, with true screen
  coordinates;
- the popup's menu window is owned by the panel service, not the host, so the
  seat's dropdown path never saw it open and chose items with keys to the host;
- a full path typed in the Save As field is a file name: AppKit saved
  `~:Downloads:x.txt` in the current folder.

## Decision

A pointer Command whose endpoint is qualified remote panel content
(`SurfaceInputClassification.remotePanelContent`, a different process that is
the panel service) posts no event. `RemoteContentActuator` hit-tests the host
application's tree at the Command's point and
`DialogEndpointResolver.remoteContentPath` proves the element: from the node
under the point up to the first naming the surface, every node belongs to the
surface's or the content's process and names the content's window or none, and
the path names the content's window unless the endpoint itself was attested
from the surface's subtree. Anything else refuses.

A row bounds what a click reaches. In an Open panel the file name is a text
field inside its row's cell, with the size and kind as static text beside it
(Resolve, 2026-10-05), so a click there is a click on the file:

| Click | Element | Accessibility |
|---|---|---|
| left, 1 | anything inside a row but a control | `AXSelected` on the row |
| left, 2 | anything inside a row | AXOpen on the innermost element offering it, the row last |
| left, 1 | button, check box, radio, disclosure triangle, menu item, also inside a row | AXPress |
| left, 1 | text field, text area, combo box outside a row | caret at the end through `AXSelectedTextRange` |
| left, 3 or more | text field, text area, combo box outside a row | `AXSelectedTextRange` over the whole value |
| right, 1 | the nearest offering it | AXShowMenu |

A popup or a menu button refuses with `opensMenu`: pressed, it opens a menu
window the panel service owns that nothing in the seat follows, and the menu
stays open. `select` opens, chooses and closes it in one action. Any other
click refuses with `RemoteContentActuationRefusal.unsupportedRole` naming the
role. A drag or a scroll refuses with `gestureUnmeasured`: no
accessibility counterpart was measured, and whether a routed one activates the
host was not measured either. Nothing falls back to posting.

A click that leaves a caret or a selection outside a row remembers the field with the
surface, the content window and the selection generation it was proved under.
`.text` and `.insertText` on that surface, under that generation, with the
content window's identity unchanged and the field still answering, set
`AXSelectedText` and read `AXValue` back for the log. Any other Command forgets
the field; without one, text keeps the key route. `.key` Commands keep
`RemoteKeyboardPlatform` and its host priming.

The actuation keeps the posting boundary: the gate's preparation is awaited as
the driver awaits it, the reference and the endpoint are checked again after
it, and the closure expectation is unchanged. The Receipt counts no event and
names `PostRoute.accessibilityAction`; the trace records the accessibility call
as the send. -25204 from an action is a delivery, verified like any Receipt by
what follows it. A refused action or write may still have taken effect and is
never repeated: the broker reports it as an action whose effect is unknown, and
the engine as acted but unverified.

Every refusal carries one sentence telling the worker what to do instead, as
its `description`, which the broker's error mapper also answers with: the
engine prints a thrown error as it comes.

A dropdown's menu is looked for among the menus of the host and of the panel
service drawing a held remote file panel. The pixel dropdown opener, a routed
click, refuses while such a panel is held. The integration's `select` opens the
popup with its native action and reads the menu's items in the host's tree, or
else the service's. Titles are compared without the bidi isolates and marks
U+2066 to U+2069, U+200E and U+200F, ignoring case: Where read
`⁨Desktop⁩ — iCloud` and `iCloud Drive` twice. The one enabled item of that title
is pressed; none or several is a miss, which names the enabled titles, a repeated
one once with its count, and closes the menu with AXCancel on its AXMenu, which
answered 0 and closed the service's menu on Resolve on 2026-10-05. The popup's
native value is verified afterwards.

## Follow-up: a Save sheet (TextEdit, 2026-10-05)

A live worker saved from TextEdit, whose Save panel is a sheet on the document
window. No activation and no `waiting` occurred, and the accessibility route
ran. Four defects followed from the sheet:

- `holdsRemoteFilePanel` answered false, so the engine replaced the name with
  a click and selecting keys, and a key forgets the remembered field: the name
  was appended. A sheet has no `AXWindows` entry; accessibility lists it under
  its host's entry. The foreign content of a held modal is now read from that
  entry too, and attested as an endpoint is attested, drawn inside the surface.
  The seat and a Command's classification share one rule,
  `SurfaceInputClassification.isRemotePanelContent`.
- A target copied from the scene's `label = value` form, with the value in
  bidi isolates, named nothing. Resolution accepts that form when both halves
  name the element, and compares labels without isolates and marks.
- The engine pressed the Where popup by its label before the seat saw the
  click, opening the service's menu outside the scene. With a remote file
  panel held, the engine refuses a click on a popup or a menu button in the
  `opensMenu` words and presses no control by label.
- Once expanded, the sheet extended left of its document window. The picture
  covers both, while the integration admitted a point only inside the host's
  frame. A point inside a hosted sheet's picture region is now kept, and the
  seat admits it against the sheet or refuses it.

Not fixed here: the sheet's held record keeps the frame it was adopted at.
`AgentSeat.preflight` checks the requested window, the sheet, through
`currentIssues(for:)` against the window server, finds the expanded frame and
reports `geometryChanged`. The recovery that follows runs on `seatGuard`, which
`preflight` leaves on the host because a sheet owes no return; the host is
where it was, the episode finishes, and the sheet's record is never updated.
Every later Command on the sheet repeats it. The repair belongs to the
recovery, which accepts a settled resize only for the guarded window
(`acceptOperationalGeometry`).

## Follow-up: native menus of an ordinary window (Finder, 2026-10-06)

A worker opened Finder's contextual menu with a right click and then clicked
its item. The engine picks an item of an open menu with keys, and the seat sent
them through keyboard endpoint discovery, which refused: Finder's list answers
no Window ID for its focus (ADR 0014). A later `context_menu` then refused with
`contextMenuAlreadyOpen`, and the worker stopped.

- While a menu window of an ordinary window's process is open, its tracking
  takes every key. A key or text Command then asks no focused control and is
  posted to the window with the unprepared recipe, since a preparation's
  restore is what dismisses a menu.
- The engine first presses the menu's own `AXMenuItem` of that title, compared
  by `LabelText.menuTitleKey` (case, bidi controls, typographic quotes, a
  trailing ellipsis): Finder titles `Compress “carla_video_bn”` with curly
  quotes. Keys pick only where no item answers.
- A menu already open when `withContextMenu` starts cannot be told whose it is.
  It is closed with the action's own levers, the preparation cycle and then
  Escape, and the action opens its own; `contextMenuAlreadyOpen` remains for a
  menu that does not close.

## Follow-up: Finder's own windows (owner decision, 2026-10-06)

In a Finder window held by the seat, a click on the sidebar's Downloads row
changed nothing, single or double, and `/` did not open Go to Folder. The owner
decided that the ordinary windows of the applications listed in
`EndpointDiscovery.accessibilityClickedApplications`, Finder alone for now,
take their clicks through accessibility as a remote panel's content does.

- `DialogEndpointResolver.ownContentPath` proves the element: from the node
  under the point up to the window's own `AXWindows` entry, every node is the
  window's process and names the window or no window. The mapping is this
  ADR's; a click on empty space refuses with the role it reached.
- Scroll and drag keep their posted route: no activation is known for them,
  and a drag is how files move.
- A row selected in such a window also has its list (`AXOutline`, `AXTable`,
  `AXBrowser`) given the focus a pointer click would give it, so a key such as
  `/` reaches the file list. The answer is reported in the trace, never
  retried.
- Keys keep their route. The `/` failure was the focus: the seat routed the
  key by the focused control, which named the window (`attestedSurfaceItself`),
  while Finder's file list answers no Window ID, so the focus was not in the
  list, after two posted clicks on the sidebar. Commit `b84a7ca` changed only
  the guidance and measured nothing.
- A menu item named by the start of its title, "Compress" for Finder's
  `Compress “file.mov”`, is the unique enabled item whose key begins with it
  and a space or a quote (`LabelText.menuItemMatch`); an exact title wins.

Measured once with a probe on 2026-10-06: AXPress on Finder's
`File > New Finder Window` brought Finder in front within 573 ms and took its
other window out of Stage Manager's strip. The probe window was closed through
its close button and the front given back; nothing else was measured. Whether
a posted click on Finder's sidebar is eaten as a first click, whether the
focus write takes and whether `/` then opens Go to Folder are not measured.

## Follow-up: an open panel's icon view (2026-10-06)

Resolve's Import Media panel opened in icon view, and every click on a file
refused at its `AXImage`. Measured the same day with the probe on an
`NSOpenPanel` in icon view, its host in the background:

- the tree is the host's `AXList 'icon view'`, whose `AXSelectedChildren` alone
  is settable, the service's inner `AXList`, an `AXGroup` per item with nothing
  settable and no action, and its `AXImage` offering AXOpen and AXShowMenu;
- writing `AXSelected` on the group or the image, `AXSelectedChildren` of the
  inner list to the group, or of the outer list to the image, answered 0 and
  changed nothing: Open stayed disabled;
- `AXSelectedChildren` of the outer list set to the group selected the file:
  the list read one selected child, the image read `AXSelected`, Open became
  enabled, and AXPress on Open returned the file, with no activation (0 of 1);
- AXOpen on the image completed the panel but activated the host (1 of 1);
  AXOpen on the list view's name field did not (0 of 2).

So a click on an item outside any row or control, under a list whose selected
children are settable, writes that selection with each item between the hit
and the list, the list's nearest first, and keeps only a selection read back:
the list holding exactly that item, or the hit becoming selected. A write that
answers 0 without that is passed by; none verifying refuses with
`selectionNotVerified`. A double click selects the same way and then presses
the default button the list or the window names (`AXDefaultButton`); where none
is named it uses AXOpen, the one route measured to activate the host. Whether
the panel's window names its default button through the host is not measured.

Column view (`AXBrowser`) was not measured: a click there refuses with
`columnView`, which says to switch to list view. `select` now opens a menu
button, the view-mode control among them, with AXPress like a popup.

## Limits

- No live run was made for this change. The table above is the probe's, on one
  build, with the elements named; other roles, other panels, other builds and
  other frameworks' own dialogs are unqualified.
- Whether the AX caret makes the name field the panel's first responder, so
  that a following `/` key still opens Go to Folder, is not measured.
- AXCancel closing the service's menu was measured once, on Resolve. A menu it
  does not close is reported `contextMenuLeftOpen`, the loudest failure, since
  neither a host preparation cycle nor an Escape to the host is known to close
  the service's menu.
- A right click's AXShowMenu opens a menu nothing in the seat follows either,
  as a popup's press would; it is kept as specified and not measured.
- The closure expectation of `UserFocusRecovery` is still armed for every
  Command on a modal surface, including actions that cannot close it.
