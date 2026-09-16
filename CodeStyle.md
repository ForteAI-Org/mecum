# Code style

Conventions for Swift packages and applications. Apply this document to new
code and to changed code in the surrounding responsibility. Do not reformat
unrelated files merely to make them match.

## Purpose

This guide makes module boundaries, ownership, failure behavior, and execution
constraints readable in the source. Formatting supports that goal; it does not
replace a stated contract or measured evidence.

## Public Surface and Visibility

- Treat `public` declarations as consumer promises and `package` declarations
  as contracts between targets within the package.
- Start with `private` for an implementation detail, `internal` for a module
  collaboration, and widen visibility only for a demonstrated consumer need.
- Keep platform types, transport handles, and storage details out of a public
  API unless they are deliberately part of the contract.
- A public value must not require callers to understand an inaccessible helper,
  an implicit global, or an undocumented lifetime.
- Prefer values for independent state and transformations. Use reference
  semantics when shared identity, coordination, or resource lifetime is part
  of the model, and document the consequence.
- Prefer `let`. A `var` represents a transition that should be clear to the
  reader and valid at every observable point.

## Naming

- Types use `UpperCamelCase`; members, parameters, and cases use
  `lowerCamelCase`.
- Keep initialisms consistent: `URLDecoder` for a type, `sourceURL` and
  `requestID` within member names, and `url` at the start of a member name.
  Preserve the required spelling when mapping an external API directly.
- Name booleans as questions or capabilities, such as `isReady`, `hasPendingWork`,
  and `canRetry`.
- Prefer names that expose a role, unit, direction, or phase when those facts
  affect correctness: `byteOffset`, `timeoutSeconds`, `destinationFrame`.
- Avoid vague containers such as `Manager`, `Helper`, `Utility`, and `Data`
  unless the domain gives them a precise, documented meaning.
- Do not use cryptic abbreviations. Keep an abbreviation only when it is
  universal in the relevant domain and clearer than its expansion.
- Protocols name roles or capabilities. Never append `Protocol` to a protocol
  name. `ByteReading` and `CommandSending` communicate more than
  `ByteReaderProtocol` or `SenderProtocol`.

## Documentation and Comments

All comments are written in English.

Use `///` for declarations whose role, contract, or reason for existing cannot
be recovered from the signature. Public declarations normally need it; private
code needs it when an invariant, lifetime, algorithmic decision, or restriction
would otherwise be easy to break.

For a type or protocol, start with its name as the subject. For a method, start
with a precise verb. State the role or result first, then the motivation and
constraints that the signature does not show.

A useful doc comment states only the facts that apply:

- the role or behavior of the symbol;
- the reason for a separate abstraction or non-obvious decision;
- caller obligations and invalidation conditions;
- ownership, borrowing, copying, and resource lifetime;
- isolation, ordering, reentrancy, or callback behavior;
- failure effects, including partial effects, cancellation, cleanup, and retry;
- units, limits, and performance conditions when they are contractual.

```swift
/// ByteReading supplies a bounded sequence of bytes addressed by offset.
///
/// A read borrows the destination only until the operation returns. A failed
/// read may have modified part of that destination.
public protocol ByteReading {

    /// Fills the entire destination or throws if the complete read fails.
    mutating func read(
        at offset       : UInt64,
        into destination: UnsafeMutableBufferPointer<UInt8>
    ) throws
}
```

Use `//` only for an implementation decision that would be misread without its
reason. An implementation comment has at most two lines, excluding a file
header. Move longer material to the enclosing declaration's documentation or a
design document with a durable purpose.

```swift
// Validate before updating state, so a rejected request leaves the prior value.
guard request.isValid else { throw RequestError.invalid }
```

- Do not leave commented-out code. Use version control for prior versions.
- Do not use an em dash in comments. Use a comma, colon, parentheses, or a new
  sentence.
- Use `TODO` only for a concrete remaining task with a completion condition and,
  where available, a tracking reference.
- Document a workaround's scope, reason, and removal condition. Keep extensive
  investigation history out of an implementation comment.

## Layout and Files

- Indent with four spaces. Do not use tabs for indentation.
- Keep lines generally within 100 to 120 columns. Break earlier when that makes
  ownership, conditions, or labels easier to scan.
- One top-level type per file is normal. A file may contain at most two
  top-level types when they form one small, inseparable responsibility.
