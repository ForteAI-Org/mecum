# ADR 0018: Native composition owns a bounded preparation

Qt 6.11.2 on macOS 27.0.1 (26A434) drops a routed dead key while its native
input context has no focus object. Applying AppKit preparation creates marked
text, but restoring after that first Command closes the context and commits
an isolated accent. Recipient-only key-window priming does not create preedit.
The target's `QInputMethodEvent` history distinguishes these effects from
injected Unicode text and from an ordinary Qt key callback.

`AgentSeat.withNativeTextInput(observation:turn:within:operation:)` permits an
explicit qualified composition on an attested non-modal surface of the selected
window. The scope holds one Turn. Entry consumes its observation because
preparation changes native focus. The consumer must observe, decide, send and
confirm separately for each physical key. Returning the Turn during the scope
is refused. Switching the selected target cannot redirect a composing key.
`AgentSeat.sendSequence` remains unavailable.

`InputDriver` owns preparation and the process-wide input exclusion for this
scope. A task-local, unconstructible identity associates its descendant sends
with the prepared window and Turn correlation. Identity, deadline, key hold,
command gate and final Seat admission are checked before each post. Only
unheld physical key presses with empty Unicode payload and no Command or
Control modifier are accepted. Pointer Commands, held-key Commands, bulk text,
other platform recipes, sequences and preparation cycles are refused. Other
senders aimed at that PID wait for the exclusion to be released.

The scope has a finite deadline of at most five seconds, including the measured
300 ms preparation settle. Its timer restores even while the consumer is
waiting. Task cancellation, body failure, window return and host teardown also
close it. Restoration and exclusion release are idempotent. A command admitted
after closure is refused before posting. A fresh ownership chain is required
before the restore record; an unavailable or changed chain reports failed
cleanup without addressing a potentially recycled target. The Seat degrades
on failed cleanup. The callback can unwind later, but it retains no input
authority or process exclusion after closure.

Individual Receipts describe their own Commands. Their preparation is `none`
because preparation and its cleanup belong to the enclosing scope, whose
result is `InputCleanupResult`. A `NativeTextInputFailure` preserves body
failure and cleanup independently. Receipts already returned remain posted
and retain their ordinary confirmation obligations. Scope failure grants no
replay or document rollback. On the measured Qt dead-key source, restoration
commits remaining marked text as an isolated accent; cancellation does not
promise to discard it.

Six controlled Seat regressions verify fresh observations, unsupported
Commands, Turn ownership, different recipients, consumer failure, failed
cleanup and exclusion of unqualified application families. Three native Qt
rows verify actual preedit and exact `é` commit, deadline closure with a refused
late key, and cancellation while marked text exists. Each observes Qt's final
inactive state, returns its owned window, and verifies zero physical input and
preserved User Seat. Exact commands and remaining IME limits are in
[Qt.md](../platforms/Qt.md). Candidate-window IMEs and other application families require
separate qualification before this scope is offered to them.

Chrome 154.0.8037.58 reproduced an ordinary dead key without native preedit.
The same scope then produced real browser composition events and exact `é`.
Chrome is the second independently observed consumer. Its qualified own-window
endpoint may be `windowlessContentOfSurface`, whose complete ancestry binds
the focused page content to that same window. Other endpoint relations remain
refused. `ChromiumPlatform` defaults native composition qualification to false;
the app enables it only with renderer evidence and the qualified Chrome bundle
identifier. Reusing that platform for Electron or CEF does not enable the scope.
The admission regressions exercise both positive consumers and refuse ordinary
Chromium policy without qualification. Native Chrome deadline and cancellation
rows preserve the same cleanup and late-command contracts, including the
isolated-accent effect of closing marked text. See [Chromium.md](../platforms/Chromium.md).

The Seat also binds its callback to a task-local scope identity. Detached work
has no admission, and an inherited child that outlives the callback retains a
closed identity rather than falling back to ordinary posting. An offline
regression reproduced both escaped sends before the guard was added; both now
refuse before delivery. The InputDriver independently refuses an unscoped send
using the active scope's PID and correlation ID, rather than queueing it until
the context expires.
