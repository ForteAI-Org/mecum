# Keyboard, shortcuts, and text delivery

Status: **approved design**, September 14, 2026. Twelve tickets in two groups,
derived from the nine brief items. Order is mandatory within each group. The
groups do not depend on each other, but A2 and B1 touch the same file and must
not run in parallel on separate branches. This specification is authoritative:
its done criteria are the agreed criteria, not values derived from an earlier document.

| Brief item | Ticket |
|---|---|
| 1. Separate down and up, repeat, versioned table of physical, logical, and layout names | A1, A3 |
| 2. Declarative hotkeys with `OptionSet`, logical held state separate from event flags | A1, A4 |
| 3. Preserve preexisting held keys; a shortcut adds only what it owns | A4, section 3 |
| 4. Direct virtual-key path, backend choice before the first post | A1, A6 |
| 5. Private `CGEventSource` as a hypothesis, not proof; three verification conditions | A7 |
| 6. Atomic sequence; clean up only what the session owns | section 5, A4 |
| 7. Eight shortcuts on AppKit and Chromium | A7 |
| 8. Text units, Unicode boundaries, IME, chunks, recipient, commit | B1, B2, B3, B4 |
| 9. Measure and bound bulk text without promising semantic delivery | B1, B4 |

References that constrain the design: `Context.md` for vocabulary,
sections 5 and 6 of `Spec.md` for the driver and primitives, `SpiLedger.md`
for existing measurement evidence, `adr/Adr0001FailClosedPrivatePrimitives.md`, and
`adr/Adr0011ModifierPolicyLeavesNoState.md`.

## 0. Starting evidence

Two facts already in the ledger constrain the matrix before it is written.

`InputCommand.paste`, meaning Command-V, is **delivered to both families and
acted on by neither**. From inside the target, it reports `NSApp.isActive` as
true, `isKeyWindow` as true, an Edit menu with Paste installed, and
`target(forAction:)` resolving to its own `NSTextView`, yet nothing is pasted.
On Chromium, the page never sees a `paste` event. The cause is structural: a key
equivalent is not *delivered*; it is **resolved by the application menu**, which
belongs to the frontmost application, a state the kit never assumes.

Record type `0x0C`, meaning `flagsChanged`, **has never been read from a
record**. The ledger covers 0x01 through 0x04, 0x0A, 0x0B, and 0x16.
`RecordLayout.typeByte(of:)` declares the general rule, but a rule is not
verification.

These facts make the menu-resolved matrix rows expected **FAIL** results and
require the `flagsChanged` branch to begin with ledger verification, not code.

## 1. Vocabulary

`SeatCore/Input/Keys/` holds pure types; `SeatInput/Keyboard/` reads the layout.
This follows the package's existing boundary: `SeatCore` has no system
dependencies, while `UCKeyTranslate` is a system read.

The three names in item 1 are not three tables. They are three ways to refer to
a key, and the caller chooses among them:

```swift
public enum KeyReference: Sendable, Equatable {
    case physical(PhysicalKey)   // The position, identical on every layout.
    case character(Character)    // The meaning, resolved through the layout.
    case virtualKey(CGKeyCode)   // The unchanged direct path.
}
```

Option-Right Arrow is `.physical`; Command-C is `.character`, because the menu
binds the character, which occupies a different virtual key on AZERTY. The
layout participates **only** in `.character` resolution.

A `.character` names the key, not the text an event with every flag would
produce. The reader derives only four rows: base, Shift, Command, and
Command-plus-Shift. Command may select an alternate arrangement, while Option
and Control remain flags and do not transform `a` into U+0001 or `e` into a
dead accent. Resolution first searches for the character in the base or Command
row even when Shift is present, so Shift-Slash names Slash. If no base key
exists, explicit Shift may search for the symbol in its row: Question Mark with
Shift names Slash; Question Mark without Shift is refused. For an arrangement
that changes under Command, Command-plus-Shift is preferred. The ordinary Shift
row is allowed only where the key retains its base identity under Command.
Uppercase characters or symbols are never synthesized to force a resolution.

