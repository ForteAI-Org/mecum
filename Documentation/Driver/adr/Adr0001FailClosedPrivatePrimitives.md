# Fail closed on private primitives, with no global fallback

Every private primitive the kit relies on is gated per macOS build: the symbol is
resolved, the record's shape is checked, the offsets are cross-validated against
public setters, and only a Ledger entry plus passing self-checks make a Facility
`validated`. A missing symbol or a changed record refuses action. The original
unknown-build refusal is superseded by [ADR 0015](Adr0015UnqualifiedBuildsRemainUsable.md). There is deliberately no fallback to global event
posting: an action that leaks onto the User Seat is worse than an action that
does not happen, and a click that may or may not have landed is worse than a
click that was never sent.

## Considered options

Falling back to `CGEventPost` (rejected: it breaks the isolation the kit exists
for), gating by macOS major version (rejected: yabai does this and silently
slides into legacy branches on an unknown major), trusting the Ledger alone
(rejected: the running system is the authority, so self-checks always run).
