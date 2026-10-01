# CLI chat

Mecum can use the installed, signed-in Claude Code or Codex CLI as its reasoning
provider. The provider calls Mecum through MCP; perception and input stay in the
Mecum process. This does not connect to or import conversations from the ChatGPT
website.

## Use

```sh
.build/debug/mecum --chat --allow-unvalidated-build
```

Choose a saved conversation or a new one, then choose the provider and model.
Claude offers its default plus Sonnet/Opus aliases and custom model names.
Codex offers its default plus visible models from its local model cache and custom
model names. The provider validates availability; a cache entry is not a guarantee.

A quoted prompt starts the conversation immediately:

```sh
.build/debug/mecum --chat "Inspect Pro Tools and tell me which window is open" \
  --provider claude --model sonnet --allow-unvalidated-build
```

In an interactive terminal this continues as a chat. For one turn and exit:

```sh
.build/debug/mecum --chat "Inspect Pro Tools without changing anything" \
  --provider codex --once --allow-unvalidated-build
```

Saved conversations:

```sh
.build/debug/mecum --chat --list
.build/debug/mecum --chat --resume last --allow-unvalidated-build
.build/debug/mecum --chat --resume <conversation-UUID> --allow-unvalidated-build
```

Inside chat: `/model`, `/status`, `/release`, `/help`, `/quit`.
Ctrl+C or SIGTERM stops further tool calls, cancels the provider, drains the
active tool operation, releases the Seat and browser connection, and saves an interrupted entry.

CLI chat and app workers stop after three unsuccessful tool attempts without a verified
result. Observing, switching targets, or reopening the session does not reset this budget.
A verified action (including an explicit toggle already at its requested value) resets it;
a new user message starts a new budget. The host stops its provider, drains active work,
and releases the session. The stop is reported as a failure and cannot teach a successful
memory. Read-only inspection and release remain available at the tool boundary.

The explicit research flag is still required on a macOS build not validated by
the Driver ledger. It is never inferred from a prior chat or silently enabled.
Likewise, `--allow-destructive` belongs to this invocation, not the saved model context.

## Architecture

- **ChatCore:** provider/turn/event/conversation values. No process, MCP, storage,
  AppKit, perception or Driver dependency.
- **CLIProviders:** argv construction, Claude/Codex JSONL decoding, streaming
  child process ownership and cancellation. No shell command interpolation.
- **FileConversations:** private atomic transcripts and exclusive conversation leases.
- **LocalMCP:** JSON-RPC stdio bridge, authenticated ephemeral loopback host and
  serialized tool router. No application behavior.
- **AutomationRuntime:** the shared engine composition and persistent Seat session.
  Ordinary CLI actions and chat use the same EngineRuntime.
- **AutomationMCP:** validation, tool schemas and result formatting over
  AutomationSession. No provider, terminal or conversation-store dependency.
- **CLI composition:** menus, signals, paths, explicit policy flags and the event
  wiring between modules.

The chat process owns one host. Each provider turn may launch a fresh
`mecum mcp-bridge` process, which only forwards MCP messages to that existing host.
It never starts another capture pipeline or Seat. The app launches the same bridge
from `mecum-bridge`, a helper that holds only the bridge and depends on LocalMCP
alone, so the app does not carry the whole command line.

The internal bridge uses authenticated newline-framed JSON on an ephemeral
127.0.0.1 port. It is not a public Streamable HTTP endpoint. The external provider
interface is standard MCP over stdio. A private temporary file carries the
connection credential, and is removed at shutdown.

Only one CLI chat host per user runs at a time, even with different transcript
directories. Within that host, concurrent tool effects are refused rather than
interleaved. The first version controls one application session at a time.
A provider process disconnect between turns does not release the Seat.

## Tools and results

`status`, `windows`, `apps`, `open_session`, `observe`, `act`, `select`,
`type_text`, `press_key`, `scroll`, `drag`, `context_menu`, `menus`, `resolve_action`,
`menu`, `batch`, `close_session`.

These native tools use the closed `AutomationTool` vocabulary. The same registry also exposes
[`browser_*` tools](Browser.md) for Chrome page content. Unknown tool names are refused before
any effect. Native actions require the ephemeral session ID returned by `open_session`;
browser actions use a separate connection, tab and current snapshot reference.
A target copied from a scene line, such as `Mute {Track 2}` or `stile = Regolare`, is read back once
at the tool boundary (`SceneTargetReference`): the label is what is resolved and recorded, and the
container in braces becomes the section when the call gives none. Reading stops at a label the last
observation showed, so a real label that holds a mark, such as `x = y`, is acted on whole. The turn's
event records the call as it was executed, and admission compares it with what the evidence observed,
never with a copy of it. The system instructions carry no label, panel or application from any run.
Observations carry a revision, capture report time, and the current text scene.
The existing engine observes afresh before acting; saved observations are not
coordinates or authority for later input.