The result is a virtual key plus flags. A resolved Shortcut does not call
`keyboardSetUnicodeString`: that payload changes `charactersIgnoringModifiers`
and may prevent AppKit from recognizing the key equivalent. `InputCommand.text`
and `.insertText` remain the only paths carrying a Unicode payload.
`CharacterShortcutOrigin` retains the logical character and selected plane only
for Key Hold bookkeeping. Before event construction, the driver rechecks the
Command plane and, when required by the symbol, the Shift plane. If either
changed, it refuses before the first post. Option and Control do not invalidate
a resolution because they did not select the virtual key.

```swift
public struct Modifiers: OptionSet, Sendable, Hashable {   // UInt8
    command shift option control function capsLock
}
public enum KeyPhase: Sendable, Equatable {
    case press, down, up
    case repeated(count: Int)
}
public struct Shortcut: Sendable, Equatable {
    let key: KeyReference
    let modifiers: Modifiers
}
```

In `InputCommand.key(virtualKey:text:modifiers:phase:)`, `modifiers: Modifiers`
replaces `flags: CGEventFlags` on both `.key` and `.drag`. There is one
vocabulary, and `CGEventFlags` returns to being a construction detail. The enum
gets no new case: it remains at six, and `Shortcut` is not a Command but a
resolver that produces one. Two cases for the same action would give a call site
two opportunities to choose the path that does not work, the exact error the
ledger already records for the three drag paths.

There is no transitional type alias; call sites update in the same step.

## 2. What is versioned, and by whom

| | Versioned by | Why |
|---|---|---|
| `KeyNames.version`, virtual key to physical name | **us**, a manually bumped integer | a consumer that serializes `"ArrowRight"` in configuration must notice when the kit's table changes underneath it |
| `KeyboardLayout.generation` plus `inputSourceID` | **the system** | changes when the new read differs in identity, source bytes, or keyboard type |

`KeyboardLayout` also carries the `KeyNames.version` against which it was built,
so a read retained across a kit update exposes its staleness instead of silently
resolving.

The reader retains the latest source and translated `KeyboardLayout`. A read
with the same ID, the same `LMGetKbdType()`, the same `KeyNames.version`, and
identical bytes reuses the value without repeating `UCKeyTranslate`. Bytes are
compared exactly with unaligned SIMD loads and a bounds-checked tail, not through
a hash. If even one byte changes, the cache translates again and increments the
generation even when all four resulting rows are identical. The generation
identifies the observed source, not only its visible output. An absent or
untranslatable source clears the reusable entry and does not return the previous
layout.

A failed resolution refuses the command with
`InputFailure.keyUnresolvable(reference, layout)`. A character unavailable on
the installed layout does not become virtual key 0 with attached text, because
that is the `.text` path and has different semantics.

## 3. Logical held state and event flags

Two states that are never the same:

- **logical held state**, per PID: the modifiers *we* hold down for that process
  because an explicit `.down` pressed them and no `.up` released them. It never
  includes the person's hand; we neither read nor infer it.
- **flags applied to the event**, per event: `(held union command modifiers)`
  converted to `CGEventFlags` during construction.

`ModifierHold.shared` is keyed by PID and sits beside, not inside,
`InputTargetExclusion.shared`: an exclusion entry exists only while a lease
exists, while held state must outlive the command that pressed it. The two use
the same `Mutex` and shape but have different lifetimes.

The Turn owns the state: the registry stores `[PID: [correlationID: Modifiers]]`.

```swift
func add(_ m: Modifiers, owner: Int64, processID: Int32) -> Modifiers
func remove(_ m: Modifiers, owner: Int64, processID: Int32) -> Modifiers
func releaseAll(owner: Int64, processID: Int32) -> Modifiers
```

They return the **effective delta**, not the argument, because that delta is
exactly the set that requires `flagsChanged` transitions. The registry computes
the transitions; the builder emits them.

