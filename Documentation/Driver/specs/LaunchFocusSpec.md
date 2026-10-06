# Launch focus: an application the agent opens does not keep the person's focus

Status: **draft for review**, September 29, 2026. Ticket T5 of the seat batch
of that day (T1 to T4, T6 and T7 are the other tickets). Nothing here is
implemented. It amends `adr/Adr0010BoundUserFocusRecovery.md`; the new section
is drafted in section 7 and is not part of the ADR until this specification is
approved.

References that constrain the design: `CONTEXT.md` for vocabulary, ADR 0010 for
the focus recovery contract, its budgets and the closure transition this design
reuses, and `measurements/` for the format of the evidence a live row records.

## 0. Starting evidence

**The run.** On September 29 at 09:38 a worker opened Google Chrome, which was
not running. `SeatBroker.launch` started it with `activates = false`, the seat
adopted window 69641 at 09:38:49, and the first Command two seconds later was
refused with `targetActivated`: Chrome was frontmost. The seat went to
`waiting`, the state with no deadline, and stayed there. At adoption the log had
already said `no focus restoration is armed: no window of the person's own is
known to go back to`. No `user focus recovery:` line was ever written, so no
restoration was attempted. While Chrome was frontmost, the person's keyboard
went to a window on the virtual display that they could not see.

**The probe.** A standalone program repeated the broker's call exactly
(`NSWorkspace.openApplication`, `activates = false`), with Chrome not running
and another application frontmost, and sampled the front application every
10 ms. One run:

| t (ms) | Event |
|---:|---|
| 0 | front: the person's application |
| 3855 | `openApplication` returned Chrome's pid |
| 4495 | `didActivateApplication`: Chrome |
| 4525 | front: Chrome |
| 4939 | Chrome's first adoptable window on screen (1200 × 828) |
| 12015 | end of the run: Chrome still frontmost, still active |

Chrome activates itself 640 ms after the launch returns and about 440 ms before
it has a window. It does not give the front back on its own.

**Why the kit has nothing to answer with.** Four facts combine:

1. The host and the seat are created inside `SeatDriver.adopt`, after
   `SeatBroker.launch` returned. When Chrome steals the front, no seat exists,
   so no focus watch is installed and nothing observes the activation.
2. Once the seat exists, `UserFocusRecovery.rememberUserWindow` records nothing
   while an adopted process is frontmost, and Chrome is frontmost by then. The
   destination stays nil.
3. `refreshFocusPreparation` skips a seat that holds no window, and by the time
   the seat holds one, the only activation has already happened. No activation
   of an adopted process arrives afterwards, so no episode ever opens.
4. ADR 0010 says so explicitly: the recovery "does not prevent the initial focus
   transfer", and "an activation first observed only after a hold ends is not
   automatically reversed". A launch was never an episode.

T1 fixed the terminal failure that followed: releasing the window no longer fails
the seat. The steal itself is untouched, and so is the seat waiting forever.

## 1. What "does not steal the focus" means

macOS lets an application that is starting take the front, and Chrome takes it
whatever the launch options say. The kit cannot forbid that. What it can
guarantee, and what the tests of section 4 measure, is this:

- **F1. The focus comes back.** After an open that launched an application, the
  person's frontmost application and focused window are the ones they had
  before the open: the same process and the same Window ID.
- **F2. The interruption is bounded.** For each steal, the time from the launched
  application becoming frontmost to the person's application being frontmost
  again is at most **300 ms**. That covers the activation notification, one
  restore call (8 ms in ADR 0010) and the verification window (250 ms). This is a
  budget to be qualified, exactly like the rows of the ADR 0010 table, and not a
  measurement.
- **F3. No fight.** At most **two** automatic restorations per launch, the same
  budget as a closure transition and for the same reason: an application may take
  the front a second time when its first window appears. A third steal is not
  answered. The episode ends `unrecoverable`.
- **F4. The seat works afterwards.** The seat ends `ready` with the launched
  window adopted on the virtual display. The recovery posts no pointer or
  keyboard event and does not move the cursor.