- Name a file after its principal type. Organize folders around responsibilities,
  not generic buckets such as `Misc`.
- Put attributes and property wrappers on their own line above a declaration.
- Use blank lines between meaningful groups and members.
- Align colons, assignments, and labels within a small local group when doing so
  improves scanning. Do not create large-scale alignment churn in unrelated code.
- Break declarations and calls with more than one argument across lines, with
  one argument per line and the closing parenthesis on its own line.

```swift
let receipt = try await sender.send(
    command,
    to           : destination,
    correlationID: correlationID,
    options      : options
)
```

Order a type so the reader meets its role, stored dependencies and state,
initialization, primary operations, and private helpers in a coherent sequence.
Place conformances or derived behavior in extensions when that clarifies the
role. Do not split one invariant across many files without a real boundary.

## Protocols, Generics, and Closures

Protocol-oriented design represents actual behavioral variation. Introduce a
protocol when a consumer needs a stable role and there is a concrete alternate
implementation, test double, platform adapter, or near-term boundary that the
role makes clearer. Do not mirror a concrete type behind a protocol merely for
symmetry.

- Keep requirements minimal and behavioral.
- Put behavior derivable solely from requirements in a protocol extension.
- Do not supply a successful default for persistence, authorization, cleanup,
  or another operation that a conformer may need to perform.
- A method only declared in an extension is not a customization requirement.
  Make it a requirement when callers depend on conformers overriding it.
- A test double preserves the required ordering, failure, and resource-lifetime
  semantics. A happy-path fake alone does not prove the contract.

Choose the abstraction form from the required behavior:

| Form | Use when | Review |
| --- | --- | --- |
| Generic `T: Role` | The algorithm preserves a concrete type relationship. | Does the type relation help callers, and is code size acceptable for this target? |
| `any Role` | The implementation is chosen or stored dynamically. | Does the API need heterogeneity, and is the existential usable by the target toolchain? |
| `some Role` | A concrete implementation should stay hidden while retaining static identity. | Does the result use one underlying type across all return paths? |
| Closure | One focused behavior is injected. | Are captures, lifetime, isolation, and error semantics explicit? |

Do not claim that one of these forms is universally faster. Evaluate the call
pattern, build configuration, binary-size budget, and measured workload when
performance matters.

## Module Boundaries and Reuse

Every reusable module declares what it is independent from. “Agnostic” without
an object is not a useful claim. State whether it is independent from a UI,
transport, storage backend, application, operating system, or another detail.

For a reusable module, record:

- responsibility and the problem it solves;
- dependencies it intentionally excludes and dependencies it requires;
- public values and role contracts;
- ownership, execution, failure, cancellation, cleanup, and retry rules;
- units, capacities, formats, and other hard limits;
- the evidence for reuse, including actual consumers or adapters.

Use this dependency direction when it fits the problem:

```text
Composition / Consumer
        -> FeatureCore <- PlatformAdapter
        -> PlatformAdapter

FeatureCoreTests -> FeatureCore + TestAdapter
```

The core owns the role protocols it consumes. A platform adapter imports the
core and platform frameworks. The core does not import an adapter or construct
one of its concrete types. A separate contracts target is justified only when
multiple independent modules need the contracts without the core algorithms.

Dependencies are supplied at composition. Do not recover time, randomness,
configuration, authority, filesystem paths, environment values, or service
singletons from inside a reusable algorithm unless that implicit dependency is
itself the explicit contract.

Configuration is a value or a narrowly scoped dependency with documented
defaults. It must not silently couple separate module instances. Avoid global
mutable configuration; if a process-wide setting is unavoidable, isolate access,
document its scope and synchronization, and provide a controlled reset path for
tests.

A second adapter proves substitutability when it preserves the same contract.
Claim cross-project reuse only after a second consumer target or package builds
and exercises the library product without the first application's layer. Check its transitive
dependencies, resources, isolation, and required toolchain. Moving files under
a `Core` directory or adding a generic parameter alone is not evidence.

## Ownership, Resources, and State

Each resource-owning type identifies who creates, borrows, transfers, and
releases its resources. This includes buffers, file descriptors, tasks,
subscriptions, locks, transactions, and framework handles.

- Say whether a parameter is borrowed only for a call, copied, retained, or
  transferred.
