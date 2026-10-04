# Flows through the Mecum application

These checks were initiated from the signed Mecum app's conversation on
2026-10-03, on macOS 27.0.1, build 26A434, Mac16,1. They exercise the app's
discovery, broker, perception, Engine tools, Driver and handback together.
They do not extend qualification to other OS builds or applications.

The operator used an exclusive desktop and synthetic documents or form values.
No repository was created, committed or pushed; no login, upload or print was
submitted. Each app flow closed its Seat explicitly. An unverified input was
observed before any further decision and was not automatically replayed.

## Observed effects and failures

| Surface | Observed effects | Remaining failures or limits |
| --- | --- | --- |
| AppKit, TextEdit | Exact three-line replacement including `é` and `🧪`, confirmed in a fresh Mecum observation and independent AX read; native Open panel opened and withdrawn through AX Cancel; final discovery lists the offscreen owned window | Ordinary Cancel click returned `subtreeUnreadable`. Independent AX selection range supports the navigation effect, but Mecum does not expose that range and cannot verify the keys itself. |
| Adobe UXP, Photoshop 2026 | New Layer dialog and layer creation; New Document surface opened | First name replacement retained an old prefix. Exact supplementary Unicode is unqualified from OCR. Undo/Redo were refused as disabled. The claimed New Document cancellation was incorrect: independent WindowServer title and Window menu show an additional `Untitled-1` beside the owned seed. |
| Qt, Resolve 21.1.0 Project Manager | Search/filter, context-menu Select All followed by one Delete, native Import panel cancellation, restored search controls; final repeat reads exact `Mecum Qt é 🧪` | Cancel's learned effect prediction differed despite observed panel withdrawal. Resolve exceeded the one-second quit wait, then exited later; the app reports the pending cleanup. |
| Chromium, Chrome 154.0.8037.58 | Checkbox on/off, counter, scroll region offset, one successful HTML drag/drop, file picker opened/cancelled with zero selected files; final repeat reads exact short `é`/`🧪` text and a real LF | Web select resolution intermittently loses AX controls. Context menu opens, but type-ahead and Escape return `subtreeUnreadable`; a click outside does not reliably withdraw it. |
| Electron, GitHub Desktop | Exact synthetic repository name, README checkbox on/off, Create dialog withdrawn with Cancel; final repeat reads exact Description `Mecum Electron é 🧪` | Git Ignore selection returns `contextMenuNeverOpened` without changing the value. Create Repository was never invoked. |
| CEF, official `cefclient` 154.0.33.0 | Exact `Mecum CEF é 🧪` and multiline text with a real LF; checkbox on/off, counter 0 → 1, scroll offset 0 → 120, file panel opened/cancelled with zero selected files | One drag was dispatched but `Drops: 0` remained; `found_acted` did not establish a drop. Select returned missing/ambiguous with a text-only scene; `Alpha` remained. Initial geometry interruption caused no input effect. A checkbox clipped at the viewport edge initially stayed off, then worked after explicit scrolling. |
| Resolve Cloud, hybrid candidate | Cloud adopted, observed and returned to Local | Email/Password appear only as pixel labels, with no editable AX controls or value. One synthetic Email insertion is unverified. A CEF framework in the bundle does not prove this surface uses CEF. |

An app's visible label, a delivered event and an observed effect are different
evidence. The Chrome fields initially appeared only as pixel labels, although
the native AX tree contained the controls. The deeper walk restores those
controls. Initial short-text Unicode failures in Qt, Chrome and Electron were
reproduced before the Engine dispatch correction, then passed exact-value
repeats through the rebuilt app. The popup and modal limits remain.
The dedicated CEF fixture supplies separate evidence; it does not qualify
Resolve's hybrid surface. Additional UXP hosts remain unqualified.