For a `.press` with modifiers `M` and current held state `H`:

```
added     = M minus H      the only transitions owned by the shortcut
effective = M union H      what appears on the down and up flags
```

Intended, counterintuitive consequence: **if the session already holds Shift
and the caller requests Command-C, the target sees Command-Shift-C.** This is
how a physical keyboard behaves, and the shortcut does not clear context the
caller deliberately established. It releases only Command at the end.

## 4. Platform policy

```swift
public enum ModifierPolicy: Sendable { case eventFlags, flagsChanged }
func modifierPolicy(for command: InputCommand) -> ModifierPolicy   // default .eventFlags
```

It accepts the command just as `preparation(for:)` and
`preparationSettle(for:)` already do; the protocol gains no new concept.

`InputEvents.append` gains one parameter, not four:

```swift
package struct KeyboardContext {
    let held        : Modifiers
    let policy      : ModifierPolicy
    let layout      : KeyboardLayout
    let repeatPacing: KeyRepeatPacing
}
```

A `flagsChanged` event has no public initializer. Build a keyboard event with
the modifier keycode (55 Command, 56 Shift, 58 Option, 59 Control, 57 CapsLock,
63 Fn), then rewrite it to `type = .flagsChanged`. Two rules are easy to get wrong:

1. **Flags are cumulative, not differential.** Pressing Command and then Shift
   produces `flagsChanged(Command)` followed by `flagsChanged(Command, Shift)`;
   releasing produces `flagsChanged(Command)` followed by `flagsChanged(empty)`.
2. **Order is declared.** Press in `OptionSet` bit order and release in the
   exact reverse. The target does not care, but the test does, and "reverse"
   has no meaning without a stable order.

## 5. Atomicity

The `InputEngine` posting loop has no error branches: there is no `try` or
`checkCancellation` inside it, `postToPid` returns `Void`, and `usleep` is not
interruptible. All verification happens above the loop. The last operation
before the `for` is an identity and geometry reread that may refuse. The per-PID
exclusion lease and the actor are held for the entire duration.

Modifier transitions enter the **same** `pending` list. Therefore *press added
modifiers, key down, key up, release the reverse of only the added modifiers* is
one list that either never starts or finishes. The existing architecture, not a
new mechanism, satisfies item 6.

Our code cannot close one gap: the controller process may die halfway through
the loop. The two branches are not symmetric, and that asymmetry is the subject
of ADR 0011.

Two floating states remain, both deliberate and bounded:

- A `.down` without `.up` is a floating key **requested by the caller** and
  bounded by the Turn. `release(turn)` calls `releaseAll(owner:)` and posts the
  reverse transitions. Every receipt reports it through
  `InputReceipt.heldAfter: Modifiers`. A failed release reports
  `report([.modifiersNotReleased])`, the exact counterpart of
  `.preparationNotRestored`. Releasing one Turn does not touch another Turn's
  held state for the same PID.
- A long `.repeated(count:)` holds the actor and lease for `count × interval`
  inside a non-cancellable `usleep`. The count is **declared and bounded**, and
  values above the limit are refused.

## 6. Tickets

### Group A: keyboard and shortcuts

**A1. Vocabulary and name table.**
Deliverables: `Modifiers`, `KeyPhase`, `KeyReference`, `PhysicalKey`, `Shortcut`,
`KeyNames` with `version`, and `KeyRepeatPacing` in `SeatCore`; `KeyboardLayout`
and its reader in `SeatInput`; `InputFailure.keyUnresolvable`.
Done when: `KeyNames` covers ANSI, ISO, and JIS keys with physical names;
resolving a `.character` against at least two different injected layouts
produces different virtual keys in a unit test; `KeyboardLayout` carries
`inputSourceID`, `generation`, and `tableVersion`; unit tests contain no network
or system tests.

