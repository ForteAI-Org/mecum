# Withdrawn: a bounded foreground window for one action

**Status: withdrawn on 2026-09-18, after being accepted, built, measured live and
removed.** No code implements it. This ADR is kept for the measurement, which is
worth more than the code was.

The decision it recorded was that the seat could take the person's focus on
purpose, for one bounded action, and give it back. The reason was that a file the
agent had copied would not paste into Slack from the background, and the theory
was that the missing fact was the target being genuinely frontmost. The theory
was wrong, and the live runs say so precisely enough that nobody should have to
build this again to find out.

## What was measured

Every cell is a live run, with the pasteboard verified between the copy and the
paste.

| pasting a file into Slack | in the background | with the target frontmost |
|---|---|---|
| Command with V | nothing | nothing, frontmost confirmed at 23 and 29 ms |
| the contextual menu item | text yes, file no | text yes, **file no**, at 34, 46 and 84 ms |
| the contextual menu item, by hand | | file yes |

The copy is not in doubt: the kit reported choosing Copy in the contextual menu,
and a types-only probe then read `public.file-url` and `com.apple.icns` off the
pasteboard. The item click is not in doubt either: the kit reported choosing
Incolla on every run. And the discriminator is sharper than "no attachment": with
text on the pasteboard that same click pastes text, and with a file it does
nothing at all. Slack acts on the click. The file attach is what fails.

## What that rules out, and what is left

Being frontmost was never the missing fact. The bottom two rows of the table
differ in nothing else: same application, same menu, same item, same pasteboard,
same window, frontmost in both. The only difference left is the provenance of the
event itself, routed and synthetic against real HID. A bounded foreground window
cannot change that, so it bought nothing and cost the person their focus, which
is the most expensive thing this kit can spend.

ADR 0011 already recorded the other half: Command with C, V, A and Z are
delivered and acted on by none, because a key equivalent is resolved by the
frontmost application's menu. The foreground window was the experiment that
tested whether that was the whole story. It was not.

## Do not propose this again for the clipboard

Not for a paste, not for a key equivalent, not for a menu item. The measurement
above is the answer, and the next person to have this idea should read the table
rather than rebuild the mechanism. **Files reach an application through its own
attach button and the system file panel**, driven as ordinary Commands, which is
where the effort belongs.

Nothing here argues that the seat may never take the person's focus. It argues
that this particular reason was tested and did not hold. A future proposal needs
its own measured reason, and it starts from an empty page rather than from this
one.

## What was built, and what became of it

For the record, because a withdrawal that hides what it removed teaches nothing.

The operation was `AgentSeat.withTargetInFront(observation:turn:within:body:)`,
with a second entry point scoped to a `SeatMenuInteraction` for the one shape the
evidence pointed at, the menu item clicked with the application in front. It
refused before activating anything unless a fresh prepared restoration to a
window of the person's own could be built at that moment; it armed an expectation
on `UserFocusRecovery` so the activation it caused was not read as the person's
focus being taken; it activated through `_SLPSSetFrontProcessWithOptions` with a
participant resolved beforehand; and it gave the focus back through the same
validate-and-restore body the automatic path uses. All of it is gone:
`withTargetInFront` on both types, `ForegroundWindowOutcome`,
`UserFocusRestorer.bringToFront`, `InputPauseReason.targetNotPrepared`, the two
`SessionFailure` cases, the expectation state on the recovery, the report's
provenance, and the suppression of `SeatIssue.targetActivated` that went with it.

Three findings from that work outlived it, and two are still in the tree.

**The desktop is not one of an application's windows.** The Finder draws one
desktop window per display, so `containsOnlyVirtualWindows` could never be true
while the Finder was adopted, on any machine, by construction; and the desktop of
a physical display satisfied every clause of `containsUserWindow` and could have
been restored to as though it were the person's own window. That is a defect of
the **automatic** recovery, found while the foreground window was being run, and
it is fixed. ADR 0010 records it, and that section stands on its own: it does not
depend on anything in this ADR.

**The gap between a restoration requested and a restoration verified is real.**
The 250 ms verification window can pass and the focus still arrive afterwards,
measured. Nothing in the kit acts on that today, and it is written down here
because it is the kind of fact that costs a day to rediscover.

**A refusal that leaves the seat reporting nothing is worse than a noisy one.**
Both of the suppression bugs found during this work were silences, not errors.

## What this ADR no longer says

Every rule it used to state about arming, deadlines, suppression, provenance and
the handback is void, because nothing implements them. ADR 0010 is unchanged by
the withdrawal and remains the contract for automatic user focus recovery,
including its 2026-09-18 revision about desktop-level windows, which is not
foreground-window work and does not depend on this decision.
