# The window reader reads and returns, and writes one switch

`TargetReader` reads another application's window through accessibility and
answers with value types: a window identity, a geometry and the accessibility
hierarchy flattened into `[AXElementNode]`. It takes no action on the target, no
Facility imports it, and nothing in it is a fallback for a Facility that refused.
The caller decides what the reading means.

**One write is allowed**, and it is the only one in the package besides the
placement of ADR 0004: `AXManualAccessibility` on the application element.

## Context

Chromium based applications, Electron and CEF included, build their
accessibility tree only when a client asks for it explicitly. Without that
switch an Electron target exposes a handful of elements and no text at all, so
the switch is the **precondition of reading the tree**, not an action on the
target: it presses nothing, moves nothing, and changes nothing the person can
see. Refusing it would not make the kit more read-only, it would make the reader
useless against the whole family of targets the consumer cares about (user's
decision, 09/09/2026).

Electron's switch is written in `WindowReader.enableManualAccessibility`.
Its asynchronous tree is polled for node growth with a three-second ceiling;
there is no per-process cache.

### Chrome and Chromium browsers, verified 10 September 2026

Chrome 153.0.8010.36 does not implement AXManualAccessibility: the write returns
attributeUnsupported (-25205). The probe page's ordinary HTML Stampa button was
missing because only 37 toolbar/window nodes were exposed, with no AXWebArea.

For the explicitly identified Chrome and Chromium browser bundle IDs, the
reader first reads AXRole on the application and then reads each descendant's
role individually before its children. Chromium uses these reads to enable
native and web accessibility on demand. A bulk attribute read alone did not
expose the web subtree in the measured case.

Tabbed windows missing AXWebArea are polled for at most four seconds. Timeout
is an explicit `webAccessibilityNotReady` error, not a complete-looking toolbar
snapshot. Native Chrome dialogs without tabs remain readable. The traversal
tracks visited elements and reports its bound rather than mistaking a truncated
walk for a native dialog. No PID cache or AXEnhancedUserInterface write is added.

Verification on a fresh background Chrome profile: the production reader found
AXWebArea and an enabled AXButton named Stampa; AXEnhancedUserInterface read
false before and after. An enhanced-switch experiment was explored separately
in an owned diagnostic process and discarded; it is not part of the kit.

Sources:
- https://github.com/chromium/chromium/blob/main/chrome/browser/chrome_browser_application_mac.mm
- https://github.com/chromium/chromium/blob/main/content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm

## What left the reader, and why

- **Category and the list of actions.** Deriving "this is a slider you can drag"
  from `AXSlider` is interpretation. The reader reports the role; the caller
  derives what it accepts and which nodes are candidates.
- **The candidate list itself**, for the same reason: "actionable" is a verdict.
  The reading is the tree.
- **Menu semantics** (which control a renderer's menu covers, whether a popup is
  open). Evidence, read off the tree by whoever plans on it.
- **`AXFocusSentinel`.** Phase 7 took accessibility focus out of `SeatObserver`,
  so the kit had no consumer for it. It is a diagnostic oracle and it lives with
  the consumer's test application.

## Consequence

No returned type holds an `AXUIElement`, an `AXObserver` or an `AXValue`, so a
caller can keep a whole reading for as long as it likes without keeping the
target's accessibility objects alive. `ObservedWindowTests` walks every
field with `Mirror` and fails if one ever does.
