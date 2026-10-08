# ADR 0035: Settle on the running window stream, and keep the observation between gestures

Status: part 1 implemented, 2026-10-07; part 2 decided against changing; part 3 (the baseline taken
before the input) implemented, 2026-10-08. Offline tests only for part 3; no live run. It builds on
[ADR 0034](Adr0034ObserveFromTheRunningWindowStream.md).

## Evidence

Measured on 7 October 2026 (ADR 0034, Calculator, TextEdit, Chrome, 20 inputs each): a
`press_key` cost about 700 ms, of which the act cycle's fixed `pause` (`ActionTiming.clickSettle`,
300 ms, plus its own overhead, about 310 ms) was the largest part. On the preview's running
30 fps stream the first frame after an input came 17 to 34 ms after delivery and the first frame
with changed pixels about 31 ms after it, p95 40 to 51 ms. `ActionTiming` had rejected an
adaptive wait because proving a window stopped changing cost two captures; on the running stream
the frames arrive anyway.

## Part 1: the wait after a gesture ends when the window settles

### The seam

`EngineCore` declares `Settling`: `settle(in:cap:) async`, which never throws and sends nothing.
`ActionEngine.Dependencies.settling` is optional. With it, the waits after a click, a toggle, a
typed or inserted text and every input judged by two scenes call the role with
`ActionTiming.clickSettle` as the cap; without it they sleep the click settle exactly as before.
The wait after the right click of a contextual menu keeps the fixed pause: the menu is a window of
its own, which the target's frames never show. `MenuBarCommand` takes the same optional role with
`pressSettle` (400 ms) as the cap, and sleeps 400 ms without one. The Engine imports neither the
Driver nor the Broker.

`SeatDriving.SeatSettler` fills the role. It reads the window stream the Broker's preview already
runs, which `SeatTarget` now borrows with the seat (`SeatTarget(borrowing:seat:liveFrames:)`,
passed by `SeatDriver.borrowedTarget`). `EngineRuntime` gives every seat runtime a settler; a
`SeatTarget` nobody streams (the command line's own host) has no source, so its settler sleeps
the cap, which is the fixed pause.

### Settled

Starting when the role is called, right after the last gesture went out, the settler asks the
source for each next frame displayed after the previous one and compares consecutive frames with
`SeatFrame.showsSameContent(as:)`, exact bytes. The constants, in `SeatSettler`:

- `stabilityInterval`, 90 ms: three frame intervals of the 30 fps stream, so a second repaint
  within two frames of the first (a highlight, then the content under it) is still waited for.
  Three intervals read off display times come to 99.99 ms, so 100 would take four.

There is no shorter wait for a window that does not change: when no frame changed, the wait lasts
the whole cap and is named `quiet`, so the measurement can still count those cases.

It answers `stable` once frames have stayed identical for the stability interval after the last
change; `cap` at the cap with frames still changing; `quiet` at the cap with none changed. A
source that declines (`notLive`, `recovering`, `pinnedToDisplay`, `otherWindow`) or any frame it
cannot place answers `fallback` after waiting out the rest of the cap: the fixed pause exactly when the source
declines at once. A resting stream is woken and its frames used (ADR 0036). No wait exceeds the cap. Part 1 took
the reference from the first frame displayed after its own start, so an effect already drawn in
it read as no change and cost the cap; part 3 corrects that.

### The contract

The scene an action returns is still taken after the action settled: the role returns before the
engine perceives again, and that perception is a new observation whose frame is displayed after
its own request (ADR 0034), so it is never older than the settle. The settle reads the same frames
observation reads, one after the other, never at once, and holds one pool surface for one frame
interval at a time. The verdict rule is unchanged.

### What it does not see

Only the target window. A menu, a sheet or a panel that opens as a window of its own after the
target window settled is not waited for, where the fixed 300 ms may have covered it; the
contextual menu path keeps the fixed pause for that reason. A menu command that opens a dialog is
the same case: its verdict is the application's window list after the observation, and a dialog
later than the settle reads as "no window opened". That risk is closed by design: a window that
does not change ends the wait at the cap, never earlier, and an action that opens a window of its
own leaves the target's pixels alone, so it waits the same 300 or 400 ms as before. Only an action
that changed the target and then left it still ends sooner. The live acceptance should still cover
one. Each frame comparison runs on the main
actor, one `memcmp` per row of a 1 to 4 MB window; its cost is not measured.

With phases on, `settle` times each wait and is named by how it ended: `settle:stable`,
`settle:stable.baseline`, `settle:quiet`, `settle:cap`, `settle:fallback.<reason>`. `PhaseInterval.end(_:)` carries that
detail and `phase-table.py` prefers it to the begin's.

## Part 2: `type_text` keeps its observation between the click and the text

A click then a text is three observations: the scene, one after the click to authorize the text,
and the scene after the text. Making the first authorize both was considered and is not done,
because the middle observation is what checks the click's consequences, not its pixels:

- Admission (`AgentSeat.admissionRefusal`) compares a reference with the seat's last folded
  reading: the selection and its generation, the sheet role, the surface's window-server
  rectangle. It does not read the application's window inventory again. Only `observe()` folds a
  fresh reading, lets the window follower settle a surface it has just seen, takes in a window
  already open, refuses on containment and the other suspension causes, stages a stashed target
  and resolves a modal's host.
- A click is the Command most likely to make a surface: a sheet, a dialog, a completion list, a
  window on the person's display. The follow pass a Command requests (`requestWindowFollow`, one
  second ahead for a Qt click) runs on its own and the next `send` does not wait for it. With the
  click's observation reused, the text would be admitted against a seat that has not looked at
  what the click did.