- **F5. The person's choice wins.** If the person switches to another application
  or window during the launch, that becomes the destination, and nothing sends
  them back to the one they had before.
- **F6. A failure is said, never silent.** When the focus cannot be given back,
  the seat waits and the agent is told why, in the `waiting` sentence of
  `SeatAdmission`. The release that follows ends the wait (T1), and it also ends a
  recovery that is paused (section 3.4).

Non-goals:

- Keystrokes the person typed during the interruption are not recovered. They
  went to the launched application, as with every episode in ADR 0010.
- Applications the person opens themselves are out of scope.
- So is the focus while the agent works inside the seat; that is ADR 0010's
  existing contract.

## 2. Approaches

**A. A launch is an episode with evidence of its own (recommended).** It follows
the same pattern as the closure transition of ADR 0010: the person's window is
taken before the act that steals the focus, and nothing learned afterwards
replaces it.

- The seat exists before the launch and opens the episode.
- The launched application's processes are the steal actors, so their activation
  is never read as the person's choice.
- A steal is answered with the restorer the kit already qualified, which is the
  exact `_SLPSSetFrontProcessWithOptions` path, gated by the Facility.

It is general: every application that activates itself on launch is covered,
and none has to be known in advance.

**B. Prevent the steal with launch options.** `OpenConfiguration.hides = true`,
or launching without a startup window, might keep Chrome from activating. This
is unmeasured, and it would be per application: a remedy for Chrome says
nothing about the next application. It becomes spike S0 (section 5). If a
variant prevents the steal without costing the adoption, it is applied on top of
A, and A stays the safety net.

**C. The broker activates the previous application again**, through
`NSRunningApplication.activate`. Rejected for three reasons:

- Under macOS cooperative activation, an application that is not active cannot
  make another one active reliably, and nobody has measured it here.
- It has no attested destination: whatever is found afterwards would be the
  "destination discovered after the steal" that ADR 0010 forbids.
- It would bypass the Facility gate and the verification that ADR 0010 requires.

## 3. Design (approach A)

### 3.1 The seat exists before the launch

`AgentSession.open(applicationNamed:)` now does, in this order:

1. resolve the name, as today;
2. `driver.beginLaunch(bundleIdentifier:)`: brings the host and the seat up
   (`liveSeat`, which includes the replacement of a failed seat), then opens the
   launch episode on the seat. Bringing the virtual display up earlier moves its
   cost of about 380 ms; it does not add it;
3. `environment.launch(wanted)`, as today;
4. `use(window, of:)`, as today;
5. `driver.endLaunch()`, on **every** exit path: success, `noWindowShown`, a
   title that names no window, `notSeated`, and cancellation. An episode left
   open is an armed restoration nobody asked for.

The same applies when `launch` sends a reopen to a running application that has
no window, because a reopen can activate too. An application already running
with a window gets no episode, since nothing was launched.

### 3.2 The launch episode

The episode lives in `UserFocusRecovery`, beside `ClosureTransition`, as a
`LaunchTransition`. It is opened through a package entry point on `AgentSeat`
and never by a consumer's arbitrary choice of window.

**Evidence, taken when it opens.** Everything here is read before
`openApplication` is called, and none of it is learned again later:

- the person's focused window, read the ordinary way (`focusedUserWindow`,
  `validDestination`) while their application is still frontmost;
- its attested identity and retained PSN (`prepareDestination`);
- the preparation generation;
- a monotonic deadline.

If there is no valid destination at that moment, the episode opens unarmed and
says why, once, in the existing `no focus restoration is armed:` line. The
launch still proceeds.

**Steal actors.** The launched application's pid is unknown until
`openApplication` returns, and an application may activate before that returns.
So the actors are named by **bundle identifier**, resolved from the activating
pid (`NSRunningApplication(processIdentifier:).bundleIdentifier`) when an
activation arrives. The pid joins them once it is known. As with a closure's
remote service, belonging to that set attributes nothing and adopts nothing: it
only decides whose activation it was.

**Classification of an activation while the episode is open:**

