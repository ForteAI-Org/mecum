# Browser automation

Mecum can drive Chrome page content through a native Swift connection. It uses the browser's
semantic accessibility tree and DOM references, not screenshots interpreted as coordinates.
It does not require Seat, macOS Accessibility, or Screen Recording permission.

The reusable engine is available in the Mecum app, `mecum --chat`, a JSONL CLI and an MCP
stdio server. App workers expose it through both the Claude/Codex MCP bridge and the direct
model tool loop. Safari is not implemented.

## Connect without copying browser data

Two modes use the same engine and tools:

- `current` attaches to the normal Chrome session and uses its existing authenticated tabs.
  Chrome 144 or newer is required. In that Chrome instance, open
  `chrome://inspect/#remote-debugging`, enable remote debugging, and approve the connection
  prompt when Mecum connects. Mecum reads the `DevToolsActivePort` discovery file only.
  It does not read, copy or decrypt the browser's cookie database or keychain.
- `automation` opens or connects to a separate persistent Chrome profile at
  `~/Library/Application Support/Mecum/Browser/Chrome`. Sign into sites in this profile once.
  Subsequent connections reuse the same directory. Login expiration still follows the site's
  policy. This is a separate profile, not a clone or a symlink to the user's profile.

`browser_disconnect` and normal CLI exit release debugging but leave Chrome running and
leave its data intact. There is no automatic reconnect or action replay after a failure.
A stale discovery endpoint produces an error; reopen that Chrome profile before reconnecting.
Neither mode changes Chrome's remote-debugging settings automatically.

The engine intentionally avoids the old Locator profile-copy route. Ordinary debugging flags
cannot enable the default Chrome profile on current Chrome versions. Chrome's user-authorized
current-session connection is a separate supported mechanism.

