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
active tool operation, releases the Seat and saves an interrupted entry.

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
It never starts another capture pipeline or Seat.

The internal bridge uses authenticated newline-framed JSON on an ephemeral
127.0.0.1 port. It is not a public Streamable HTTP endpoint. The external provider
interface is standard MCP over stdio. A private temporary file carries the
connection credential, and is removed at shutdown.

Only one CLI chat host per user runs at a time, even with different transcript
directories. Within that host, concurrent tool effects are refused rather than
interleaved. The first version controls one application session at a time.
A provider process disconnect between turns does not release the Seat.

## Tools and results

`status`, `windows`, `open_session`, `observe`, `act`, `select`,
`batch`, `close_session`.

Action tools require the ephemeral session ID returned by open_session.
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

Typing, scrolling, keyboard shortcuts and menu-bar navigation are not yet in this
chat surface. There is no foreground fallback. Multi-app concurrent control,
remote ChatGPT connections, and a shipping application host are separate work.

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

Normal chat sends the user's prompts and Mecum's textual tool results to the
selected provider. Screenshots are not sent by this interface. Provider sign-in
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
conversation or automatic replay. After restarting Mecum, old Seat IDs are invalid.

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
session resumption with a remembered test phrase. They do not prove a live
Pro Tools or Premiere workflow through the model.