The CEF sample was downloaded from the project's
[automated build distribution](https://cef-builds.spotifycdn.com/index.html),
which is linked by [cef-project](https://github.com/chromiumembedded/cef-project).
The selected macOS ARM64 client is
`154.0.33+ga03e714+chromium-154.0.8037.94`; its 132,795,446-byte archive matched
the distribution index SHA-1 `99ff6093774520c4dda09af9cea0aec47d27c708`.
The temporary app's bundle is `org.cef.cefclient` and embeds
`Chromium Embedded Framework.framework`. The operator opened the owned local
fixture, and an independent AX read confirmed the final text, counter and
unchanged drop count. The operator quit this sample after Seat closure and
verified its process had exited. No security or permission setting was changed.

CEF's later page-navigation scroll also changed the nested scroll offset from
120 to 204. This was a targeting side effect after the requested scroll check,
not the requested 120-pixel result or successful drag evidence. The disposable
fixture retained test text and counter values until it was closed.

## Corrections found by these flows

- Perception now harvests empty `AXTextArea` controls and uses their AX identifier
  when title, description and value are empty. The real TextEdit repeat confirms
  exact input after two failing regressions identified the missing role and handle.
- The default augmentation depth is 16 rather than 10. Chrome's measured fields
  were at depth 10, excluded by the former exclusive ceiling. Element, table and
  deadline limits still apply, and stale/out-of-window frames remain rejected.
- Session cleanup waits briefly for an owned app to terminate. If it is still
  running, `close_session` carries a warning. The app is already handed back;
  no unsaved document is discarded and the quit request is not retried.
- A click outside a popup reports an unverified dismissal when the popup remains
  or the window census fails. It cannot claim closure or suggest clicking again
  immediately without evidence. This corrects reporting; it does not repair the
  underlying popup delivery refusal.
- Scene metadata uses a fresh WindowServer title for the exact captured window
  number. The adoption title remains recovery metadata. Missing or ambiguous
  current rows supply no title, preventing a previous document name from being
  presented as current evidence.
- Short text containing supplementary Unicode or line breaks is inserted as
  one intact payload. The former per-character path lost `🧪` and changed line
  breaks on renderer and Qt fields. Four failing regressions cover emoji, LF
  and CRLF; the rebuilt app confirms exact values in AppKit, Qt, Chrome and
  Electron. Short BMP-only text retains its previous dispatch.
- Discovery can recover offscreen standard AX windows explicitly reported
  nonminimized, with matching server owner/ID and an attested usable native body.
  Minimized windows, attached panels, missing readings and unqualified geometry
  remain excluded. The tool now delegates to the session's discovery policy,
  rather than a separate onscreen census. Two regressions first reproduced the
  missing candidate and disconnected tool; final app reads list the same owned
  Photoshop and TextEdit IDs without manually activating Photoshop. Adoption
  still requires its own fresh identity, readiness and geometry proof.

The offscreen Photoshop repeat adopted and captured the owned document, then
refused the first New Layer shortcut with `geometryChanged` before delivery.
No modal appeared, and the command was not replayed. The scene did not provide
an unambiguous canvas target, so the canvas-focus and Undo/Redo sequence was
not executed. Discovery and title corrections therefore do not qualify editing.

## Validation

The regressions first reproduced missing controls, false popup-closure reporting
and stale scene titles, then short-text dispatch errors. The corrected targeted
suites pass. The local baseline
passes with 2,223 executed, 93 skipped, 2,316 reported tests in 28 bundles,
`problems: []`. The product build and signed Xcode build pass. Xcode app tests
pass with 320 tests in 59 suites; `git diff --check` passes.

The baseline intentionally skips live opt-in rows. The application effects in
the table come from separate live conversations and inspected outputs; unit
tests are not their substitute. The local conversation and diagnostics retain
the detailed action outcomes, synthetic values and unverified effects.

The [UXP guide](UXP.md), [Qt guide](Qt.md) and [Chromium guide](Chromium.md)
record the independent Driver tiers. Their passed rows do not erase failures
observed through the app's complete path.

The [expanded installed-app campaign](ExpandedApplicationChecks.md) adds nine
apps, repeated arithmetic, a guidance correction and remaining window/focus
failures. It brings the selected-flow campaign to fourteen installed apps plus
the separate CEF sample, without establishing an app-wide reliability rate.