Sources: [Chrome current-session connection](https://developer.chrome.com/blog/chrome-devtools-mcp-debug-your-browser-session),
[debugging-port profile restrictions](https://developer.chrome.com/blog/remote-debugging-port).

## Use from the app or chat

The chat registry includes both browser and native desktop tools. Its instructions choose
`browser_*` for web page content and native tools for menus, browser chrome or OS panels.
Browser operations do not open a Seat or require a native desktop permission preflight.
Missing Chrome consent is reported; it never silently switches to a separate profile.

For an initial read-only check, send:

> Connect to my existing Chrome using the current profile. List its tabs and stop.

Or, to test a separate persistent profile:

> Use the automation Chrome profile. Open about:blank, observe it and stop.

A connection survives successful messages in the same chat. Ask the agent to disconnect it
when finished. Stopping a running turn, a failed turn, closing a worker or exiting CLI chat
releases the connection. CLI `/release` releases both the native session and browser.
Disconnecting leaves Chrome and its profile data intact.

Within one app workspace, a profile can belong to only one chat at a time. Another chat gets
an explicit busy result until the owner disconnects. Current and automation profiles may be
used independently. This coordination does not lock other Mecum instances or human input.

Claude/Codex MCP providers can receive browser screenshots. The app's direct model transport
currently carries text only, so it exposes the other 20 browser tools and does not advertise
`browser_screenshot`. A screenshot request there fails explicitly rather than returning an
empty result. Semantic page snapshots work in both routes.

## Run the CLI

Build using the repository's Swift 6.4 toolchain:

```sh
swift build --product mecum
.build/debug/mecum browser
```

This keeps one connection alive and reads one JSON object per line. Output is MCP-shaped JSON,
with ordinary data in `structuredContent` and screenshots in `content`. Diagnostics go to stderr.
Use IDs returned by this running process, never IDs saved in an earlier conversation.

First enter one of:

```json
{"tool":"browser_connect","arguments":{"profile":"current"}}
```

```json
{"tool":"browser_connect","arguments":{"profile":"automation"}}
```

Copy the returned `id` into `connection`. Read the tabs, then copy the intended tab's `id`.
The tool host exposes short references such as `t1` for tabs and `s2` for observations, hiding
Chrome's transport IDs. They belong to the exact connection returned by this running host;
unknown, consumed, cross-tab and disconnected references are refused before input. There is
no fuzzy ID matching or fallback to the active tab. Library `BrowserControlling` IDs remain
adapter-owned and are not interchangeable with these tool references:


```json
{"tool":"browser_tabs","arguments":{"connection":"CONNECTION_ID"}}
{"tool":"browser_snapshot","arguments":{"connection":"CONNECTION_ID","tab":"TAB_ID"}}
```

A snapshot returns an `id`, semantic nodes with `ref`, and explicit coverage limitations.
Use both the snapshot ID and an element reference for an action:

```json
{"tool":"browser_fill","arguments":{"connection":"CONNECTION_ID","tab":"TAB_ID","snapshot":"SNAPSHOT_ID","ref":"e5","text":"Example"}}
```

Actions and `browser_open` now include a fresh `observation` in their result. Use its `id` and
`nodes[].ref` directly for the next action; a separate `browser_snapshot` is only needed when the
required content is absent, still loading, or the automatic reading failed. An action consumes
its input references, and the returned observation replaces them. Navigation or changed element
semantics also makes references stale.

An automatic observation is a point-in-time reading, not a promise that network requests or
asynchronous page updates have settled. `delivered` stays `delivered`; the caller must inspect
the new state before claiming task completion. If the reading fails, `observationError` is
returned beside the original action receipt. The action is never replayed to obtain a reading.

### Compact and focused readings

`browser_snapshot` accepts optional `scope`, `query`, and `limit`:

- `auto` (default): read one unambiguous dialog when present, otherwise the page.
- `page`: include page controls and text beyond any focused dialog.
- `dialog`: require one unambiguous dialog; fail rather than choose between several.
- `content`: read article summaries and their links/headings; without articles, read main text
  and links. This view omits unrelated controls.

`query` narrows by a case-insensitive label match, including matching subtrees and their context.
The node limit defaults to 120 and may be raised to 400. Selection happens before truncation, so
a dialog after hundreds of background nodes remains readable. Every filtered or truncated view
reports its coverage limitations. Equal text is removed only under its owning named control,
heading or article; separate controls with the same label remain distinct.

```json
{"tool":"browser_snapshot","arguments":{"connection":"CONNECTION_ID","tab":"TAB_ID","scope":"content","limit":200}}
```

Actions accept the same settings in an optional `observation` object to choose the resulting
reading. The defaults are evaluated again after every action, so closing a dialog returns to
the page automatically. Read options do not persist implicitly between calls.

```json
{"tool":"browser_click","arguments":{"connection":"CONNECTION_ID","tab":"TAB_ID","snapshot":"SNAPSHOT_ID","ref":"e5","observation":{"scope":"dialog"}}}
```

The MCP text view uses one metadata JSON line followed by compact node rows. Action receipts
separate the new observation with `observation:`. `structuredContent` remains ordinary JSON for
programmatic clients. Read one representation, not both, to avoid repeating the same page in the
model context. Both views retain node references, roles, labels, nonempty states and parent references.
Adapter frame IDs and empty fields stay out of the model response. The engine still owns frame
and document identity and checks them before acting.

End with `browser_disconnect` or EOF (Control-D). For a dedicated development/test profile,
use `.build/debug/mecum browser --automation-profile /absolute/separate/profile/path`.
That argument affects only `automation`; it does not change current-profile discovery.

### Collect several articles in one call

For feeds expressed as HTML articles, `browser_collect` reads text and scrolls within a budget:

```json
{"tool":"browser_collect","arguments":{"connection":"CONNECTION_ID","tab":"TAB_ID","count":30,"maxScrolls":12}}
```

It accepts 1 to 50 articles and 0 to 20 scrolls, and stops at 64 KiB of text. Each article is
limited to 6,000 characters with an explicit truncation flag. It reads at most the first 100
rendered top-level articles in the main document. Permalinks or HTML IDs identify items; when
neither is available, equal text is deduplicated but `identityUncertain` prevents a claim that
the requested number of distinct articles was established. Sites that recycle IDs may need a
more specific adapter. Images, videos and embedded frames are not interpreted.

The operation directly scrolls the main document, so it is not a passive reading. It does not
activate a tab or synthesize a trusted wheel event. Nested scrolling containers and sites that
load content only from wheel handlers may stop with no progress. Scrolling enables the renderer
focus emulation described below. Initial reads can still precede asynchronous loading; no progress
or endOfPage describes the observed state, not feed completeness. It follows no links and clicks
no controls. It polls briefly after scrolling, without asking the model for each step. Inspect
`stopReason`, item truncation flags and `limitations`: navigation, no progress, a budget limit,
cancellation or a failed scroll preserve partial results and never trigger input replay.
`countReached` establishes a count of identified article elements, not complete understanding
of their content. Arbitrary page layouts without article semantics need ordinary snapshots.

## Use as an MCP server

Point any standard MCP client at the compiled binary. Example server configuration:

```json
{
  "mcpServers": {
    "mecum-browser": {
      "command": "/absolute/path/to/mecum/.build/debug/mecum",
      "args": ["browser", "--mcp"]
    }
  }
}
```

The model first calls `browser_connect`, selects an explicit tab, then observes it.
The server advertises these tools:

| Purpose | Tools |
| --- | --- |
| Connection | `browser_status`, `browser_connect`, `browser_disconnect` |
| Tabs | `browser_tabs`, `browser_open`, `browser_close` |
| Reading | `browser_snapshot`, `browser_screenshot`, `browser_dialog`, `browser_collect` |
| Controls | `browser_click`, `browser_fill`, `browser_select`, `browser_set_checked` |
| Input | `browser_key`, `browser_scroll` |
| Navigation | `browser_navigate`, `browser_back`, `browser_forward`, `browser_reload` |
| JavaScript dialogs | `browser_handle_dialog` |

`browser_status` reports host metadata, not a fresh connectivity check. `browser_connect` on
an existing connection checks the transport. Standard MCP errors instruct the caller to observe
before considering another action; direct engine errors also preserve `effectsPossible`.

## Engine boundaries and ownership

`MecumBrowser` exports three modules:

- `BrowserCore`: Sendable values, explicit outcomes and the `BrowserControlling` role. It has no
  CDP, MCP, AppKit, Driver, memory or provider dependency.
- `ChromeBrowser`: the native adapter. It owns one persistent WebSocket and attached target
  sessions. Calls are bounded, correlated by request ID and never automatically replayed.
- `BrowserMCP`: validation and presentation over an injected `BrowserControlling`. No Chrome
  construction occurs in this module, so a future Safari adapter can fill the same role.

The standalone browser CLI composes these objects in `BrowserCommand`:

```swift
import BrowserMCP
import ChromeBrowser
import LocalMCP

let browser = ChromeBrowser(configuration: .standard())
let tools = BrowserTools(browser: browser)
let router = MCPRouter(
    tools: BrowserTools.definitions,
    instructions: BrowserTools.instructions
) { name, arguments in
    try await tools.call(name, arguments)
}

// At host shutdown, after stopping the provider:
router.pause()
await router.drain()
try await tools.shutdown()
```

`AutomationTools` combines this registry with desktop tools for the app and CLI chat.
`TeamModel` owns a `BrowserSessionPool` and injects one client per `WorkerAgentHost`. The pool
holds profile ownership until disconnect succeeds; a failed first connection releases ownership.
The host drains calls before releasing its controller, including after cancellation. A single
controller rejects overlapping operations rather than interleaving them.

Different processes are not covered by the pool. Human interaction and other debugging clients
are not suspended. Document/element preflight reduces stale actions, but cannot make the
browser and input delivery one atomic transaction. Browser failures have no automatic desktop
fallback, reconnect or action replay.

Browser calls use the shared failure budget, but their events remain outside native desktop
`ActEvidence`. They cannot teach a successful desktop memory step. Browser-specific evidence
and admission remain future work. Local tool summaries omit page bodies, screenshots, typed
field values and URLs; the selected provider still receives the requested tool results.

## Outcomes and current limits

`verified` confirms a narrow state: field text equals the requested text, a native select holds
the selected option, or a checkbox/radio has the requested checked state. `delivered` confirms
input delivery only. Click, keyboard, scroll and navigation require inspecting their returned observation to establish
the user's intended outcome. `unverified` means the action occurred but its postcondition could
not be established. Transport failures may also have partial effects.

An AX `StaticText` reference may identify a DOM Text node. Clicking it uses its visible text
rectangles and checks the hit target, including disabled/inert ancestors and disabled native
labels. It does not click the center of a larger enclosing container. Wrapped text can use a
visible line. Text values nested inside fields are omitted as independent targets; an autocomplete
selection must use an actual option after it appears, not the text just typed into the field.
Named keys are case-insensitive, with conventional aliases such as `down`, `esc` and `return`.

The adapter refuses hidden, detached, disabled or covered click targets, checks observed role
and name before node actions, and binds references to frame/document identity. Native input
uses CDP rather than the system cursor. Before input or collection scrolling, the adapter enables
CDP focus emulation on its attached session. Chrome then presents the document as active and
focused to page scripts while the physically selected tab and system focus remain unchanged.
The override remains until that session detaches, including on disconnect; read-only snapshots
do not enable it. Sites can react to these visibility/focus changes. This prevents background
renderers from silently ignoring input, but a delivered receipt still needs outcome verification.

Select uses DOM value assignment and input/change events;
it is not a trusted physical selection event, which some applications require.

Supported reading includes Chrome accessibility nodes, open Shadow DOM and same-process
iframes. Click coordinates are checked through frame ancestry. Readings default to 120 nodes, allow at most 400,
and cap each label at 512 characters; truncation and unreadable frames are reported. Editable
field values are omitted from snapshots, including password fields. Page labels and screenshots
can still contain private content and should only be requested for the user's task.

Current limitations are explicit:

- A focused dialog view follows its AX subtree. Embedded frame documents may require `scope: page`.

- Out-of-process/cross-origin frames may be omitted; there is no separate target adapter for them.
- Canvas controls and content absent from Chrome's semantic tree have no element reference.
- Native browser chrome, OS file pickers, upload/download management, arbitrary JavaScript,
  network interception, console history and extensions are not exposed.
- HTML select and checkbox/radio operations do not pretend to support custom web widgets.
  Use click, observe and click on a custom dropdown.
- Dialog events are known only after attachment. A modal already open before attachment may
  require the user to dismiss it. A dialog opening during input is reported immediately so the
  agent can answer it instead of waiting indefinitely for Chrome's blocked command response.
- Safari's regular browsing session needs a separate adapter. Safari WebDriver's isolated
  automation session is not interchangeable with the user's logged-in Safari profile.

## Verify changes

The normal repository baseline includes `BrowserTests`:

```sh
swift build --product mecum
make test SWIFT=swift
git diff --check
```

Run the live synthetic adapter checks separately, with Chrome installed and Python 3 plus
`websockets` available in the test environment:

```sh
python3 Scripts/browser-smoke.py --artifacts /tmp/mecum-browser-smoke
```

This launches a temporary headless Chrome profile, serves only synthetic loopback pages, drives
Mecum's actual JSONL engine, captures a PNG, and tests persistence across a graceful browser
restart. It neither opens the user's profile nor sends data to a model provider. Its independent
WebSocket dependency observes background focus state and closes its own test Chrome gracefully; the Mecum engine
has no Node, Puppeteer, Playwright or third-party WebSocket runtime dependency.

App coverage lives in `WorkerBrowserTests` (deterministic adapters) and
`WorkerBrowserLiveTests` (opt-in real Chrome). The live suite uses a local scripted model
transport; no provider account is contacted. Set `MECUM_BROWSER_APP_LIVE_TESTS=1` and
`MECUM_BROWSER_APP_FIXTURE` to an owned directory under `/private/tmp/`, containing a
`chrome-headless` executable wrapper that launches Chrome with `--headless=new`, and
`fixture.html` with a button named `Run` that changes its text to `Done` on click, plus five
`article` elements with unique IDs and nonempty text. The suite
creates its own `profile` and `worker` subdirectories. With Xcode, pass these variables with
the `TEST_RUNNER_` prefix. Close only this test profile after the run; disconnect intentionally
leaves it running.

The current-session consent flow needs a separate manual/live check in ordinary Chrome. Passing
the headless test does not establish that a user's debugging setting or consent is enabled.

The app records an automation stop's own explanation, including the last failed tool, ahead
of the provider interruption it caused. A stopped turn remains a failure; no action is replayed.

The opt-in `WorkerBrowserProviderLiveTests` suite uses the app's signed-in Codex provider with
only an owned synthetic form. Set `MECUM_BROWSER_PROVIDER_LIVE_TESTS=1`, the same
`MECUM_BROWSER_APP_FIXTURE` directory, and `MECUM_TEST_BRIDGE` to the built CLI (all with
`TEST_RUNNER_` when running Xcode tests). Copy `Scripts/Fixtures/browser-journey.html` as
`journey.html` into that directory. Each run uses a fresh provider Chrome profile; close the
owned headless profiles after testing. This sends synthetic page content to the selected provider. The test independently checks all
requested values and exactly one search submission. Recoverable argument/reference/native-select
refusals are reported; a failed turn or unexpected transport/protocol error fails the test.
The deterministic live fixture also needs a `Solo andata` StaticText target whose click replaces
its text with `One way selected`.
