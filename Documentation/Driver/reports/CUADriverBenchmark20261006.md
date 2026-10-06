# Mecum vs Cua Driver: macOS benchmark

**6 October 2026 · MacBook Pro M4 (base model), 16 GB RAM**

This run compares the two drivers on the same windows in nine macOS applications. It measures individual tool calls and their responses, including the time needed to return an updated view of the app. Both drivers kept their default observation, settling and safety behavior.

Mecum returned substantially less context per read and lower reported step medians in the five non-Qt application rows outside Stocks and Safari. It also used more driver CPU and memory. The application results show specific strengths and failures for each driver; they are not a support percentage for an entire framework.

[Results](#results) · [Failures and UI effects](#failures-and-ui-effects) · [Resources](#resources) · [Method](#method) · [Reproduction](#reproduction) · [Per-operation latency](#per-operation-latency)

## Results

### The main measurements

| Measurement | Mecum | Cua Driver |
| --- | --- | --- |
| Estimated tokens per full read, across eight apps | 142–978 | 3,801–34,002 |
| Estimated tokens when Mecum's scene was unchanged | 38–100 | Full read values shown below; no separate unchanged-read series |
| Median equivalent step, five non-Qt app scenarios, excluding Stocks and Safari | 1.047–1.316 s | 1.355–1.602 s |
| Median driver memory footprint | 132 MB | 35 MB |
| Peak driver memory footprint | 241 MB | 122 MB |

Mecum's full-read responses contain **85–97% fewer estimated tokens** in the paired application results. Cua returns roughly **7–35 times as much context**. These are estimates of response context, not tokens billed to a model or savings measured over a complete task.

For the five non-Qt app rows outside Stocks and Safari, Cua's reported step medians are **15–39% higher** than Mecum's; the median of those five relative differences is **30%**. This calculation uses the supplied app-level values. TextEdit, Chrome and kitty have different accepted operation sets, so it is not a matched-operation speed estimate. Stocks has no Mecum measurement; Safari's refusal pattern differs too much; Qt is outside Cua's declared background support.

### Qt background support

Cua's [official macOS guide](https://github.com/trycua/cua/blob/main/libs/cua-driver/rust/Skills/cua-driver/MACOS.md#canvases-viewports-games-blender-unity-ghost-qt-wxwidgets) describes Qt/GPU viewports as requiring foreground input, with no background route. Qt is also absent from its [accepted native macOS support ledger](https://github.com/trycua/cua/blob/main/libs/cua-driver/docs/action-support.md#native-macos). These sources were checked on 6 October 2026. For this background-driver comparison, Cua is marked **Not supported** on DaVinci Resolve and Prism Launcher.

The experiment still tried both drivers on simple controls: Resolve's Project Manager view buttons and scrolling, and Prism's Meow toggle and a key press. Both returned successful responses for these basic interactions, and the independent probe confirmed Prism's toggle changed with both drivers. Resolve's GPU editing canvas was not tested. These checks do not establish general Qt background support.

Cua's Qt action timings, completion counts and action-resource values are therefore omitted below. A dash in those cells means outside declared support, not that the calls were never attempted or all failed. The original experiment record retains the measurements. Scene reads and token estimates stay in the Perception comparison because observing a window is separate from operating it.

### Driver-reported completions

Each count is reported-done calls / attempted calls in the eight measured repetitions. The source report calls this field “ok”. It includes actions whose effect the driver could not verify, so it must not be read as task success or framework coverage.

| Application / framework | Mecum reported done | Cua reported done | Cua background support | Observed boundary |
| --- | --- | --- | --- | --- |
| TextEdit (AppKit) | 48/56 | 56/56 | Supported | Select All menu refused as disabled. |
| Chrome (Chromium) | 48/56 | 56/56 | Supported | Bookmarks menu refused as disabled. |
| Obsidian (Electron) | 40/40 | 40/40 | Supported | All tested operations accepted. |
| Stocks (Mac Catalyst) | session refused | 24/24 | Supported | Mecum could not open the session; Cua accepted keys and scrolling. |
| kitty (OpenGL/GLFW) | 40/40 | 32/40 | Partial | Mecum typing passed the OCR check; Cua typing failed. Ctrl chords had no confirmed effect for either driver. |
| DaVinci Resolve (Qt + GPU UI) | 32/32 | — | Not supported | Basic Project Manager controls were tried; Qt background support is not declared by Cua. GPU canvas editing was not tested. |
| Prism Launcher (Qt 6) | 16/16 | — | Not supported | Toggle and key operations were tried; Qt background support is not declared by Cua. |
| Calculator (SwiftUI) | 24/24 | 24/24 | Supported | Display changes independently checked; Cua had one initial AX error before the measured run. |
| Safari (WebKit) | 48/64 | 24/64 | Partial | Mecum refused both menu commands. Cua refused typing, keys and scrolling with a second window open. |

TextEdit and Chrome account for eight refused Mecum menu calls each; Safari accounts for sixteen. The separate Stocks session failure prevented its action block from running. Resolve's result covers Project Manager interactions, not GPU canvas editing.

### Equivalent step latency

An equivalent step gives the agent an action result and the app's state afterward:

- **Mecum:** the action tool already returns the updated scene.
- **Cua:** the action is followed by `get_window_state`.

Values below are the source's per-application medians in milliseconds. They include the driver's default waits and client transport, but exclude session opening and closing. Refused or failed operations change the accepted mix: use the completion table above to interpret each row. A matched-operation timing summary requires the raw paired measurements.

| Application / framework | Mecum step (ms) | Cua step (ms) |
| --- | --- | --- |
| TextEdit (AppKit) | 1,069 | 1,489 |
| Chrome (Chromium) | 1,227 | 1,590 |
| Obsidian (Electron) | 1,316 | 1,513 |
| Stocks (Mac Catalyst) | — | 2,061 |
| kitty (OpenGL/GLFW) | 1,155 | 1,602 |
| DaVinci Resolve (Qt + GPU UI) | 1,269 | — |
| Prism Launcher (Qt 6) | 1,127 | — |
| Calculator (SwiftUI) | 1,047 | 1,355 |
| Safari (WebKit) | 1,246 | 1,385 |

**Safari is not a direct speed comparison.** Cua's median includes only its accepted click and menu calls; Mecum's median includes a different set of accepted operations. Both values are retained to describe the run, not to rank the drivers on Safari.

### Estimated context per read

Mecum returns a structured text scene. Cua returns a screenshot and the full AX tree as Markdown. All values below are estimated tokens in MCP `content`.

| Application / framework | Mecum full read | Mecum unchanged | Cua full read |
| --- | --- | --- | --- |
| TextEdit (AppKit) | 385 | 100 | 6,185 |
| Chrome (Chromium) | 978 | 38 | 13,986 |
| Obsidian (Electron) | 738 | 97 | 7,307 |
| Stocks (Mac Catalyst) | Session refused | — | 5,755 |
| kitty (OpenGL/GLFW) | 142 | 39 | 4,566 |
| DaVinci Resolve (Qt + GPU UI) | 764 | 38 | 17,924 |
| Prism Launcher (Qt 6) | 622 | 39 | 4,157 |
| Calculator (SwiftUI) | 476 | 38 | 3,801 |
| Safari (WebKit) | 977 | 38 | 34,002 |

Text tokens were estimated at four characters per token. Image tokens used the source's Anthropic-style area estimate, `width × height / 750`, after resizing. No real-model task was run and no provider usage counter was collected.

The unchanged-scene comparison ranges from about **62× to 895×**, using Cua's full-read value against Mecum's unchanged value for each app. It exceeds 100× in six of eight rows, not every row. Returning a scene diff reduces context size; it does **not** make Mecum's observation faster.

Cua also returns 34–425 KB of `structuredContent` per read. Those bytes are excluded from the token estimate. A client that forwards that field to its model adds further context.

## Failures and UI effects

### What the independent probe confirmed

The probe read the target's AX values before an action and 250 ms afterward. Where an observable, deterministic effect existed, both drivers produced it in every measured repetition:

| Application | Independently checked effect |
| --- | --- |
| Calculator | Display after pressing 7 and Escape |
| Chrome fixture | Button press counter |
| Prism Launcher | Meow toggle state |
| TextEdit | Document text |

Scrolls, Tab moves and menu commands did not change a value available to this probe. Their rows therefore rely on the driver's own verdict. The independent checks do not establish success for every accepted action.

kitty exposes no terminal text through AX. A window capture plus Vision OCR confirmed Mecum's inserted text in every repetition. Cua reported that it delivered zero of ten characters and returned an error. Neither driver's Ctrl+U or Ctrl+A cleared the line in the background; the responses were unverified, not independently confirmed successes.

### Cases that need attention

| Case | Result and explanation |
| --- | --- |
| Mecum / Stocks | `open_session` failed twice with `placementNotConfirmed`. Stocks had a second 482 × 600 Untitled window whose placement was not confirmed. Adopting all substantial process windows aborted the session, although the requested window could be adopted alone. |
| Mecum / background menus | TextEdit Select All, Chrome Always Show Bookmarks Bar, and Safari Zoom In / Actual Size were refused as disabled. Cua accepted each tested menu item in all eight repetitions. Its menu path makes the window key and raises it before restoring focus. |
| Cua / Safari with two windows | `same_pid_keyboard_ambiguity` refused typing, keys and scrolling. The measured table contains 40 such failed calls; the report records 45 refusals overall. The refusal protects against a process-scoped key reaching another window. Mecum avoided that ambiguity by moving both Safari windows onto its virtual display, including the person's other window. |
| Cua / Calculator startup | The first AX press failed once with `-25204`, then succeeded on retry. |
| Resolve scenario setup | Escape closed the Project Manager and quit Resolve with no project open. That scenario was removed before the measured run. |

### Foreground and cursor observations

The probe recorded no target becoming frontmost and no physical cursor movement attributable to either driver. Recorded cursor movements arrived in bursts that also included read-only calls; the source attributes them to the person using the Mac.

This observation does not measure lost keystrokes or prove that simultaneous typing is unaffected. A sentinel window recording focus, key and pointer events is a separate test still to run.

### Context outside the target window

Cua's AX tree included the app's full menu bar, including Apple → Recent Items. Names of recently opened files, projects and apps can therefore enter the model's context even when they are unrelated to the target window. Mecum's scene omits the menu bar; its `menu` tool reads it on request.

## Resources

### Idle memory and CPU

| Driver | MCP ready (ms) | Median footprint (MB) | Peak (MB) | Idle CPU (ms/s) | Idle wakeups/s |
| --- | --- | --- | --- | --- | --- |
| Mecum | 108 | 132 | 241 | 9.6 (session open) | 2.2 |
| Cua | 127 | 35 | 122 | 0.01 | 0.2 |

Mecum's idle figure is with a session open. In this run its median footprint was about **3.8×** Cua's. That is a local resource tradeoff alongside the smaller response context; it is not a measure of total system energy.

WindowServer's baseline was 475 ms CPU per second with neither driver running, across two displays and the person's apps. Differences with an idle driver were within 5 ms/s, so the experiment could not isolate either driver's steady-state WindowServer cost.

### Read calls

These are median deltas per call. App CPU and energy belong to the target process and were read through `proc_pid_rusage`.

<details>
<summary>Read measurements by application</summary>

| Application | Driver | Driver CPU (ms) | App CPU (ms) | App energy (mJ) |
| --- | --- | --- | --- | --- |
| TextEdit | Mecum | 108 | 33 | 9 |
| TextEdit | Cua | 66 | 76 | 295 |
| Chrome | Mecum | 177 | 35 | 69 |
| Chrome | Cua | 121 | 140 | 754 |
| Obsidian | Mecum | 172 | 32 | 56 |
| Obsidian | Cua | 126 | 62 | 343 |
| Stocks | Cua | 122 | 62 | 265 |
| kitty | Mecum | 131 | 18 | 4 |
| kitty | Cua | 25 | 52 | 140 |
| Resolve | Mecum | 138 | 50 | 22 |
| Resolve | Cua | 185 | 295 | 1,359 |
| Prism Launcher | Mecum | 140 | 32 | 11 |
| Prism Launcher | Cua | 109 | 90 | 24 |
| Calculator | Mecum | 75 | 63 | 61 |
| Calculator | Cua | 45 | 62 | 181 |
| Safari | Mecum | 183 | 33 | 65 |
| Safari | Cua | 234 | 390 | 1,382 |

</details>

The target-app cost was larger for Cua on the measured web and Resolve reads. For example, Resolve used 295 ms of target CPU and 1,359 mJ with Cua, against 50 ms and 22 mJ with Mecum. These process deltas are not whole-Mac battery measurements.

### Action calls

<details>
<summary>Action measurements by application</summary>

| Application | Driver | Driver CPU (ms) | App CPU (ms) | Driver energy (mJ) |
| --- | --- | --- | --- | --- |
| TextEdit | Mecum | 234 | 80 | 720 |
| TextEdit | Cua | 43 | 24 | 38 |
| Chrome | Mecum | 367 | 93 | 1,079 |
| Chrome | Cua | 46 | 5 | 40 |
| Obsidian | Mecum | 382 | 103 | 1,187 |
| Obsidian | Cua | 36 | 11 | 42 |
| Stocks | Cua | 80 | 10 | 203 |
| kitty | Mecum | 288 | 36 | 941 |
| kitty | Cua | 62 | 3 | 105 |
| Resolve | Mecum | 292 | 158 | 918 |
| Resolve | Cua | — | — | — |
| Prism Launcher | Mecum | 272 | 109 | 830 |
| Prism Launcher | Cua | — | — | — |
| Calculator | Mecum | 165 | 151 | 611 |
| Calculator | Cua | 28 | 31 | 21 |
| Safari | Mecum | 337 | 89 | 1,017 |
| Safari | Cua | 8 | 78 | 24 |

</details>

Mecum performs OCR and two perceptions around an action, so its own CPU and energy cost was higher. The response already includes the scene after the action. CPU time is not wall time, so these values should not be added to the step latencies. The source headline CPU table also differs from the detailed action table in some rows; both are retained below, pending a check of the raw aggregation.


<details>
<summary>Driver CPU values in the source headline table</summary>

| Application / framework | Mecum CPU (ms/action) | Cua CPU (ms/action) |
| --- | --- | --- |
| AppKit (TextEdit) | 231 | 43 |
| Chromium (Chrome) | 364 | 46 |
| Electron (Obsidian) | 382 | 36 |
| Mac Catalyst (Stocks) | — | 80 |
| OpenGL/GLFW (kitty) | 288 | 72 |
| Qt + GPU (DaVinci Resolve) | 292 | — |
| Qt 6 (Prism Launcher) | 272 | — |
| SwiftUI (Calculator) | 165 | 28 |
| WebKit (Safari) | 255 | 15 |

TextEdit, Chrome, kitty and Safari contain differences from the detailed action table. Separate filters were not recorded for these two CPU summaries. Use the raw rows to reconcile their aggregation; the two summaries are shown separately here.

</details>

### Why the timings differ

Cua's default actions take about 1.1 seconds and scrolls about 1.6 seconds. Its post-action window watcher polls every 50 ms for up to 1,000 ms and holds a lease that restores the previous frontmost app. If no new window appears, the full second elapses. A second default Cua run reproduced the reported medians within 2%.

Mecum combines target perception, input delivery, a 300 ms click settle and a second perception. A perception takes roughly 350–550 ms; a menu command adds a further 400 ms wait. Unchanged reads still take 337–561 ms, despite their smaller responses.

Opening a Mecum session took a median 1.46 seconds, with an overall p95 of 2.0 seconds; Safari's application median was 2.317 seconds. Closing took about 0.69 seconds. The first open of the day took 30.7 seconds once. That cold path was neither reproduced nor investigated.

## Method

### Machine and builds

| Item | Configuration |
| --- | --- |
| Mac | MacBook Pro M4 base model; Mac16,1; 10 cores; 16 GB RAM |
| OS | macOS 27.0.1, build 26A434 |
| Displays | Built-in Retina and external 1080p display; Stage Manager off |
| Mecum source | `b2b5070`, unmodified working tree |
| Mecum server | Release `mecum-mcp-stdio`, using `AutomationTools` and `MCPRouter` through the CLI chat path and `AutomationSession` |
| Mecum toolchain | Swift 6.4; `xcrun swift build -c release` |
| Cua source | `trycua/cua` main at `4f33cd6b119c50b11d96d82d023722fc2edf1bc0`, committed 6 October 2026 |
| Cua toolchain | rustc 1.97.1; `cargo build --release -p cua-driver` |
| Cua mode | `cua-driver mcp --direct`; telemetry disabled; a session label on each call |
| Permissions | The same Accessibility, Screen Recording and PostEvent grants inherited from the launching process |
| Knowledge | A fresh Mecum knowledge directory per run |

The OS build was not in Mecum's Driver Ledger. The run used its research opt-in and did not qualify or promote that build. This is a driver experiment through the CLI path, not a test of the released Mecum app or its installer.

Cua's direct mode had no animated agent cursor because it lacked the certified AppKit main-thread host adapter. The installed daemon/proxy path adds a socket hop and was not measured here. On this OS, building Cua also required disabling release stripping to avoid dyld rejecting proc-macro dylibs; the build settings are listed below. Release, unstripped binary sizes were 9.7 MB for `mecum-mcp-stdio` and 36 MB for `cua-driver`.

### Targets and repetitions

Chrome used a separate profile and a local HTML fixture with a field, press-counter button, select and 200 rows. Safari used the same fixture in a dedicated window. TextEdit used a scratch document. Other targets were the apps' existing controls: Obsidian's quick switcher, Resolve's Project Manager view toggles and Prism Launcher's Meow toggle.

Each driver addressed equivalent targets: Mecum by label, Cua by the corresponding `element_token`, and the TextEdit caret click by window-local pixels.

For each app, the drivers ran separate blocks of **one warm-up and eight measured repetitions**, cycling through the operations. They never ran concurrently. Mecum opened and closed one session per block, then ran three extra open/close cycles. Warm-up calls are excluded from the headline results; the first session open is reported separately.

Latency is client wall time from request to reply, including JSON and pipe transport. Resource deltas are taken around the call. Independent probes and harness settles are outside that measurement window; each driver's own waits remain inside it. WindowServer CPU was read through `ps` at 10 ms resolution.

### Limits of this run

The experiment covers one machine on one day, a small operation set and eight measured repetitions per operation. The person occasionally used the Mac, adding noise to cursor and WindowServer observations. Application version numbers were not recorded in this report.

Token counts are approximate. Some action effects lack an independent oracle. Stocks did not open in Mecum, and Safari's accepted operation sets differ. The one 30.7-second cold open remains unexplained. No complete task with a real model was run, so the report does not establish task success rates, billed tokens, task cost or end-to-end speed.

## Reproduction

The data bundle for this report identifies:

- Raw rows: `CUAComparison20261006.jsonl`, recorded under `../measurements/` beside the original benchmark report.
- Harness and probes: `Tools/Driver/CUAComparison/`.

Those files must accompany the report for a full reproduction. They are not included in the Markdown document. The commands below assume the harness and both driver source checkouts are available.

Build Mecum's server and probes from the repository root:

```sh
cd Tools/Driver/CUAComparison
xcrun swift build -c release
xcrun swiftc -O probe.swift -o .build/probe
xcrun swiftc -O ocr.swift -o .build/ocr
```

Build Cua from its checkout at the commit above:

```sh
CARGO_PROFILE_RELEASE_STRIP=none \
CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none \
  cargo build --release -p cua-driver
```

Launch the target apps in the background. From the harness directory, start with the two-app example below; repeating the full matrix requires the remaining targets and equivalent starting windows.

```sh
MECUM_BENCH_SCRATCH="$(mktemp -d /tmp/mecum-cua-bench.XXXXXX)"
MECUM_APP_SUPPORT_DIR="$MECUM_BENCH_SCRATCH" python3 compare.py \
  --apps "Calculator,TextEdit" --drivers cua,mecum --reps 8 \
  --out results.jsonl --scratch "$MECUM_BENCH_SCRATCH"
python3 summarize.py results.jsonl
python3 headline.py results.jsonl
```

## What to measure next

| Test | What it would answer |
| --- | --- |
| Complete tasks with the same model and prompt | Task success, tool calls, actual input/output tokens, retries, wall time and billed cost |
| A sentinel window while the person types | Lost or leaked keystrokes, pointer interference and focus changes |
| Covered, minimized, hidden and multi-window targets | How each driver behaves outside the current window setup |
| Internal Mecum timing | Whether settle time or either perception can be reduced without weakening result checks |
| 1,000 actions per app | Memory growth, p99 latency drift and failure rates over time |
| Cold starts and AX enablement | Whether the first-open delay or initial Chromium/Electron reads are repeatable |
| More frameworks | Java Swing, Flutter, Tauri, JUCE plug-in windows and Adobe UXP |

arc-cua was not tested in this experiment. A three-driver comparison and a Memory benchmark remain separate work. Adobe UXP is also outside this run; see the [UXP Driver guide](../platforms/UXP.md) for its separate qualification work.

## Response payload details

The table separates transport reply size from estimated model context. Bytes in a JSON response are not tokens: screenshots may be encoded as image data, and clients decide which response fields they forward.

<details>
<summary>Response sizes by application</summary>

| Application | Mecum reply (bytes) | Mecum unchanged (bytes) | Cua reply (bytes) | Cua text (characters) | Cua image (px) | Cua structuredContent (bytes) |
| --- | --- | --- | --- | --- | --- | --- |
| Calculator | 2,076 | 269 | 126,467 | 14,701 | 230×408 | 52,728 |
| TextEdit | 1,712 | 543 | 242,617 | 23,259 | 656×422 | 70,248 |
| kitty | 703 | 273 | 89,292 | 12,130 | 1298×949 | 39,032 |
| Prism Launcher | 2,709 | 273 | 372,141 | 10,491 | 1568×1239 | 33,925 |
| Obsidian | 3,153 | 518 | 272,466 | 23,092 | 1567×1094 | 91,384 |
| Stocks | (refused) | — | 338,913 | 16,885 | 1568×1063 | 53,934 |
| Chrome | 4,131 | 269 | 442,677 | 49,810 | 1200×1006 | 248,646 |
| Resolve | 3,271 | 269 | 480,152 | 65,561 | 1568×1103 | 155,383 |
| Safari | 4,152 | 269 | 732,899 | 130,501 | 1088×949 | 425,319 |

</details>

## Per-operation latency

Each cell gives **median / p95 in milliseconds**, followed by **reported-done calls / attempts**. A dash is unavailable data or an unaccepted operation, not zero latency. The tables keep the recorded values, including calls with an unverified effect, except Cua Qt action metrics excluded under the support scope above.

<details>
<summary>TextEdit (AppKit)</summary>

| operation | mecum | cua |
|---|---|---|
| list_windows | 8 / 8 (1/1) | 9 / 9 (1/1) |
| open_session | 1,411 / 1,544 (4/4) | — |
| observe | 357 / 380 (8/8) | 294 / 308 (8/8) |
| observe_unchanged | 356 / 369 (8/8) | — |
| click | 365 / 381 (8/8) | 1,331 / 1,350 (8/8) |
| type | 1,242 / 1,267 (8/8) | 1,106 / 1,130 (8/8) |
| key | 1,066 / 1,109 (8/8) | 1,189 / 1,212 (8/8) |
| hotkey | 1,062 / 1,085 (8/8) | 1,118 / 1,140 (8/8) |
| scroll_down | 1,072 / 1,149 (8/8) | 1,623 / 1,679 (8/8) |
| scroll_up | 1,079 / 1,100 (8/8) | 1,599 / 1,640 (8/8) |
| menu | — / — (0/8) | 411 / 442 (8/8) |
| close_session | 666 / 918 (4/4) | — |

Mecum's TextEdit caret click (365 ms) is much faster than its other clicks. This
was not investigated.

</details>
<details>
<summary>Google Chrome (Chromium)</summary>

| operation | mecum | cua |
|---|---|---|
| list_windows | 24 / 24 (1/1) | 9 / 9 (1/1) |
| open_session | 1,503 / 1,890 (4/4) | — |
| observe | 445 / 477 (8/8) | 455 / 459 (8/8) |
| observe_unchanged | 418 / 434 (8/8) | — |
| click | 1,250 / 1,286 (8/8) | 1,105 / 1,138 (8/8) |
| type | 2,620 / 2,663 (8/8) | 1,700 / 1,732 (8/8) |
| key | 1,226 / 1,258 (8/8) | 1,110 / 1,131 (8/8) |
| hotkey | 1,191 / 1,202 (8/8) | 1,115 / 1,129 (8/8) |
| scroll_down | 1,221 / 1,296 (8/8) | 1,587 / 1,650 (8/8) |
| scroll_up | 1,228 / 1,255 (8/8) | 1,583 / 1,600 (8/8) |
| menu | — / — (0/8) | 419 / 447 (8/8) |
| close_session | 679 / 896 (4/4) | — |

</details>
<details>
<summary>Obsidian (Electron)</summary>

| operation | mecum | cua |
|---|---|---|
| list_windows | 16 / 16 (1/1) | 10 / 10 (1/1) |
| open_session | 1,370 / 1,557 (4/4) | — |
| observe | 460 / 502 (8/8) | 320 / 339 (8/8) |
| observe_unchanged | 470 / 500 (8/8) | — |
| click | 1,089 / 1,132 (8/8) | 1,113 / 1,121 (8/8) |
| type | 1,483 / 1,518 (8/8) | 1,371 / 1,380 (8/8) |
| key | 1,430 / 1,482 (8/8) | 1,107 / 1,131 (8/8) |
| key_close | 1,309 / 1,367 (8/8) | 1,106 / 1,124 (8/8) |
| hotkey | 1,316 / 1,394 (8/8) | 1,112 / 1,123 (8/8) |
| close_session | 568 / 617 (4/4) | — |

</details>
<details>
<summary>Stocks (Mac Catalyst)</summary>

| operation | mecum | cua |
|---|---|---|
| open_session | — / — (0/1, plus 1 in discovery) | — |
| observe | — | 321 / 353 (8/8) |
| key | — | 1,135 / 1,151 (8/8) |
| scroll_down | — | 1,657 / 1,668 (8/8) |
| scroll_up | — | 1,650 / 1,675 (8/8) |

</details>
<details>
<summary>kitty (OpenGL, GLFW)</summary>

| operation | mecum | cua |
|---|---|---|
| open_session | 1,417 / 1,475 (4/4) | — |
| observe | 405 / 449 (8/8) | 151 / 157 (8/8) |
| observe_unchanged | 394 / 420 (8/8) | — |
| type | 1,373 / 1,454 (8/8) | — / — (0/8) |
| key | 1,155 / 1,182 (8/8) | 1,180 / 1,191 (8/8) |
| hotkey | 1,154 / 1,202 (8/8) | 1,093 / 1,106 (8/8) |
| scroll_down | 1,152 / 1,193 (8/8) | 1,592 / 1,614 (8/8) |
| scroll_up | 1,170 / 1,184 (8/8) | 1,595 / 1,599 (8/8) |
| close_session | 708 / 776 (4/4) | — |

</details>
<details>
<summary>DaVinci Resolve (Qt with a GPU UI)</summary>

| operation | mecum | cua |
|---|---|---|
| open_session | 1,641 / 2,074 (4/4) | — |
| observe | 456 / 481 (8/8) | 618 / 664 (8/8) |
| observe_unchanged | 419 / 442 (8/8) | — |
| click | 1,281 / 1,342 (8/8) | — |
| click_back | 1,334 / 1,352 (8/8) | — |
| scroll_down | 1,257 / 1,283 (8/8) | — |
| scroll_up | 1,239 / 1,280 (8/8) | — |
| close_session | 685 / 928 (4/4) | — |

Cua action values are omitted because Qt background input is outside its declared support. Observation values remain shown.

</details>
<details>
<summary>Prism Launcher (Qt 6)</summary>

| operation | mecum | cua |
|---|---|---|
| open_session | 1,457 / 1,482 (4/4) | — |
| observe | 383 / 415 (8/8) | 342 / 363 (8/8) |
| observe_unchanged | 371 / 394 (8/8) | — |
| click | 1,157 / 1,175 (8/8) | — |
| key | 1,096 / 1,155 (8/8) | — |
| close_session | 718 / 953 (4/4) | — |

Cua action values are omitted because Qt background input is outside its declared support. Observation values remain shown.

</details>
<details>
<summary>Calculator (SwiftUI)</summary>

| operation | mecum | cua |
|---|---|---|
| open_session | 1,476 / 1,901 (4/4) | — |
| observe | 342 / 373 (8/8) | 231 / 351 (8/8) |
| observe_unchanged | 337 / 345 (8/8) | — |
| click | 1,095 / 1,127 (8/8) | 1,132 / 1,182 (8/8) |
| key | 1,047 / 1,065 (8/8) | 1,115 / 1,156 (8/8) |
| menu | 795 / 831 (8/8) | 476 / 514 (8/8) |
| close_session | 770 / 778 (4/4) | — |

</details>
<details>
<summary>Safari (WebKit)</summary>

| operation | mecum | cua |
|---|---|---|
| open_session | 2,317 / 2,542 (4/4) | — |
| observe | 552 / 615 (8/8) | 847 / 851 (8/8) |
| observe_unchanged | 561 / 614 (8/8) | — |
| click | 1,497 / 1,544 (8/8) | 1,108 / 1,118 (8/8) |
| type | 1,089 / 1,175 (8/8) | — / — (0/8) |
| key | 530 / 591 (8/8) | — / — (0/8) |
| hotkey | 526 / 562 (8/8) | — / — (0/8) |
| scroll_down | 1,423 / 1,466 (8/8) | — / — (0/8) |
| scroll_up | 1,403 / 1,473 (8/8) | — / — (0/8) |
| menu | — / — (0/8) | 441 / 474 (8/8) |
| menu_back | — / — (0/8) | 459 / 473 (8/8) |
| close_session | 1,546 / 1,571 (4/4) | — |

</details>