- An observation without a capture would have to repeat `observe()`'s whole pre-capture path in a
  second place and then issue a reference for pixels taken before the click. A
  `SeatObservationReference` binds one Frame to the situation it was taken in; that is what
  admission and the observation cutover rely on (no Command posted from one observation and one
  decision after another Command).

Focus is not the reason. The seat keeps no focus reading in an observation: a keyboard Command's
recipient is resolved from the live accessibility focus when it is sent
(`AgentSeat.inputEndpoint`), with or without the middle observation.

What the middle observation costs since ADR 0034 is one frame of the running stream, about 31 ms
median, and no stream start. `type_text` therefore stays at three observations.

## Part 3: the first frame is compared with a baseline taken before the input

### Evidence

Measured live on 7 and 8 October 2026 (final run counts of settle endings, stable / quiet):
Calculator 14 / 18, Finder 0 / 32, Chrome 8 / 24, Notes 30 / 2. An application that redraws within
a few milliseconds of the input (Calculator showing "8") has drawn its effect in the first frame
the settler sees. That frame became the reference, every later frame was identical to it, and the
wait ran to the whole cap as `quiet`.

### The rule

The reference is a frame displayed before the gesture was delivered, the baseline. The first frame
after the input that differs from it counts as a change, and the wait then ends once frames have
stayed identical for `stabilityInterval`, capped as before (`stable.baseline` in the phase table:
the change was seen against the baseline, where `stable` is one seen between later frames). If no
frame differs from the baseline before the cap, the whole cap is waited and the ending is `quiet`,
as in part 1: an effect that opens a window of its own leaves the target's pixels unchanged, and
that case keeps today's full wait. Every other rule stands: caps, fallbacks, the scene taken after
the settle, byte-exact comparison.

### The seam

`Settling` gains `prepare(in:)`, with a default that does nothing. The engine calls it right before
it delivers an input (before the click's or the toggle's gesture, and once before the first of the
gestures `send` delivers), so the baseline is the newest frame before the action began and any
effect of the whole input counts against it. `SeatSettler.prepare` asks the
running stream for its newest frame (`displayedAfter: 0`, bound 50 ms, which a stream of about
30 frames a second answers at once) and keeps a detached copy: holding the stream's own frame
across the wait would hold two pool surfaces, which the one frame contract forbids. The copy costs
one `memcpy` of the window and runs on the main actor; with phases on it is the `settle.prepare`
interval.

The alternative was the frame the pre-action scene was built from (`SeatSceneProvider` keeps it
for ADR 0034). It is not used because it is not recent: the model's turn lies between that
observation and the gesture, and any change in that time reads as the effect.

A baseline serves one wait, and is used only when it is of the window being settled, was displayed
before it was copied, and is at most `baselineLifetime` (2 s) old when the wait starts; otherwise,
and when the stream has no frame or no copy could be made, the wait is exactly part 1. That
lifetime bounds a baseline left by a gesture whose wait never came (a failed delivery, the
contextual menu path, a refused menu press). `MenuBarCommand.perform` prepares before a press that
asks no refresh. `performInFront`, and a press that refreshes, do not: activating the application
redraws it before the press, so a baseline from before would read that redraw as the effect and
end the wait before a window the press opens. Their wait is part 1's.

### Risk

A blinking caret, a clock, an animation or a page still loading can make the first frame differ
from the baseline for a reason that is not the gesture, and end the wait about 90 ms after that
frame, earlier than the effect. Part 1 had the same blind spot only after its first frame. The live
check of this part watches the menu verdicts (`pressed ...: no window opened`) for it, and the
endings per application.

## Consequences

- With the baseline (part 3) an effect drawn in the first frame is no longer a full cap: it waits
  from about 110 ms (one frame, then three identical intervals). Not measured live.
- An action on a streamed seat window that changes the window waits from about 150 ms (the
  second frame changes, then three identical intervals) to its cap, instead of always the cap; one
  that changes nothing in it waits the cap. Not measured live; the live acceptance of this work
  measures it.
- The command line, the foreground and any seat without a running stream wait exactly as before.
- `ActionTiming` values are unchanged; on the seat `clickSettle` is now a cap.
