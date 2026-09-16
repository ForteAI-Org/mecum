# The default modifier policy leaves no state in the target

A shortcut holds its modifiers in one of two ways, and the platform chooses
before the first event goes out. `.eventFlags` stamps the modifiers on the key
events themselves. `.flagsChanged` also posts real modifier transition events,
which tell the target that a modifier went down and later came back up.

`.eventFlags` is the default, and no platform the kit ships asks for anything
else until a measured row says otherwise.

## Why the line is here

Three independent arguments point the same way, and none of them is about
which one delivers better.

A dangling modifier is not the same failure under the two policies. Under
`.eventFlags` the flags live and die with the single event they are stamped on,
so a hold left behind in `ModifierHold` is bookkeeping of ours and nothing
else: it makes the next command's flags wrong and it changes nothing inside the
target. Under `.flagsChanged` we have told the target, and a stuck Command key
inside somebody's editor is very visible.

The controller process can die between the press and the release, and no code
of ours closes that. It is a two process problem. Under `.eventFlags` it does
not exist, because no modifier state was ever communicated.

The row the whole investigation is for is unlikely to move. On AppKit,
`performKeyEquivalent:` reads the key event's own `modifierFlags`, which
`.eventFlags` already carries. On a Chromium renderer, a page reading
`e.metaKey` on a keydown sees it either way. The Command and V failure is not
in the delivery of the modifier, it is in menu resolution, and a modifier
delivered more thoroughly does not move a menu that belongs to another
application.

## Consequences

`.flagsChanged` is built, gated and measured anyway, because a negative that
was measured is a ledger line that closes the question instead of leaving it
open to every future caller who tries again. It refuses until the running
build's ledger says the `0x0C` record type was read back from a record, with no
implicit fallback to `.eventFlags`: a silent fallback would produce a matrix row
that passes for the wrong reason.

## What the matrix answered, 2026-09-14

The third argument above is no longer a prediction. The shortcut matrix ran
twice on macOS 27.0 build 26A428 against a Chromium renderer, once under each
policy, and the two runs are indistinguishable row for row. Under
`.flagsChanged` the transitions really went out, and the event counts say so:
Command and C rose from 2 events to 4, Command and Shift and Z from 2 to 6.
Command and C, Command and V, Command and A, Command and Z and Command and
Shift and Z were delivered and acted on by none under both; Option and the
right arrow acted under both.

So the ADR holds, and for the measured reason rather than the reasoned one.
`.eventFlags` stays the default because the fidelity it gives up buys nothing
and the failure it avoids is real.

The AppKit family was then measured too, against a Fixture built for it, and
its four rows agree with the browser's: the same six delivered and ignored, the
same word motion and the same Escape acted on, under both policies. Four runs,
two families, two policies, one answer.

If a menu-resolved row ever passes under one policy and not the other, on any
family, this ADR is wrong and the default changes.