**A2. Migrate from `CGEventFlags` to `Modifiers`.**
Deliverables: `InputCommand.key` and `.drag` accept `modifiers`; update
`InputEvents`, `InputCommand+DragPath`, `WindowCoordinateValidator`, `AgentSeat`
line 944, plus `InputEventsTests`, `ContextMenuTests`, and
`InputMatrixLiveTests`. `InputPlatformTests` passes no flags and does not change.
Done when: `swift test` is green, there is no transitional type alias, and
`CGEventFlags` no longer appears on the public surface.

**A3. Phases and repeat.** Measured on September 14, 2026; results are in `SpiLedger.md`.

**The autorepeat bit made the event undeliverable.** Across 24 rows, two
families, and three intervals, zero repeats were received. Removing the field
delivered them all. The kit therefore posts repeats as ordinary key-down events,
and `KeyPhase.repeated` makes the lost distinction explicit.

**The pause is not required for delivery**, but remains the default: with a zero
interval all 32 arrive in 782 ms instead of 1909. The measurement establishes
delivery, not how the target interprets the gap. An application that accelerates
while a key is held reads the interval, and nobody has measured that behavior.
The staggered-timestamp experiment **must not be written**: it existed to remove
a pause that can already be removed by setting the interval to zero.

**A3. Phases and repeat.**
Deliverables: feed `KeyPhase` into construction; write
`keyboardEventAutorepeat` on repeated downs; add `KeyRepeatPacing` to
`InputPlatform` beside `dragPacing`; enforce a typed refusal above the count cap.
Done when a unit test proves that `.down` produces one event and `.press` two,
that `.repeated(count: n)` produces `n` downs with the autorepeat field set to
1, and that a count above the cap is refused before construction.
Measurement: `RepeatCostLiveTests`, with one sweep answering both questions.

The probe page counts each `keydown` in `k`, so `n` repetitions must advance it
by `n + 1`: the initial down plus the repetitions. Key up is not counted. A
smaller increase means the target discarded events.

**Ask the cheap question first; it may make the other unnecessary.** The sweep
tests intervals of 0, 8000, and 33000 microseconds. If zero delivers every
repeat, the pause is dead time that buys nothing, and **the staggered-timestamp
experiment must not be written at all**. It would exist only to remove a pause
already shown to be unnecessary. Write it only if zero loses repetitions.

The cap of 32 is the highest tested count, so one run reveals whether it is
conservative, correct, or already too generous.

**A4. Per-PID held state and a mid-session layout change.**
Deliverables: `KeyHold.shared`; `InputReceipt.heldAfter`;
`InputReceipt.layoutGeneration`; `SessionFailure.keysStillHeld` on Turn release;
and `SeatIssue.keysNotReleased` for the terminal path.

**It is named `KeyHold`, not `ModifierHold`, and holds keys rather than only
modifiers**: `.down` exists for every key, and a held letter can be lost just
like Command. Modifiers are the subset whose virtual key is known and derived
on demand; that subset stamps the next Command's flags.

**Turn release refuses; it does not post.** A Turn that still holds a key cannot
be returned: `release` throws `keysStillHeld`, just as it already throws
`unconfirmedCommands`. The kit does not post missing key-up events itself for
the same reason it never replays a Command: what to release and in which order
is knowledge owned by the Turn holder, not an assumption the seat can make
safely. `SeatIssue.keysNotReleased` covers only the terminal case, when no Turn
remains to reject.

**A `.down`/`.up` pair is bound to the resolved virtual key, not the
`KeyReference`.** The person may switch from Dvorak to QWERTY between down and
up. Resolving the character again would yield a different virtual key, release
a key that was never pressed, and leave another held forever. The registry
therefore stores the virtual key. The layout is reread for every command so a
new shortcut always uses the current layout, and the receipt carries
`layoutGeneration` so a consumer comparing two receipts can observe the change.
No run-loop observer is needed; the generation compared by
`KeyboardLayoutReader` answers the same question.

