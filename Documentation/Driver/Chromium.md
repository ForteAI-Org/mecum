# Chromium qualification

The current local qualification uses Google Chrome 154.0.8037.58 on macOS
27.0.1, build 26A434, Mac16,1. This is one browser version on one host;
`unvalidatedBuild` remains attached to Driver receipts. Electron and CEF reuse
ordinary `ChromiumPlatform` policy. Their separate application checks below
provide partial effects on named targets, rather than full family qualification.

The [application flow checks](ApplicationFlowChecks.md) separately exercise
Chrome, a GitHub Desktop Electron dialog and the official CEF client through Mecum. Successful checkbox,
drag and picker effects coexist with dropdown failures and unreadable context-menu
recipients. Initial short-text Unicode loss is fixed in the Engine; exact-value
repeats pass for all three apps, with a real LF also verified in Chrome and CEF.
CEF's drag was dispatched but its independent drop counter stayed at zero.
Those flows are partial evidence for
the named apps, not family-wide qualification.

## App integration and readiness

`SeatDriver.adopt` selects renderer policy from positive bundle evidence.
Before recording the window's home geometry, it obtains a qualified
`WindowReader.windowSnapshot` and compares the returned WindowIdentity with
its initial WindowServer reading. Failure prevents adoption. Chrome needs
individual AX role reads and bounded web-tree readiness, as implemented by
`WindowReader`; a thin toolbar tree is not a ready page.

A cold owned browser reproduced `subtreeUnreadable` on its first key before
this reading. The independent matrix with the reading observed an AXWebArea,
then delivered the first physical key. This is a readiness change, not a retry
of a posted or unconfirmed Command.

The app selects native composition qualification only for positive renderer
bundle evidence together with `com.google.Chrome`. Ordinary policy reuse
alone does not enable it for another shell or another Chrome distribution.
The composition operation still requires an explicit bounded
`AgentSeat.withNativeTextInput` scope. Individual key tools do not implicitly
start a composition lifetime.

## Repeatable local tier

```sh
make chromium-live-tests SWIFT=swift
```

Eight independent rows own their browser process and temporary profile. Each
uses a synthetic local page; no personal browser profile is selected. The tier
asserts one reported test per row and stops on failure. It covers:

| Row | Effect oracle |
| --- | --- |
| Input matrix | Page counters for key, bulk insertion, word navigation, HTML dialog cancellation, click, wheel and drag |
| Two windows | Target change refused with Shift held, release on the original window, then a plain key on the second window without residual modifiers |
| Native file picker | Attested hosted sheet contained in the Virtual Display, real Cancel click, DOM cancel event and no visible panel; zero selected files |
| Native composition | Browser compositionstart/update/end events and exact `é` after physical key positions |
| Composition deadline | Restoration while the callback waits, refusal of a freshly observed late key and no additional page effects |
| Composition cancellation | Cancellation with actual preedit present and successful preparation cleanup |
| Context-menu effects | Select All, a witnessed replacement, Undo to the original contents and Redo to the replacement |
| Print recovery | Context menu Print action, return to the same user app and window, stable cursor and an attested cleanup ledger; no print is submitted |

The input matrix retains six known failures of effect: copy, paste, select all,
undo, redo and Save. Their key delivery is asserted separately. They arrive
without the menu action taking effect in background. A green test summary with
six known issues does not qualify those effects.

The independent context-menu row provides observed Select All, Undo and Redo
effects on the same host. It identifies each enabled item by its actual AX frame
or the captured menu image and clicks only a newly observed menu surface.
Each action requires virtual containment, verified closure, zero physical events
and a foreground timeline containing only its original user-app sample.
Undo requires a preceding edit sent through a fresh Seat observation and confirmed
by the page's exact contents. Redo restores that edit. These effects qualify
the context-menu route; their keyboard equivalents remain delivered without effect.

The two-window row replaced an obsolete harness that attempted to move the
selected target with Shift still down. That is explicitly forbidden by the
current Turn contract. No held-key transfer capability is claimed.

The native picker uses `followsNewWindows`, as the real app does. An AXSheet
belongs to the host's accessibility tree; demanding a separate AXWindows entry
or requiring its own capture surface would measure the wrong representation.
The row identifies its sheet through the Driver observation and re-reads its
WindowServer identity and geometry before operating it. It finds the actual
Cancel control frame and selects no file. The first visible panel frame was
contained in the measured run; this does not establish absence of every
possible earlier exposure.

`LiveStage.run` awaits host teardown and its resource checks after a throwing
row, then rethrows the original error. A failed body cannot skip the teardown
verification merely by unwinding into an unawaited cleanup task.

## Native composition limits

Chrome's ordinary unprepared dead key produced no native preedit. The bounded
scope maintains internal preparation across separately observed physical keys.
No Unicode payload or scripted composition event is injected. The current
Dvorak source resolves an Option dead key and commit key with Carbon;
composition events and the textarea value provide the independent browser
oracle. Closure restores preparation. On this source, deadline and
cancellation commit a remaining isolated acute accent; they do not discard
marked text or roll back an edit.

Qualification requires `ChromiumPlatform(nativeTextInputIsQualified: true)`.
The default refuses native composition admission. An own-window endpoint is
required; qualified windowless page content can name that same recipient.
Remote endpoints, modals, held keys, pointer Commands, Command/Control
shortcuts and bulk text remain outside the scope. Task ownership, per-command
admission and the five-second ceiling are shared with the Qt implementation.
See [ADR 0018](adr/Adr0018BoundNativeTextInputPreparation.md).

## Remaining qualification

Candidate-window IMEs and CJK input, additional browser versions and macOS
versions, other Chromium distributions, complete Electron/CEF matrices and
hybrid native/web surfaces remain open. Native file selection, Save, nested native panels and
drag/drop across applications require their own effect oracles and owned
fixtures. The menu-equivalent effects above remain known failures.