- By a steal actor: this is the steal. The input gate closes, and one
  restoration to the saved destination is requested (3.3).
- By the destination's own process, or by another application the person
  chose: this is the person. The destination becomes their current window, read
  the ordinary way (F5). The episode is not spent.
- Unclassifiable: the destination and the gate stay as they are, as in a closure
  transition.

**The request.** It uses the closure transition's reconciliation unchanged in
kind:

- The saved destination is renewed: the same Window ID must still carry the same
  identity, and its retained PSN is re-bound.
- The window server snapshot is read again for the adopted processes plus the
  steal actors plus the destination.
- Then one request is made through the restorer.

A destination that is no longer the window it was answers nothing, and the seat
waits for a real choice. Verification is ADR 0010's: two agreeing readings of
the exact destination, within 250 ms.

**Budget and end.** At most two requests per episode (F3). A third steal is
refused, and the report says `unrecoverable`, naming the elapsed time, the
requests made and the last refusal. The episode ends at `endLaunch`, and its
deadline is only a backstop:

- A long launch is not a reason to keep an automatic request armed forever.
- The deadline is the launch's own allowance (the 20 s first-window wait, or the
  60 s start allowance once a window exists) plus the adoption's 2 s.
- After the deadline, a steal is not answered, the seat waits (F6), and the
  report says that the deadline passed.

### 3.3 The containment precondition

ADR 0010 requires every visible window of an adopted application to be on the
virtual display before a restoration, with one exception: during delivery,
staging and automatic containment, a restoration may be requested while windows
surely attributed to the application are still to be transferred. **A launch is
the beginning of a delivery**, and it uses that exception unchanged.

At the steal, the launched application usually has no window at all; Chrome's
appears about 440 ms later. When it has one, that window is on the physical
display and is the window about to be adopted. The evidence scope of the snapshot
is the adopted processes, the steal actors and the destination, so the launched
application's rows are attested rather than guessed. Full containment is still
required before any input, exactly as today.

### 3.4 The seat's state, the gate and the release

- During the episode the seat has no Turn and no Command in flight.
- A steal closes the gate with the existing `.focusRecovery` cause. During the
  restoration the seat is `waiting`, as in every episode: `focusRecoveryChanged`
  moves it there on `restoring` and back on `restored`. It stays `waiting` only
  when the restoration fails or the budget is spent.
- **The paused recovery must end when its application is given back.** Today a
  recovery that stays paused with no destination keeps the gate closed and the
  seat in `waiting` after the release of every window, and nothing can end it:
  `verify` ends it only on the person's verified focus, and `stop` is terminal.
  T1 left this open on purpose. A launch episode that ends `unrecoverable`
  reaches it every time. `UserFocusRecovery` therefore gets one method that ends
  a pause whose adopted set became empty:
  - it invalidates the timer;
  - it resumes the `.focusRecovery` cause;
  - it emits `cancelled`, so the seat leaves `waiting` through
    `focusRecoveryChanged`.

  It is called from `AgentSeat.forgetRecord` when the last window of the
  application goes.

### 3.5 Reports and log lines

- `UserFocusRecoveryReport` gains the episode kind (`launch`, beside the Turn,
  the operation and the closure).
- Its timing gains three timestamps: the activation of the steal actor as
  received, the request, and the first verified reading. The line the seat
  already writes for every report carries them.
- Opening and ending the episode write one line each. The steal line names the
  bundle identifier that stole.

### 3.6 What does not change

- The restorer, its Facility gate and its 8 ms budget.
- The Turn and closure episodes and their budgets.
- The rule that no Command is replayed.
- The rule that the kit never activates the target itself.

## 4. How it is tested

The request that produced this document was to be able to **test that the focus
is not actually kept by the launched application**. The live row of 4.3 is that
test. The unit tier pins the rules, so a regression is caught without a display.

### 4.0 Red first

The live row of 4.3 is written and run **before** any product change (ticket
T5.0). On the current code it must fail F1: the probe of section 0 predicts
Chrome frontmost at the end of the trial. A row that passes on the current code
measures nothing and is fixed before anything else.