Done when unit tests cover two owners on the same PID, independent PIDs, the
effective delta returned by `add` and `remove`, release of one Turn leaving
another's held state untouched, and a `.down` resolved under one layout followed
by `.up` under another that releases the **same** virtual key.

**The row that confirms or falsifies PID keying belongs to this ticket**, not
A7, and is `KeyIsolationLiveTests`. PID keying is a belief, not a measurement:
two windows of one application are one AppKit process with one notion of what is
pressed, so PID is the boundary the system actually provides. The row tests it
in two halves.

The cheap first half measures **the kit**: the event built for the second window
carries the modifier held on the first, proving that the registry works. Unit
tests already cover this.

The second half measures **the target**, which nobody has measured before. The
letter is sent as a position, not a character, so the event carries no text and
the target must derive the character from the keycode and flags. The field
contains its interpretation, not ours.

If the row falsifies the model, change the `KeyHold` key. The failure message
must state that explicitly rather than leave it to inference.

**A5. Verify record `0x0C`.**
Deliverables: `RecordLayout.verifyFlagsChangedRecord()`, which builds a
`flagsChanged` event, verifies that type reassignment held, rereads byte 0x08
through `SLEventRecordPointer`, and checks for `0x0C` with declared length
`0xF8`; its row in `SystemGateHostTests`; and an entry in the **behavior** table
of `SpiLedger.md`.

**This does not become a Facility requirement and therefore adds no build-ledger
row.** `Ledger.verdict(for:in:)` iterates `facility.requirements`. A new
`untested` requirement would invalidate the entire Input Facility on every
build nobody has yet promoted, breaking the driver merely to add a check. The
transition-posting policy therefore closes over this check's live answer, which
is more direct evidence than a ledger row and requires no human promotion act.

Done when the check passes in the host tier on the current build and
`SpiLedger.md` records the dated result. **Blocks A6.**

Result on 26A5425a, September 14, 2026: type reassignment held, the record
declared 248 bytes, and offset 0x08 contained `0x0C`.

**A6. `flagsChanged` policy.**
Deliverables: `ModifierPolicy` on `InputPlatform`; cumulative transition
construction in declared order; `InputFailure.modifierPolicyUnavailable`.
Done when `.flagsChanged` **refuses** until `verifyFlagsChangedRecord()` passes
on the current build, with no implicit fallback to `.eventFlags`; the result is
read once per process and retained; and a unit test proves cumulative flags and
the exact reverse release order.

**A7. The matrix.**
Deliverables: eight shortcut rows for two families; two new probe-page title
fields, `s=<code> n=<counter>`, increasing the title from 30 to 39 characters,
below the WindowServer elision threshold of 60; new `FixtureReport` fields;
rows for two windows of the same application; and an
`AGENTSEAT_MANUAL_TESTS` manual suite.
Every row requires **two** proofs, delivery and effect, because that distinction
is central to the Command-V ledger entry.

| Row | Delivery | Chromium effect | AppKit effect | Expected |
|---|---|---|---|---|
| Command C | keydown c plus meta | `copy` event | pasteboard `changeCount` | FAIL |
| Command V | keydown v plus meta | `paste` event | field grows | FAIL |
| Command A | keydown a plus meta | `selectionEnd` minus `selectionStart` | `selectedRange().length` | FAIL |
| Command Z | keydown z plus meta | value returns | same through `undoManager` | FAIL |
| Command Shift Z | keydown z plus meta plus shift | value is reapplied | same | FAIL |
| Command Shift S | keydown s plus meta plus shift | a new target window | same | FAIL |
| Option Right Arrow | keydown ArrowRight plus alt | `selectionStart` advances one word | `selectedRange().location` advances | **PASS** |
| Esc | keydown Escape | `keydown` with Escape key | `cancelOperation:` | **PASS** |

Expected results are written before measurement: a matrix that predicts nothing
is not falsifiable. If Option-Right Arrow fails, the model is wrong. If Command-Z
passes, the Command-V ledger entry is narrower than believed and must be rewritten.

