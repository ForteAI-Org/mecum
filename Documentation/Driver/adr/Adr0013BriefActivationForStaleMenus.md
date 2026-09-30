# Bring a stale application in front for its menus

Accepted on 2026-09-30 at the owner's request. It is the measured reason ADR 0012
asked any future proposal to bring, for one case only: an Adobe UXP application
whose menu bar reads disabled because it was driven in the background.

## What was measured

Photoshop 27.10, driven only by the seat since it was launched, read its whole
File and Layer menus disabled with a document open. A press on a disabled item did
nothing, and neither did the key-window records. Brought in front by the person,
it re-enabled them, and they stayed enabled once it was behind again.

The first answer lived in the broker: activate the application, hold 150 ms, give
the front back. It failed live because the seat did not know the activation was
intended. Its own recovery read it as the person's focus being taken, closed the
gate, moved the seat to `waiting` with `targetActivated`, and restored the
person's window after 19 ms: Photoshop was in front for 10 to 24 ms. The second
attempt in the same episode found the one automatic request spent, the seat sat in
`waiting` for about 1.2 s, and only because of that the next call found the menu
enabled. Several attempts returned nothing at all, because a guard on the
application's focused window, which lags in Photoshop, failed without a word.

Then one run with the application left in front: File > Save As... read disabled
at 5 ms, every accessibility read of the menu bar answered `cannotComplete` from
61 to 961 ms while it recomputed, and the item read enabled at 1050 ms. A fixed
150 ms hold could never have worked, even uncut.

## The decision

The activation belongs to the seat, as `AgentSeat.bringTargetBrieflyInFront`,
because only the seat can tell its own activation from a steal.

- **Expected, not stolen.** The recovery is told to expect that one process until
  a deadline. Its activation closes no gate, reports nothing, opens no episode and
  spends no request. Another application activating meanwhile is the person's
  choice as always. Past the expectation, nothing is different.
- **The seat's window, the recovery's restorer.** The front goes to the window the
  seat holds, never the application's focused window, through the same
  `_SLPSSetFrontProcessWithOptions` path, participant resolved first, that gives
  the person's focus back.
- **Poll for the answer, bounded.** The item is read every 20 ms with a 0.1 s
  messaging timeout; an unreadable menu bar is "not yet". The moment ends as soon
  as the item reads enabled, and at two seconds in any case: the run above with
  room, not a qualified budget.
- **The handback is verified.** The front goes back only while the target still
  holds it; the person's window must read focused twice within 250 ms. A handback
  that is not verified goes to the ordinary recovery, which pauses and waits for
  the person. It is never reported as a success.
- **Every refusal has a name.** No recovery, a seat that is not ready, no window
  of the person's in front, a target that cannot be prepared: each is logged and
  returned, and the worker's refusal says which.

## Scope

Only applications `TargetPlatform` reads as `.adobeUXP`, only for a menu bar item
that reads disabled, once per menu request. Everything else keeps the rule that
the seat never brings an application to the front. A dialog of the application
open in the seat, by the seat's own modal state and while its window is live, is
refused before any request: that is the application's own reason for a disabled
item, and with Photoshop's "Save changes?" alert up two seconds in front changed
nothing.

## What this does not authorize

Not the clipboard, not a paste, not a key equivalent and not input delivery: ADR
0012 measured those and stands unchanged. Not a general way to raise a target for
another platform or another symptom. A new use needs its own measurement and its
own record.
