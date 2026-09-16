# One package, nine modules, no umbrella

The kit is a multi-target SwiftPM package (`SeatCore`, `PrivateSymbols`,
`VirtualScreens`, `WindowPlacement`, `SeatInput`, `CursorGuard`, `SeatCapture`,
`SeatSession`, `TargetReader` and two executables) rather than a single module
with folders. The module graph is what enforces the layering: `SeatInput` cannot
reach ScreenCaptureKit and no Facility can reach `TargetReader`, because neither
declares the dependency.

Each module is named for what it is, not for the package it ships in, and there
is **no umbrella target**. An umbrella needs `@_exported import` to make one
`import` reach the members of every module, and that is exactly the construct
that hides the boundaries the graph exists to draw: a file that compiles because
some other module was re-exported into it has a dependency nobody wrote down.
Removing it turned six such dependencies into import lines.

Two products carry the nine targets, because a product is a linkage unit and not
a module: `AgentSeatKit` for the eight modules that drive a seat, `TargetReader`
on its own for the one that only reads. A consumer changes one product reference
instead of eight, and still writes one import per module it uses.

## Consequences

Every module has its own unit suite, on its own target, because `@testable`
reaches internals only through the module itself. Default isolation is set per
target: pure types and protocols are `nonisolated`, Facilities and `SeatSession`
are `MainActor`, test targets take neither (a `MainActor` test target serializes
the whole run).

Every target declares what it imports, transitive reachability notwithstanding,
so moving a target into a second package later is moving a target and nothing
else. Two declarations are worth reading twice because they look like mistakes
and are not: `SeatCapture` depends on `SeatCore` for per-frame geometry and on
`WindowPlacement` to attest identity-bound window sources, while
`WindowPlacement` depends on `VirtualScreens` in one direction only, for the
screen-to-display reading and for the Facility's shared error type.