Command-Shift-S has no observable effect inside the page because Chrome opens a
native panel. The oracle is `WindowServerProbe` filtered by owner, the same as
for the contextual menu. "A new window appeared for that process" is the only
honest available claim.

To measure Command-V, the test must put a marker on the general pasteboard and
therefore **replace the person's clipboard**. The ledger identifies this as
unavoidable for any paste, so replacement is gated and visible. Only that row
uses `AGENTSEAT_PASTE_ROW=1`; it saves and restores the clipboard and is skipped
by default. Command-C reads only `changeCount`, a monotonic integer, and reads
none of the person's data.

The manual-suite rows are the real test of item 5 and turn
`CGEventSource(.privateState)` from a claim into a measurement. The person holds
Shift while the kit posts Command-C, verifying **both** directions: our event
carries Command but not the person's Shift, and the person's typing carries none
of our modifiers. Another row sends a never-released `flagsChanged` down followed
by the person's physical Command to measure whether AppKit resynchronizes
modifier state. Done when the report gives each row a PASS, FAIL, or INCO verdict
and every expected or unexpected FAIL produces a `SpiLedger.md` entry.

Run manually on 26A428 on September 15, 2026; results are in `SpiLedger.md`.
With Shift physically held, our event reaches the target with a **zero** mask,
measuring the private-source claim. A never-released transition instead rides
every subsequent event in the same session, and the person's physical Command
**does not clear it**. Only the inverse transition posted by the kit closes it,
which is ADR 0011.

One of the two directions promised above is not measurable with this target and
must be reported as such. The person's typing goes to the window in front of
them, never the probe page on the seat display. The inbound direction is
measured; the outbound direction remains without an instrument.

Both rows have a hardware oracle, without which they would prove nothing: zero
is also what an untouched keyboard produces. Each row therefore reads
`CGEventSource.flagsState(.hidSystemState)` and refuses to conclude unless the
key was physically held.

**A8. Spike outcome.** Entry written to `SpiLedger.md` on September 14, 2026.

**Half an answer, with the half identified.** The matrix ran on 26A428 against
the Chromium family with the default `eventFlags` policy. Five menu equivalents
were delivered and acted on by none. Option-Right Arrow was both delivered
**and acted on**, the control without which the other five would prove nothing.

**Closed.** The matrix ran four times, two families by two policies, and all
four cells agree. Six menu equivalents were delivered and acted on nowhere;
Option-Right Arrow acted on both families; Escape invoked the AppKit target's
`cancelOperation:`. `.flagsChanged` changes nothing, and the transitions were
actually emitted: Command-C grew from 2 events to 4, and Command-Shift-Z from 2
to 6.

The AppKit fixture lives at `/Users/mac/Forte_Projects/AgentSeatFixture`, outside
the package, because the kit ships no applications.

### Group B: text delivery

**B1. Declared units.**
Today's units are already mixed: `.text` iterates `for character in text` and
counts **grapheme clusters**; `.insertText` builds `Array(text.utf16)` and its
payload uses **UTF-16 units**; the documentation calls both "characters". They
match for ASCII but not for a ZWJ emoji, producing the wrong limit precisely
where the distinction matters.

| Unit | Where it applies | Why |
|---|---|---|
| grapheme cluster | `.text` count | it is the **cost**: one down and one up per cluster |
| UTF-16 unit | `.insertText` payload and limit | it is what `keyboardSetUnicodeString` accepts |
| byte | **nowhere** | explicitly excluded because `data.count` is the natural but incorrect way to derive a limit |

Deliverables: `TextUnit` and `TextMeasure`, carried on text-command receipts;
correct `InputCommand` documentation wherever it mixes units.
Done when no bare `Int` represents an amount of text on the public surface.