### 4.1 Unit tier (offline, `SeatSessionTests`)

These tests use the existing fakes (`FakeSensing` and the recovery's scripted
restorer), next to `ClosureTransitionTests`.

- **U1.** An activation by a steal actor during the episode is not recorded as the
  person's destination.
- **U2.** That activation requests exactly one restoration, to the pre-launch
  destination, with the gate closed before the request.
- **U3.** A second steal after a verified return is answered once more, and a
  third is refused as `unrecoverable`. The gate stays closed and the seat goes to
  `waiting`.
- **U4.** The person activating another application during the launch replaces
  the destination, and nothing is ever requested towards the old one.
- **U5.** A destination that is gone, or replaced under the same Window ID, before
  the steal refuses the request, and the seat waits.
- **U6.** A launch with no steal requests nothing, and `endLaunch` leaves the seat
  `ready`.
- **U7.** A steal after the deadline is not answered.
- **U8.** A paused recovery whose application is released ends as `cancelled`, the
  gate opens and the seat leaves `waiting`. This is the T1 leftover.
- **U9.** An activation that arrives before the pid is known is classified by
  bundle identifier.

### 4.2 Broker tier (offline, `SeatBrokerTests`)

- **B1.** `endLaunch` runs on every exit path of `open`.
- **B2.** `beginLaunch` precedes the launch.

If `AgentSession` offers no seam to observe the order without a display, the
missing seam is recorded as a finding, not papered over with an injection layer.
The live row then covers the order.

### 4.3 The live row: `LaunchFocusLiveTests`

**Gating.** `AGENTSEAT_LIVE_TESTS=1`, named so that `make live-tests` does not
count it. The independent sampler runs when `AGENTSEAT_FOCUS_SAMPLER` points at
`Tools/Driver/Scripts/FocusLatencyProbe` built with the research admission; its
`research-26A428` profile covers this Mac (Mac16,1, macOS 27.0 build 26A428).

**Preconditions, or the row is skipped:**
- Chrome is not running;
- no other process holds a seat display (the kit's display identity is shared
  across processes);
- the focus Facility is admitted (`focusRecoveryReadiness`).

**The person's window** is whatever application and window are frontmost when
the row starts, captured with `UserSeatState.capture()` and `FocusAXObservation`
as in `UserFocusRecoveryLiveTests`. The row itself opens no window that could
become key, because a test window takes the real keys of whoever is at the Mac.

**The open.** A broker session from the queue calls `open(applicationNamed:
"Google Chrome")` through the real launch path. It passes a temporary profile
(`--user-data-dir`) in the launch arguments, so the person's tabs and history are
neither opened nor read. The row quits only the Chrome it started.

**Assertions:**
- **L1 (F1).** At the end, the frontmost pid and the AX focused window are the
  person's, and they stay so over four readings 50 ms apart.
- **L2 (F2).** From the sampler's timeline: every interval with Chrome frontmost
  is at most 300 ms, and the row prints each interval. Without the sampler, the
  same is read from a public-API sampler process (activation notifications plus
  `frontmostApplication` every 5 ms), labelled lower fidelity in the record.
- **L3 (F3).** `lastFocusRecovery` is `restored`, with request code 0, at most two
  requests and the activating bundle `com.google.Chrome`.
- **L4 (F4).** The seat is `ready`, and Chrome's window is adopted inside the
  virtual display.
- **L5 (F4).** The fence counted no physical event during the trial, and the
  cursor did not move. Physical activity makes the row **inconclusive**, not
  passed, as in the existing focus row.
- **L6.** Cleanup: the session closes, the Chrome it launched quits, the profile
  directory is removed and the display goes down. The ledger of `TrialResources`
  names everything the row created.

**Repetition.** Ten cold launches in one run, with the distribution of L2
reported (minimum, median, maximum) and every trial's verdict listed. One
passing trial is not a qualification.

### 4.4 Controls

- **TextEdit, not running.** No self-activation is expected, so zero requests are
  expected. A request here is a false steal.
