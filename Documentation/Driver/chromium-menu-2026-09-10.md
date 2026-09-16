# Chromium menu and Live tier correction, 10 September 2026

Measured on macOS 27.0 (26A5425a), Google Chrome 153.0.8010.36. These results
come from controlled probes and the corrected package tests. The changes are
now installed in AgentSeatKit; no compatibility ledger entry was promoted.

## The menu finding

The previous Live test clicked the centre of a menu whose items were absent
from the accessibility tree. On the captured 242 by 661 point menu, that point
falls on **Print**, whose preview activates Chrome. Calling this a property of
all Chromium menu choices was not supported by the test.

The controlled comparison launches Chrome with a temporary profile and a local
text area containing `menu probe`. It opens the native menu through the kit's
routed right click, identifies an item in a ScreenCaptureKit image with Vision,
and posts an ordinary left click to the menu's own window, without Preparation.

| Choice | Independent effect | Frontmost during choice | Physical events during choice |
|---|---|---|---|
| Select All, trial 1 | page selection 5 to 10 characters | ChatGPT unchanged | 0 |
| Select All, trial 2 | page selection 5 to 10 characters | ChatGPT unchanged | 0 |
| Print, control | selection stays 5; Chrome activates | changes to Chrome | 0 |
| Select All, final matrix | selection becomes 10 | ChatGPT unchanged | 0 |
| Undo, final matrix | `changed` becomes `menu probe` | ChatGPT unchanged | 0 |
| Redo, final matrix | `menu probe` becomes `changed` | ChatGPT unchanged | 0 |

The first Select All trial also had zero physical events and an unchanged
cursor across the whole menu action. In the second, physical movement occurred
outside the choice interval; that run supports only the narrower choice result.
The Print control had zero physical events and an unchanged cursor throughout.
No print was submitted. The test-owned profile was terminated afterwards.

The integrated menu matrix now chooses the fixture's `Voce di prova` from its
accessibility rectangle and Chrome's Select All, Undo and Redo from their images. It refuses an
unidentified item. Chrome's page publishes its selection length in the title,
so closing a menu alone is no longer evidence of a successful choice. The
matrix asserts that the frontmost application stays unchanged and subscribes
to activation notifications as well as sampling the state.

**Decision:** retain the existing routed menu operation. Do not add a blanket
Command modifier or a private activation override. The consumer must identify
the command it chooses; Print and other commands that intentionally present UI
are not covered by the editing-command results. Keep the delayed `targetActivated`
guard. This finding does not promise that every Chrome menu command is usable
without activation, nor does it extend the result to every Electron application.

## Using the selection in a consumer

`AgentSeat.useContextMenu(openedAt:of:turn:choosing:)` already posts the
selection correctly. The consumer's closure must return a point relative to
the **menu window's top-left**, not the page or browser window. The kit sends
the left click to that menu's PID and Window ID with no Preparation. Applying
the normal Chromium left-click Preparation there dismisses the tracking loop.

Read an enabled item and its actual rectangle from `WindowReader.contextMenu`
when available. For the measured Chrome menu, capture the exact menu Window ID
and identify the requested text in that image. `MenuImageChoice.point(for:in:)`
in the Live test support demonstrates this observation, with exact English or
Italian labels and refusal on missing or duplicate matches. OCR belongs to the
consumer; it has not been inserted into the production input kit.

After the call, confirm the chosen command's effect in the target. A
`chosenItem` closure receipt proves that the click closed the menu, not that an
editor performed the intended operation. The expanded matrix uses selection
length for Select All and distinct field contents for Undo and Redo. It stages
the browser before returning focus and retains that staging until all effects
have been read, because a return to another Space can remove an unstaged
window from `AXWindows`.

## Source and private-primitive checks

Chromium's [menu controller](https://github.com/chromium/chromium/blob/main/ui/menus/cocoa/menu_controller.mm)
dispatches the selected item's model index through `ActivatedAt`; it does not
make arbitrary choices semantically interchangeable. Its
[context-menu helper](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/base/cocoa/menu_utils.mm)
uses the native NSMenu tracking operation. These sources explain why the
specific item matters; the comparison above supplies the runtime evidence.