- State whether an output remains valid after a later operation, cancellation,
  or owner deinitialization, and make callback retention intentional.
- Release synchronously scoped resources with `defer` when appropriate.
- Give asynchronous release and cancellation an explicit completion path.
- Validate identifiers, ranges, capacities, alignment, and arithmetic before an
  access or irreversible effect when the contract permits.
- Preserve invariants at every return, suspension, callback, and handoff point.
- Do not force-unwrap optionals or use `try!` in ordinary production code.
  A narrowly contained unsafe invariant requires an adjacent justification
  and validation that makes its precondition true.

## Errors, Cleanup, and Retry

Model failures so a caller can choose a correct next action. An error type or
result should preserve the facts the consumer needs, rather than forcing it to
parse a localized sentence or infer state from logs.

Distinguish, where relevant:

- rejection before an effect begins;
- a failed operation with known or possible partial effects;
- successful work followed by failed cleanup;
- cancellation before completion and cancellation after externally visible work;
- retryable conditions and operations that must not be repeated automatically.

Do not swallow errors with `try?`, erase them in a default value, or add an
implicit retry to an operation that may already have taken effect. `try?` is
appropriate only when absence is an intentional, documented result. A fallback
is allowed only when its trigger, behavior, and caller-visible result are
defined. Keep the primary failure when cleanup also fails.

## Concurrency and Isolation

Concurrency behavior belongs in the API contract. State which executor, actor,
queue, or synchronization rule protects mutable state when that is not obvious.

- Choose an actor when actor isolation matches ownership of the state.
- Choose another synchronization mechanism only with a clear owner and rule for
  accesses, ordering, and shutdown.
- Do not apply `@unchecked Sendable` or `nonisolated(unsafe)` merely to satisfy
  the compiler. Record the actual synchronization invariant and test it.
- Recheck state after `await` when another task could have changed it during the
  suspension.
- Document callback isolation, reentrancy, ordering, and whether a callback may
  block or invoke the owner again.
- Keep cancellation handling near the work it interrupts, including the cleanup
  and residual state it leaves behind.
- Do not inherit a target's default isolation accidentally. A module boundary
  declares the isolation it needs and verifies its public surface accordingly.

## Performance and Memory

Make performance claims only for a named path, environment, and measurement.
Document a capacity, allocation expectation, latency budget, or complexity when
it is a maintained part of the contract.

- A generic, actor, closure, reserved capacity, or inlining attribute is not a
  performance proof on its own.
- Caller-provided scratch storage can make allocation ownership explicit when it
  fits the API. It does not guarantee that an adapter or downstream dependency
  will not allocate.
- Reuse buffers only when their owner, exclusivity, and clearing behavior are
  well defined.
- Keep benchmarks separate from functional tests and use a meaningful control.

## Verification

Verify the contract at the level where its guarantees apply.

- Test normal results, boundary conditions, invalid input, state transitions,
  partial failure, cleanup failure, cancellation, and retry behavior when each
  is supported by the API.
- Test a core through controlled adapters that preserve the real contract's
  ordering, failure, and lifetime semantics.
- Test platform adapters at their boundary, with host or integration checks when
  their behavior depends on a framework, service, device, or process.
- Prefer Swift Testing for new suites when it fits the project. Preserve an
  existing test framework where migration would be unrelated work.
- Keep unit, integration, benchmark, and live-environment evidence distinct.
  A successful build or mock test does not prove behavior on an external system.
- State prerequisites for environment-dependent checks, such as permissions,
  fixtures, service versions, and hardware.

## Review Checklist

- [ ] Names describe roles, units, and transitions without vague containers.
- [ ] Public visibility, dependencies, and configuration are intentional.
- [ ] Docs explain contracts, ownership, and failure behavior where types alone
      do not.
- [ ] Comments are English, contain no em dash or disabled code, and `//` stays
      within two lines.
- [ ] Files, formatting, and local alignment keep responsibilities easy to scan.
- [ ] Protocols isolate real variation and core dependencies point away from
      platform adapters.
- [ ] Ownership, cleanup, cancellation, retry, and concurrency rules are stated
      and preserved by the implementation.
- [ ] Tests cover the contract and distinguish controlled from live evidence.
- [ ] Substitutability is checked with another adapter; cross-project reuse
      is checked with another consumer.