Batch validates all steps before starting, executes at most 20 act/select steps,
and stops on the first failed/ambiguous/unverified result. Earlier effects remain.
A verified toggle already in its desired state may continue. No action is
automatically replayed after a provider failure.

The host follows new application windows using the Driver's existing window
tracking. Dropdown selection uses the same native/custom dropdown selector as
the terminal command. Tool results preserve the Engine's outcome vocabulary,
including honest_miss, ambiguous and acted_unverified.

[Native application menus](ApplicationMenus.md) use a separate exact-path tool, with
fresh availability checks and verified new-window effects. `resolve_action` keeps ambiguous
UI and menu routes explicit. There is no foreground fallback. Shortcuts normally handled by
the menu bar are not a substitute for the native menu tool. Remote ChatGPT connections remain
separate from the local signed-in CLI providers.

## Permissions and provider access

Run from the terminal that has the necessary macOS permissions. This CLI phase
does not solve the signed application identity/deployment work. Opening a Seat
checks Screen Recording, Accessibility and posting access without prompting.
Missing access is reported; the model cannot grant it.

Claude runs with built-in tools disabled, strict MCP configuration and only
Mecum tools allowed. Codex ignores user MCP configuration, disables shell, browser,
computer-use and image tools,
uses a read-only sandbox, and explicitly authorizes the Mecum server's tools.
Neither adapter uses a global permission/sandbox bypass. Managed provider policies
can still refuse a request.

Normal chat sends the user's prompts and Mecum's requested tool results to the
selected provider. Browser tools can return page text and screenshots through MCP;
local tool summaries omit full page content and typed field values. Provider sign-in
credentials remain with the provider CLI.

## Persistence

Default transcripts:
`~/Library/Application Support/Mecum/Conversations/<UUID>.json`

Use `--history-dir` to override transcript storage. A transcript includes provider,
model, native provider session ID, user messages, assistant text, tool requests and
results, and interruptions/errors. Connection credentials are excluded. Files are
private (0600) under a private directory (0700), and updates replace files atomically.

Provider-native conversation history supplies actual continuation context.
The local transcript is an inspectable record, not a fabricated replacement for a
missing provider session. A failed resume is reported; there is no silent fresh
conversation or automatic replay. After restarting Mecum, old Seat and browser connection IDs
are invalid. Browser snapshots and element references also expire after actions or a new snapshot.

## Living memory in the app

The CLI and desktop workers use the same turn admission, recall and recording cycle.
See [worker memory](WorkerMemory.md) for ownership, failure behavior and verification.

## Verification

Local tests cover provider argv/stream parsing, complete-vs-truncated responses,
concurrent pipe draining, process cancellation, MCP authentication/reconnection,
serialized calls and draining, transcript round trips/locks, and CLI parsing.

Real signed-in provider tests are opt-in and return only invented MCP data.
They do not enumerate or capture real apps:

```sh
MECUM_SYNTHETIC_PROVIDER_TESTS=1 \
MECUM_TEST_BRIDGE="$PWD/.build/debug/mecum" \
swift test --filter SyntheticProviderTests
```

These checks verify two provider turns, real MCP tool calls and exact native
session resumption with a remembered test phrase. With temporary SQLite stores,
they also exercise learning and recall in new provider conversations for select,
set_toggle, click, double_click and right_click. The action fixture supplies
invented typed evidence: separate Engine tests verify its production generation.
The provider checks include non-use of toggle memory in another app or window,
for missing or ambiguous targets, and when the record is unreliable. They do
not prove a live Pro Tools or Premiere workflow through the model.

### Context budget

Codex turns request automatic compaction at 64,000 tokens, including resumed CLI conversations.
The app also asks CLI providers to compact after a completed turn at 64,000 tokens or 90% of
the known context window, whichever comes first. Failed or stopped turns do not trigger this
step. Provider compaction replaces model context with a summary; it does not delete visible
chat messages. Manual compaction remains available. Direct model transports retain their
existing bounded history behavior.

## External local clients

The macOS app can expose its existing engine to local MCP clients. See
[Local MCP connections](LocalMCP.md) for setup, capabilities, task boundaries and cleanup.