The running SkyLight image was inspected in LLDB inside a separate local probe,
without invoking private setters. `SLSSetPreventsActivation` passes tag index
16 to `set_or_clear_tag`; `SLSSetWindowTags` accepts tag sizes 32 or 64 and first
consults `SLSMainConnection` and `CGSWindowGetMappedImpl`. This agrees with the
[CGSInternal tag declarations](https://github.com/NUIKit/CGSInternal/blob/master/CGSWindow.h)
and [the original NSPanel investigation](https://philz.blog/nspanel-nonactivating-style-mask-flag/).
Those describe window activation policy inside the owning application, not a
verified mechanism for suppressing a command's deliberate activation in Chrome.
The earlier local TextEdit experiment returned zero without changing the tag.
An additional gated probe called `SLSSetPreventsActivation` on the owned Chrome
test window and its menu. The 64-bit tags were unchanged after 400 ms:

| Window | Before and after | Setter status |
|---|---|---|
| Chrome page | `0x0300000100082401` | 0 |
| Chrome menu | `0x00000041400f2c00` | 0 |

The page still lacked bit 16; the menu already had it. Restoring the page's
original bit also left its tags unchanged. This is direct evidence that the
cross-process setter did not establish the requested policy. The same probe
observed Chrome activate, but physical input occurred during that interval, so
it is **not** an independent activation comparison. The earlier ordinary Print
control with zero physical events is the activation evidence. A first cleanup
assertion also mistook the zero tags of the destroyed menu for a restoration
failure; the disposable probe now checks whether the window still exists.

Cmd-click on Print was attempted but its separate probes failed during browser
setup, before a choice. It remains unverified, and was not added as a modifier
policy. No cross-process tag override was promoted or claimed to work.

Chromium's [Print implementation](https://github.com/chromium/chromium/blob/main/chrome/browser/renderer_context_menu/render_view_context_menu.cc)
calls `printing::StartPrint`, while its Undo, Redo and Select All cases dispatch
directly to the source WebContents. The
[preview controller](https://github.com/chromium/chromium/blob/main/chrome/browser/printing/print_preview_dialog_controller.cc)
then shows a constrained modal dialog. This supports investigating command
semantics separately from the click's delivery; it does not establish a
universal activation policy for other commands.

## Drag and test accounting

The bundled page publishes `AS c=...`; `ChromeTarget` was still searching for
`AS clicks=...`. Consequently both browser discovery paths timed out and printed
"skipped" from inside an otherwise passing test. The marker is corrected, a
pure resource-contract test checks both the initial and updated title, and a
launch failure or discovery timeout records a failure. Missing prerequisites
are handled by the test's explicit gate.

The corrected input matrix measured Chrome drag **0 to 240 points**, through 11
routed events, with Chrome in the background and ChatGPT frontmost, and no
cursor movement during that row. Its two Command-V rows remain measured known
issues, separate from the drag result.

`run-tier.sh` now reports executed, skipped and reported counts, rejects a
failed summary even with exit status zero, and saves its validated result in
the transcript. The compatibility report consumes that result, refuses an
all-skipped tier as evidence, and shows the skip reasons. Only the explicitly
disabled optional Live calibrations are exempt from its required-test gate.
The two delivery measurements name `AGENTSEAT_TEXT_DELIVERY=1` when that is the
missing opt-in; the typing sweep similarly names `AGENTSEAT_TYPING_SWEEP=1`.
An available fixture is no longer described as a non-executable file.

## Reproduction

- `make test`: unit tests and the twelve tier/report regressions.
- `AGENTSEAT_FIXTURE_APP=<consumer executable> make live-tests`: the complete
  Live tier; the three calibrations remain opt-in.
- `AGENTSEAT_LIVE_TESTS=1 AGENTSEAT_FIXTURE_APP=<consumer executable> bash
  Scripts/run-tier.sh drag 1 xcrun swift test --filter theInputMatrix --no-parallel`.

Evidence for this investigation is in `/tmp/agentseat-drag-fixed-output.log`,
`/tmp/agentseat-menu-plain-output.log`,
`/tmp/agentseat-menu-plain-repeat-output.log`,
`/tmp/agentseat-menu-print-output.log`,
`/tmp/agentseat-menu-fixed-output.log`, and
`/tmp/agentseat-chromium-research/private-symbols.log`.

## Final validation status

The installed package's unit run completed with **410 executed, 31 skipped,
441 reported**, plus twelve passing tier/report script regressions.

The final expanded menu matrix completed in **17.311 seconds**: the AppKit item
and Chrome's Select All, Undo and Redo all closed through `chosenItem`, confirmed
their editing effects, reported no `targetActivated`, and kept the cursor
unchanged with zero physical events. ChatGPT was the only frontmost application
during every menu action. Evidence: `/tmp/agentseat-menu-three-commands-final.log`.

The complete Live tier then ran in the installed package and **passed in
44.744 seconds: 6 executed, 3 skipped, 9 reported**. Chrome's drag moved from
0 to 240, and all three Chromium menu choices again confirmed their effects
with no activation, physical input or cursor movement. The three skipped
calibrations state their actual opt-in flags. Four measured known issues remain:
two Command-V effects and two Chrome AX-content assertions. Evidence:
`/tmp/agentseat-applied-live.log`. The user was explicitly free to resume using
the machine after this run.

Earlier failures remain failures: one Undo probe restored the text but had a
frontmost change and physical input outside the choice; other probes failed
browser discovery or lost a menu window before delivery. None were counted as
successful isolation measurements. The final matrix measures effects before
returning the browser from the virtual display, so a later Space change cannot
invalidate its readback.

Additional research evidence: `/tmp/agentseat-menu-print-tag-final.log`,
`/tmp/agentseat-menu-print-command-final.log`, and
`/tmp/agentseat-chromium-research/followup/`. The tag probe is diagnostic research,
not a new production route or a compatibility-ledger promotion.