**B2. Chunking at Unicode boundaries.**
Swift `Character` **is** a grapheme cluster. Chunking by `Character` never
splits a surrogate pair, ZWJ sequence, combining sequence, or flag. No extra
mechanism is needed for that. The exception is that one cluster may be
arbitrarily long, so the chunker limits **both** units, N clusters and M UTF-16
units, cutting only at cluster boundaries. A single cluster above M is
**refused**, never split. Done when unit tests cover ZWJ emoji, regional flags,
combining sequences, and a pathological cluster above the limit.

**B3. Recipient and commit.**
Revalidation between chunks **already exists**: `sendSequence` calls
`engine.post` once per command, and `engine.post` reads identity at entry and
verifies it again immediately before the first event. The recipient is
`WindowIdentity`, which is the answer from Ticket 04.

`committed` is not a `Bool`, because a Boolean invites the forbidden reading
"the text is in the field":

```swift
public enum TextCommit: Sendable, Equatable {
    case allChunksPosted
    case stoppedAfter(chunks: Int)
}
```

**The cause belongs on the failure, not inside the enum.** An `any Error`
payload would remove `Equatable` from the case, exactly what a test needs to
assert the outcome. `TextDeliveryFailure` carries both the outcome **and** the
cause, just as `InputSequenceFailure` carries completed receipts and the cause.

**Two modes, not one.** The specification mentioned only `.insertText`, but
`.text` needs chunking more, not less: 8192 clusters are 16384 events in one
atomic Command, holding the actor and exclusion for up to 92 s on a native
target according to repository measurements. `TextDeliveryMode` selects the
path and **defines the counting unit for the entire outcome**: clusters for
`.typed`, UTF-16 units for `.inserted`.

`allChunksPosted` means only *all chunks posted, identity unchanged after the
last*. `stoppedAfter` says N chunks **are already inside the target** and there
is no rollback. It maps to `InputSequenceFailure`, which already carries
`completedReceipts`. Done when a send interrupted halfway returns `stoppedAfter`
with the exact number of delivered chunks and a test asserts it.

**B4. Measured limit and IME.** The sweep ran on September 14, 2026; results are
in `SpiLedger.md`. The declared cap of 8192 UTF-16 units arrives intact on both
families, and insertion cost is **constant**: 165 ms versus 169 ms on Chromium
between 512 and 8192 units. `TextDeliveryLimits` therefore rises to the cap,
because a smaller chunk buys nothing and repeatedly pays the fixed cost.

The IME row ran on September 14, 2026; results are in `SpiLedger.md`. With an
open composition on the AppKit target, `.insertText` **is discarded** and marked
text remains marked, four units before and after. The control in the same run
makes this a fact: the same insertion reaches the same window without a
composition. The row measures the **client** half of the protocol because the
target arms itself with `setMarkedText`, which is what an input method calls on
its client. The input source that owns the session and sees the event first is
missing, and a row requiring installed Japanese input would prove nothing on
another machine. The Chromium half is not measurable at all: a page can know
that composition began but cannot start it.

The user-written IME documentation remains.

**B4. Measured limit and IME.**
Measure the limit: `TypingCostLiveTests` extends the sweep upward until it
breaks, then places the UTF-16 limit below that point. Values above it are
refused. A3 sets the `.repeated` cap with the same method. Current evidence
covers 8192 clusters on both families, so the limit will not be lower.

IME: `.insertText` uses virtual key 0 with a Unicode payload and never consults
the layout, bypassing the input method. With active marked text it may commit or
replace the marked text or be discarded, and marked-text presence cannot even
be detected externally. The matrix therefore needs a row with a composing
target followed by `.insertText`; until then the documentation says **unknown**,
not safe.

Do not add a `charactersDelivered`-style field to the receipt. `eventCount` for
`.insertText` is 2 at every length, and the documentation must say so plainly,
because treating `eventCount` as delivered text quantity is the error the
Receipt must make impossible.

## 7. New vocabulary for Context.md

**Key Table**, **Keyboard Layout**, **Key Hold**, and **Shortcut**. Avoid
"Snapshot", which the glossary already reserves for a window's AX model.