- **Chrome running with no window** (the reopen path of 3.1). The same
  assertions as the Chrome launch.

### 4.5 Manual check in Mecum

With Mecum built with the change, type in another application while a worker is
asked to open Chrome. The person's application must come back to the front by
itself, the worker must go on without a `waiting` sentence, and the run's line
must show one `launch` episode, `restored`.

### 4.6 The record

Each live run writes a `LaunchFocus<yyyymmdd>.json` beside the existing focus
measurements: build, trials, intervals, requests, verdicts and the sampler's
admission. Evidence goes into the ledger, never into a code constant.

## 5. Spike S0: can the steal be prevented

This is the throwaway probe of section 0, run once per variant, with Chrome not
running and the person's application frontmost:

- **S0a** `activates = false`: the baseline, already measured. Chrome takes the
  front.
- **S0b** `activates = false`, `hides = true`: is Chrome still frontmost at any
  sample? Does its window appear, and can it be unhidden without activation
  (`NSRunningApplication.unhide`)?

**Decision rule.** If S0b never shows Chrome frontmost, and its window can be
shown and adopted without activating it, the broker launches hidden and unhides
before adopting, with A kept as the net for every other application. Otherwise S0
is closed as "not preventable by launch options", and only A ships. The probe
code is not kept.

## 6. Tickets

**T5.0: spike S0 and the red live row.** No product change.
- The `LaunchFocusLiveTests` row of 4.3, run on the current code, fails L1.
- S0 is decided by its rule.

**T5.1: the launch episode in the kit.**
- `LaunchTransition` in `UserFocusRecovery`.
- `AgentSeat` entry points and report fields.
- The pause that ends on release (3.4).
- U1 to U9.

**T5.2: the broker.**
- The order of 3.1 and `endLaunch` on every exit path.
- B1 and B2, or the missing seam recorded.
- If S0b passed, the hidden launch.

**T5.3: qualification.**
- The live row goes green over ten trials with the sampler, and the record of 4.6
  is written.
- The ADR 0010 section of 7 is finalised with the measured numbers.
- The manual check of 4.5 is done.

## 7. ADR 0010 amendment (draft)

> ## A launch is an episode with evidence of its own (2026-09-29)
>
> An application the agent launches can take the front by itself, before it has
> a window and before the seat has adopted anything: Chrome did, 640 ms after
> `openApplication` returned with `activates = false`, and kept it. The seat
> had no episode for it. The seat did not exist yet, it never learned the person's
> window, and no later activation opened an episode, so the person's keyboard
> stayed in a window they could not see.
>
> A launch now opens an episode before the launch is requested. The episode
> holds the person's focused window, its attested identity and retained serial
> number, the preparation generation and one monotonic deadline, all taken before
> anything is started. Its steal actors are named by bundle identifier, since
> the application can activate before its pid is returned. An activation by one
> of them is the steal and closes the gate. An activation by any other process
> is the person, whose current window becomes the destination.
>
> The request reuses the closure transition's reconciliation and nothing else:
> the destination is renewed, never re-derived, and the snapshot is re-read for
> the adopted processes, the steal actors and the destination. A launch is the
> beginning of a delivery, so the containment exception applies unchanged.
>
> The budget is two requests per launch, qualified like every other row. A third
> steal is `unrecoverable`, and the seat waits and says so. A recovery that stays
> paused after every window of its application was released ends as
> `cancelled`, because there is nothing left for it to protect.
>
> Measured: to be written by T5.3.

## 8. Open decisions for review

1. **Interruption budget, F2.** 300 ms per steal. A tighter value means that
   detection latency, which is the notification path, not the restore call, has
   to be measured first.
2. **Requests per launch, F3.** Two, as a closure. One would leave Chrome's likely
   second activation, at window time, unanswered.
3. **The reopen path.** Should a reopen of a running application also open an
   episode (proposed: yes, 3.1)?
4. **If S0b prevents the steal:** hide at launch for every application, or only for
   Chromium browsers (proposed: every launch; a hidden launch that cannot be
   unhidden without activating falls back to A)?
