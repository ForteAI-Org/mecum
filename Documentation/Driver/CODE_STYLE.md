# CODE_STYLE.md

Conventions for **AgentSeatKit**, a macOS library. Derived from
`fEditorEngine/CODE_STYLE.md` and adapted to a package whose public surface is
the product. Where the two disagree, this file wins here.

## Principles

1. **The boundary is the design.** Every `public` symbol is a deliberate promise;
   everything else is `internal` by default and `private` where it can be. A type
   that leaks a private primitive to a caller is a bug, not a shortcut.
2. **Protocols carry role names**, never a `Protocol` suffix: `WindowRelocating`,
   `EventPosting`, `InputPlatform`. A protocol with one implementation and no
   second one in sight does not get written.
3. **Fail closed.** On an unknown symbol, record layout or macOS build a Facility
   refuses. There is no implicit fallback anywhere in this package.
4. **No unsafe unwraps.** `!` and `try!` are out. The audited exception is the
   record writing path, where every offset is bounds-checked first.
5. **Explicit over clever**, and in the hot paths comment the trick.

## File header

```swift
//
//  CursorFence.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//
```

## Naming

- Never cryptic. `preparationSettle` over `settle`, `windowPointFromTop` over
  `pt`. No abbreviations unless universal (`url`, `id`, `pid`, `hid`).
- Types `UpperCamelCase`, members `lowerCamelCase`, acronyms uppercase in
  identifiers (`windowID`, `processID`) except where a field mirrors an SDK
  struct one to one.
- Booleans read as questions: `isStaged`, `hasTurn`, `canRecover`.
- The domain vocabulary is `CONTEXT.md` and it is binding: a type that means Seat
  Host is called `SeatHost`.

## Comments, in English

Antirez style: generous `///` prose that explains the *why*, the trade-off and
the gotcha, opening with the symbol's own name as the subject. Implementation
comments (`//`) are at most **two lines**; longer belongs in the `///` doc of the
enclosing declaration or nowhere. **Never an em-dash** in a comment: comma, colon
or two sentences. Never leave commented-out code.

For a private primitive the doc says which build it was verified on and what the
fallback is (there is none, so it says what fails), and the Ledger entry is the
machine-readable half of the same statement.

## Layout

- Four spaces, lines about 100 to 120 columns.
- **At most two top-level types per file**; one is the norm and the file is named
  after it. Folders by concern, split into subfolders when a concern grows.
- Align in columns: pad before the colon to line up types, align `=` in related
  groups, align enum raw values and trailing comments.
- A call or declaration with more than one argument breaks: opening paren ends
  its line, one argument per line with labels aligned, closing paren alone.
- Property wrappers and attributes on their own line above the declaration.
- Vertical breathing room over dense packing; a blank line between members.

```swift
let receipt = try driver.send(
    command : .click(location),
    to      : window,
    platform: platform
)
```

## Concurrency

Default isolation is set per target (`Package.swift`): pure types and role
protocols are `nonisolated`, Facilities and `Session` are `MainActor`, test
targets take neither. A `public` constant in a `MainActor` module is unreadable
from a `nonisolated` test, so pure values live in `SeatCore` or say
`nonisolated`.

`InputDriver` and `VirtualDisplay` are actors. The cursor fence callback runs on
its own thread with its own run loop and has **no synchronous external
dependency**: no actor hop, no `Task`, no escaping closure, no `OSSignposter`,
because each of those allocates and the callback's budget is zero allocations.

## Errors and logging

One error type per Facility (`InputFailure`, `DisplayFailure`, `FenceFailure`,
`CaptureFailure`, `SystemFailure`, `SessionFailure`), with structured cases in
English carrying the codes a report needs. Never swallow an error. Logging goes
through `os.Logger`, subsystem `dev.forte.AgentSeatKit`, one category per
Facility; user-facing prose is the consumer's job, so the kit returns fields, not
sentences.

## Tests

Swift Testing (`@Test`), suites mirroring the module folders. Unit tests are pure
and parallel; Host and Live suites are `.serialized` and gated by
`AGENTSEAT_HOST_TESTS` / `AGENTSEAT_LIVE_TESTS`. Anything with a measured budget
carries its benchmark, and a benchmark without a subtracted control is not a
measurement.
