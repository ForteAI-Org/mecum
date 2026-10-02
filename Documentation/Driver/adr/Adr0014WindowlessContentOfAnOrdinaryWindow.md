# An ordinary window takes the events of its windowless content

Accepted on 2026-10-02 at the owner's request. It adds one route to endpoint
discovery, for a surface with no attested modal relation only.

## What was measured

Driving Safari through a seat, a click on the toolbar worked and nothing inside a
page did: every click and key on page content was refused with
`subtreeUnreadable`. A read-only probe of a person's Safari on macOS 27
(`_AXUIElementGetWindow`, `AXUIElementGetPid`) found:

- the `AXWindow`, the `AXToolbar` and its buttons answer the window's Window ID,
  with Safari's PID;
- the `AXWebArea` and every node under it (`AXLink`, `AXStaticText`, `AXGroup`,
  `AXImage`, `AXList` and the rest) answer `-25201`, no Window ID, and still
  Safari's own PID.

A second reading through the shipping adapter, on 27.0.1 (26A434) with Safari
27.0.1, walked from the node the hit test answered in the visible page:
`AXImage`, `AXGroup`, `AXWebArea`, `AXScrollArea` and `AXGroup` answered
`-25201`, all with Safari's PID, and the next `AXGroup` answered the window.
At that point `pointerEndpoint` refused with `subtreeUnreadable` and this route
answered the window itself.

The pointer descent therefore ends on a node with no Window ID and no remote
content window to name, and the keyboard discovery finds a focused control with
no window, or none at all, while `ordinaryKeyboardContext` meets the same
windowless nodes in its scan. Both refuse, as they were written to.

## The decision

`DialogEndpointResolver.windowlessContentEndpoint` answers the surface itself,
with evidence `windowlessContentOfSurface` and relation `logicalSurface`, when a
node of the surface's process with no Window ID has the surface as its nearest
ancestor naming a window. The recipe is the application's own, as for any
endpoint on its own window.

- **A click** is proved along the path its point names: from the node the hit
  test answered up through `AXParent` to the first node naming a window, and
  down by the smallest containing child to the innermost node under the point.
- **A key** is proved from the focused control up through `AXParent`. That
  control must answer no Window ID itself.
- **Every node on the path** belongs to the surface's process and names no window
  or the surface. A node naming another window, even one of the same process, a
  node of another process, a failed read, more than 64 steps or 300 ms refuse.
  `_AXUIElementGetWindow` is read with its outcomes kept apart: no window is a
  success with zero or `-25201`; any other error, or the symbol missing, is a
  failed read. `-25201` is also what a destroyed element answers, and the parent
  or children read that follows one fails and refuses.
- **Only after a refusal.** `AgentSeat.inputEndpoint` asks for it only when the
  surface has no attested modal relation and the discovery, with the ordinary
  keyboard route for keys, refused with `subtreeUnreadable`. A surface whose host
  is another window is never answered. Every modal path behaves as before.
- **Keys are proved twice.** At the boundary the same proof is taken again,
  because the focused control names no window and the plain focus reading would
  answer nil. A focus that left the page's content retires the context.

## Why remote panel content stays refused

Remote panel content draws inside a modal: Slack's open panel, DaVinci Resolve's
Go to Folder sheet and Photoshop's Save As panel were all reached through a sheet
or an application-modal panel the seat attests, and this route is never asked
there. On the path itself, Slack's panel controls named the panel service's
Window ID, which refuses.

The path proof alone would not refuse every shape. On Resolve's sheet the text
field answered no Window ID and the list beside it named the remote window: a
sibling is not on the path. For a surface like that the protection is the modal
attestation, not this proof. A standalone panel proxy whose modal relation the
seat failed to attest remains the residual risk.

## What stays unproven

- That Safari's page acts on the seat's background events once they are routed
  to its window. The route decides the recipient, never the effect, and no live
  run has posted through it yet.
- Keys on a page whose application reports no focused control. The shipping
  reading above answered `-25212` (no value) for `AXFocusedUIElement`: with no
  focused control this route refuses, and so does `ordinaryKeyboardContext`,
  whose scan meets the windowless web nodes.
- Any other application or browser engine, and any other build.
