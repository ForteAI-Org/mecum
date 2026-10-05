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

Inside chat: `/model`, `/status`, `/usage`, `/compact`, `/release`, `/help`, `/quit`.
`/status` prints the status tool's answer and keeps its call and result in the transcript,
as a turn's tool records are kept.

What a turn cost is printed after it and kept as one `usage:` line in the transcript, as
the turn core reported it (the provider's own count is not repeated): the turn's own tokens,
the session total when the provider counts one (Codex), the context it left against the
model's window, and the account's limits; a value the provider did not report is `unknown`,
never 0. A Codex turn's own count is its session total less the one before in this chat; the
first turn of a resumed Codex session has no count before it, so its own count is said to be
unknown rather than shown as the whole session's. `/usage` repeats the last one and sums the
known own counts of this chat. `/compact` compacts the provider session's context with the
app's compaction (Claude Code's `/compact`, Codex's compaction turn): no tool, no Seat, the
conversation's model and the invocation's effort and role; its outcome is a `compaction:`
line, and one that did not compact is an error, with nothing invented. Usage is kept in this
chat process only: a saved conversation keeps the lines but not the counts, and Mecum adds no
automatic compaction to the chat.

A turn is configured as a worker's is in the app, with three options that belong
to the invocation and not to the saved conversation, so a chat resumed with
`--resume` is given them again:

```sh
.build/debug/mecum --chat "Trim the first clip" --provider claude --model claude-opus-5 \
  --role "You edit video in DaVinci Resolve. Answer in one sentence." \
  --effort high --web-search --allow-unvalidated-build
```

`--role <text>` is the agent's role, added after Mecum's instructions as a worker's
is (its text is trimmed, never rewritten). `--effort <low|medium|high|xhigh|max|ultra|default>`
is the reasoning effort; without it, or with `default`, the command line's own
effort stands. A level the command line does not offer for the model (Haiku takes
none, `ultra` is Codex's) is refused before the first turn, with the levels it
does offer, and said again when `/model` changes the model under it; with the
provider's default model only the known contract is checked, and the command line
has the last word. `--web-search` lets the command line search the web and read
pages with its own tools, as a worker may; off, the command line stays offline.
Model and effort left unset reach the provider as its defaults, never as a chosen value.

The chat drives applications through the same broker session as the Mecum app.
`open_session` opens an installed application that is not running (the `apps`
tool lists them) as well as a running one; the broker records that it launched
it and quits it when the session ends, and leaves an application that was already
running. The Seat stays open across turns, and is given back 30 s after a turn
with no next turn, as in the app; `/release` gives it back at once. Either way
the next turn opens a session again, through the same broker.

Ctrl+C or SIGTERM stops further tool calls and interrupts the provider, then
drains the active tool operation, closes the desktop session (the window goes
home, a launched application is quit, the seat is given back), waits for the
provider process, saves an interrupted entry, takes the broker's parked seats
down and removes the temporary configuration, and exits with status 130 once
that is done.

`--diagnose-select <directory>` is a developer's diagnosis of `select`, off by default and
set only by this option (the app never sets it). For every `select` of the session the
broker's session hands the selector's own `onCapture` and `onMenu` to `SelectionDiagnostics`,
which writes, under `<directory>/<call event id>/`, the images the selector perceived
(`before.png`, `menu.png`, `after.png`, only those it took) and `diagnosis.json`: the call,
the windows, the outcome, the typed reason a selection did not happen (`SelectionMiss`:
control not resolved, item not resolved, no route with the reason of the named and of the
painted rows, menu not read, selection not requested), the opener's label, the menu's
labels, the rows the application named and the rows the pixels painted, and the route. A
step that did not run is written as not run; nothing is captured again or reconstructed. A
file it cannot write is said in the diagnosis or on standard error and changes nothing the
selection answers. The images are pictures of the driven application's windows: name a
temporary directory, for example under `/private/tmp`. Nothing goes to the memory or to a
tool's arguments, and the outcome's sentence is unchanged.

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
- **AutomationRuntime:** the shared engine composition (`EngineRuntime`) and the
  session role the tools consume, `AutomationSessionOperating`. Ordinary CLI
  actions and chat use the same EngineRuntime. `AutomationSession`, the direct
  conformer that adopts a running application's window itself, is no longer the
  chat's session and has no production consumer left; it stays for the record
  until the vertical commands are aligned.
- **AutomationMCP:** validation, tool schemas and result formatting over
  `AutomationSessionOperating`: the 14 tools the app's worker and the chat share.
  No provider, terminal or conversation-store dependency.
- **SeatBroker:** the chat's desktop, the app's one. `ChatCommand` owns one
  `SeatBroker` for the process and one `BrokeredAutomationSession` for the chat,
  which waits in the broker's queue under a worker id stable for the chat, opens
  an application through `AgentSession.open` (launching an installed one that is
  not running, with its provenance recorded) and lends a Seat target to
  `EngineRuntime`, so scenes, engine and Brain are the command line's. The
  research opt-in for an unvalidated macOS build is the broker's configuration.
- **AgentTurn:** the one turn of an agent over a desktop session, run the same
  way by the app's worker and by this chat. `AgentTurnHost` owns the tools over
  the session its composer supplies, the router, the loopback host, the connection
  file (0600, in a 0700 temporary directory) and the provider child, or Mecum's
  own loop over a model transport for the app's model providers, and reports the
  turn's events in order (`AgentTurnEvent`: the provider's events, each tool
  record, the child's identity and what the turn cost). It composes the
  instructions both entries run with, the turn as the provider receives it (the
  model and effort when chosen, the child's environment through the Codex
  allow-list, the Codex reminder when a resumed session began with other
  instructions), the stop and the cleanup. What each entry does with the events
  stays with the entry: the app's recorder and workspace, the chat's transcript.
- **CLI composition:** menus, signals, paths, explicit policy flags and the event
  wiring between modules. `ChatHost` owns the broker session for the chat, the
  transcript and one `AgentTurnHost` over that session, and runs every turn
  inside the session's `turn`, so nothing is released between an observation and
  an act. The chat's turn names the conversation's command line and model and the
  invocation's role, effort and web search; the command line's defaults stand
  where nothing was chosen, and an effort it does not take is refused before the
  turn. `/status` between turns goes through the core's `inspect`, which lends the
  turn's one receiver to the call so its records reach the transcript.

The chat process owns one host. Each provider turn may launch a fresh
`mecum mcp-bridge` process, which only forwards MCP messages to that existing host.
It never starts another capture pipeline or Seat. The app launches the same bridge
from `mecum-bridge`, a helper that holds only the bridge and depends on LocalMCP
alone, so the app does not carry the whole command line.

The chat's Seat is the broker's. A session closed by `/release`, by a failed turn
or by the idle window gives its seat back to the broker's queue, which keeps it
warm until the chat ends; then the queue is shut down and the virtual display
taken down, after the turn core has closed. The same code in the
app and in the chat is not one queue across processes: an app and a chat running
at once are two brokers, and the Driver's own rules on the desktop apply. The
instructions a turn runs with are the turn core's (`AgentTurnHost.instructions`):
the tools' base text and the broker session's line
(`BrokeredAutomationSession.openingInstructions`) in both entries; the app's
worker adds its role and, when allowed, the web line after them, the chat adds
nothing. The provider child runs with the inherited environment through the same
allow-list as the app's worker (launch, login and proxy settings; no API key or
alternate endpoint), and a Codex conversation this chat never ran before is told
its instructions once more on its first resumed turn, as a worker's is.

The internal bridge uses authenticated newline-framed JSON on an ephemeral
127.0.0.1 port. It is not a public Streamable HTTP endpoint. The external provider
interface is standard MCP over stdio. A private temporary file carries the
connection credential, and is removed at shutdown.

Only one CLI chat host per user runs at a time, even with different transcript
directories. Within that host, concurrent tool effects are refused rather than
interleaved. The first version controls one application session at a time.
A provider process disconnect between turns does not release the Seat.

## Configuring a turn: the app and the chat

Both entries run the one turn core (`AgentTurnHost`) with the values below. The
third column is what reaches the provider's turn (`ProviderTurn`) or the tools;
the controlled tests named prove it with a scripted provider over the core's real
loopback host, for the chat through `ChatHost` and for the app through the core's
call in the shape `TeamModel` makes.

| Field | App (worker) | Chat (invocation) | What reaches the turn | Proof |
| --- | --- | --- | --- | --- |
| Command line | the worker's provider (`ModelSelection.provider`) | `--provider`, or the saved conversation's | the same `ChatProvider` | `theSameExplicitConfigurationCrossesTheCoreFromBothEntries` |
| Model | the worker's model, always named | `--model`, `/model`, or none | the name, or nil for the command line's default | same; `theInstructionsAreSharedWithTheApp` |
| Effort | the worker's level, constrained by its UI; a level the model does not take is left out of the turn | `--effort`, or none | the level when the model offers it; nil for the default. The chat refuses an unsupported level before the turn | `anUnsupportedEffortIsRefusedBeforeTheTurn`, `anEffortTheCommandLineDoesNotTakeIsRefusedBeforeAnythingStarts` |
| Role | the worker's instructions | `--role` | `instructions(role:)`: the base text, the broker session's line, the web line when allowed, then `Your role:` and the trimmed text | `theInvocationsConfigurationReachesTheTurn` |
| Web search | the app preference (on by default) | `--web-search` (off by default) | `allowsWebSearch`, the web line, and the command line's own web tools | same; `WebToolRecordsTests` |
| Environment | the process's, through the Codex allow-list | the same allow-list | launch, login and proxy settings only; no key or endpoint | same, with a synthetic environment |
| Provider session | stored on the conversation per provider, resumed on the next turn | stored in the transcript, resumed on the next turn | `sessionID`, and for Codex the instructions reminder once | `aResumedCodexConversationIsRemindedOnceAcrossInvocations` |
| Provider executable | the install locations (`ClaudeCLIClient`, `CodexCLIClient`) | `PATH` | the command line found; the same version is not asserted | the composers; a stand-in in the tests |
| Bridge, working directory | `mecum-bridge`, a folder per conversation | `mecum` itself, `<history>/ProviderWorkspace` | each host's own, stable across turns | same |
| Desktop | `BrokeredAutomationSession` per worker, the app's broker | one per chat, the chat's broker | the same 14 tools over the same session role | `theToolsAreTheSharedOnesOverTheBrokersSession` |

Defaults that differ on purpose: the app's worker searches the web unless the
preference is off, the chat does not unless asked; the app always names a model
and an effort, the chat leaves both to the command line unless asked.

What the core offers and where it is reachable today:

| Capability | App | Chat |
| --- | --- | --- |
| A command line turn (Claude Code, Codex) | yes | yes |
| A turn through Mecum's own loop (Anthropic, Gemini, Ollama) | yes | no, by design: the chat answers through the signed-in command lines |
| Compaction of the context | yes (`compact`, from the context popover and above 90%) | not exposed; a later increment |
| What a turn cost (`.usage`) | recorded in the workspace, shown on the worker | discarded: the transcript keeps no usage |
| The provider child's identity (`.processStarted`) | recorded, for the recovery after a crash | discarded |
| Tool records, replies, failures, the interruption | recorded | recorded |

## Tools and results

The chat offers the model the same 14 tools as the app's workers (`AutomationTools.definitions`),
decoded by one decoder (`ToolRequestDecoder`) that a batch's steps and the `mecum` direct commands
share. What the definitions cannot say in JSON Schema they say in words, and the decoder enforces.

| Tool | Arguments (required in bold) | Result the model reads | Result the memory keeps |
| --- | --- | --- | --- |
| `status` | none | the session id, or null, and the three permissions as preflighted | `status`: session, screen recording, accessibility, post event |
| `windows` | `app` | each running regular application (or the one named) with name, bundle id, pid and window ids and titles | `listing` of kind windows, applications and windows in order |
| `apps` | `query` | the applications `open_session` can open, best match first, at most 60, with name, bundle id, version, running and location; `more` counts the rest | `listing` of kind apps with the count left out |
| `open_session` | **`app`**, `window` | the session id, revision, time and the first scene's text | `observation`: session, revision, time and the real `current` sample, under the session's own observation event, which names the call as its origin |
| `observe` | **`session`** | a fresh scene of the session's window, its revision and time | `observation` with the call's own `current` sample |
| `act` | **`session`**, **`target`**, `verb` (click when absent), `value` (`on`/`off`, required by `set_toggle` and refused with any other verb), `section` | the outcome kind and sentence, and the scene after | `outcome` and the effect the engine observed, as typed parts |
| `select` | **`session`**, **`control`** (the dropdown's current value or label), **`item`** | as `act` | as `act` |
| `type_text` | **`session`**, **`target`**, **`text`** (typed as given, spaces included), `replace` (true when absent), `section` | as `act` | as `act` |
| `press_key` | **`session`**, **`key`** (return, tab, escape, space, delete, an arrow, a letter or a digit, read without regard to case), `modifiers` (cmd, shift, opt, ctrl, each once), `count` (1 to 20, 1 when absent) | as `act` | as `act` |
| `scroll` | **`session`**, **`direction`** (up/down), `target` (the window's centre when absent), `lines` (1 to 50, 3 when absent), `section` | as `act` | as `act` |
| `drag` | **`session`**, **`from`**, then `to` (a target) or `dx`/`dy` (points within ±5000, a missing axis 0), never both, `section` | as `act` | as `act` |
| `context_menu` | **`session`**, **`target`**, **`item`** (as the app draws it), `section` | as `act` | as `act` |
| `batch` | **`session`**, **`steps`**: 1 to 20 of the seven step tools, each with `operation` and that tool's arguments (a step may repeat the batch's session, which must be it) | each step's result, the status completed or stopped, attempted, verified and requested counts | the batch's summary, every step as a child at its position, the ones never run skipped |
| `close_session` | **`session`** | status closed | `closed` |

A required text must hold a character that is not a space, but `type_text`'s `text`. Whole
numbers may be written `3.0`, as JSON Schema's integer allows; a fraction is refused. A refused
request is refused before any effect, in the sentence the model reads, and records nothing.

Every tool but `status`, `windows`, `apps` and `open_session` requires the ephemeral session id
`open_session` returned; a stale one is refused. Observations carry the revision, the time and
the current text scene; the engine observes afresh before acting, so a saved observation is never
a coordinate or authority for a later input. Results keep the Engine's outcome vocabulary
(`found_acted`, `acted_noop`, `acted_unverified`, `honest_miss`, `ambiguous`, `refused`): a
`completed` call is a call that concluded, not a goal reached.

A batch decodes every step before the first runs, then runs them in order, each observing again,
and stops at the first step that is not `found_acted`, or `acted_noop` for `set_toggle` (the
control was already as asked); an error or a stop ends it too. Earlier effects remain; nothing is
rolled back or replayed. The host follows new application windows with the Driver's window
tracking; dropdowns go through the same selector as the terminal command.

Not implemented: the menu bar, and the shortcuts a menu resolves (Command-C, Command-V,
Command-A, Command-Z), which do nothing on a background window, so Copy and Paste go through
`context_menu`; pasting a file; horizontal scrolling; Command-Q and Command-W, which are refused;
a foreground fallback. Multi-app concurrent control, remote ChatGPT connections and a shipping
application host are separate work.

### The same actions from the terminal

The seven step tools are also `mecum` direct commands, and `mecum batch` steps, read into the same
decoder: a vertical proof of one action or sequence, with no provider and no turn (the chat is the
task path). The grammar is the tool's: the required arguments as positionals, the rest as options.

```sh
.build/debug/mecum act          <app> <target> [--verb <verb>] [--value on|off] [--section <name>]
.build/debug/mecum select       <app> <dropdown> <item> --seat
.build/debug/mecum type_text    <app> <field> <text> [--append] [--section <name>] --seat
.build/debug/mecum press_key    <app> <key> [--modifier cmd|shift|opt|ctrl]... [--count <n>] --seat
.build/debug/mecum scroll       <app> <up|down> [--target <name>] [--lines <n>] [--section <name>] --seat
.build/debug/mecum drag         <app> <from> (--to <target> | --dx <points> [--dy <points>] | --dy <points>) --seat
.build/debug/mecum context_menu <app> <target> <item> [--section <name>] --seat
.build/debug/mecum batch <app> --window <title> --seat -- type_text Name "Bus 1" --then press_key return
```

`--append` is `replace: false`; `--modifier` is given once per modifier. Every option is checked
against the command (an unknown, repeated or valueless one is refused before anything runs), words
reach the decoder as typed (Unicode included, never normalized or evaluated), and `--` makes the
next word literal: `type_text App Body -- --then` types `--then`, and `-- --then` inside a batch is
a text, not a separator. A batch's header follows the same rule: `--window -- --Window` is the title
`--Window` and `batch -- --App` the application `--App`; the first `--` that escapes nothing ends the
header and starts the steps. `act` keeps its foreground mode without `--seat`; `select` and the five
inputs run on the Seat, as the app's session runs them; `--dry-run` is taken by the direct commands
and refused by a batch. Exit status: 0 for `found_acted` or `dry_run` (and `acted_noop` for `act`
and for `set_toggle`), 1 otherwise. The calls are recorded as the chat's are, from the `cli`
source under the invocation's trace. Ctrl+C or SIGTERM stops `scene`, an action or a batch as one
request owned by the invocation (`VerticalInvocation`, with the chat's `TerminalSignals`): the
invocation's memory owner is stopped, so its finalizations share the one budget from that instant;
the command's task is cancelled, so no new action or step starts and a call it catches is concluded
as far as is known, never replayed; the Seat is let go in a task the cancellation does not reach
(`SeatRuntime.hold`), and a window not returned or a display left up is said and kept as an error;
the memory is closed; then the process exits 130 (143 for SIGTERM, 128 plus the signal). A second
signal starts no second cleanup. The shutdown as a whole has no deadline of its own. A process
killed outright (SIGKILL, a crash) can leave a call `planned` or `started` in the memory, which
`mecum memory event` shows as such.

A stop that reaches a capture is told apart from a capture that failed, typed all the way: the
seat answers an observation that ended because its task was cancelled as `.stopped`
(`AgentSeat.observeTellingStop`, package scope; the public `observe()` still answers
`captureFailed` with the cancellation's text), `SeatTarget` throws it as `CancellationError`, and
the engine throws it from `act` and `deliver` when it stops the scene's first reading, before any
effect, so the call is recorded `cancelled` rather than `failed` or an `honest_miss` that advises
Screen Recording. A capture that really failed stays the seat's error, a stop or not; a stop after
the gesture keeps the gesture's known outcome (`completed`, which never means the task succeeded).

### Reading the memory

```sh
.build/debug/mecum memory status
.build/debug/mecum memory traces [--before <order>] [--limit <n>]
.build/debug/mecum memory trace <trace-id> [--after <order>] [--limit <n>] [--detail]
.build/debug/mecum memory event <event-id> [--detail]
.build/debug/mecum memory <app>            # or: memory app <app>
```

These read the archive with no application, Seat or provider: where it is and how it stands, what
it holds per application; the traces, most recent first; a trace's calls and observations in
order, batches with their steps; an event with its source, stream, trace, session, parent and
origin, its call's typed arguments, state, three times (planned, started, ended as the calendar
read them, and the monotonic duration), result and effect, its samples with their quality and
their scene associations. A call left `planned` or `started` is said as such; nothing is completed,
failed or recaptured by reading it, and no row moves. An application is named by a bundle id the
archive holds (installed or not) or by a name of one it holds or that is running; a name that fits
several is answered with the candidates. Typed texts, window titles and labels are counted unless
`--detail` is given. The archive is opened as a reader opens it (`MemoryService.openForReading`):
only a file that already is a Mecum archive, never created, bootstrapped or changed. A missing
archive, a file of zero bytes, a SQLite database with no Mecum schema, a file that is not a database
and one of another schema each exit 1 with their own sentence and are left as they were; a valid
archive with nothing in it says so and exits 0. Gaps noted outside the archive (a `← memory` line, a line on standard error) stay where they
were written: a broken archive cannot tell what it did not save.

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

The living memory: `~/Library/Application Support/Mecum/Knowledge/memory.sqlite`,
the same file the app's workers and the `mecum` vertical commands write (`--knowledge
<directory>` moves the directory; the file name is fixed). The chat opens one
`MemoryService` on it and prints its state before the first turn (`memory: <path>
(schema 1, N commits since open)`, or `memory degraded: <reason> …; tools go on without
it`). Every tool call of a turn, and `/status`, is recorded as an agent call from the
`cli` source, the chat's worker id as the stream and the conversation's id as the trace:
planned with its decoded arguments and started before the tool runs (a stop that lands
there ends the call and nothing runs), then concluded with the result the tool represents
(an action's outcome with the effect the engine observed as typed parts; `status`'s
permissions and session; `windows`' and `apps`' applications and windows in order, with
the count left out; `open_session`'s and `observe`'s session, revision and the real
sample the scene was rendered from), the monotonic duration of the run, or failed with
its error, or cancelled (the effect, if any, is kept, never described as undone); a
batch with its steps as children, the ones never run skipped. Each observation's scene
is the call's `current` sample with its capture quality; an action's perceptions are its
`before` and `after` samples (a contextual menu's, `menu`); `open_session`'s first scene
is an observation event of the session's own, which names the call it was taken for,
since the call could not name the application when it was planned. The brain learns
from them as it always did, once per call. A busy archive (another Mecum writing) is
waited out, never a failure; a memory that truly cannot be written never stops a tool:
one `← memory …` line in the transcript says why, with no label or typed text in it, and
the chat goes on. Nothing is replayed, and the memory is closed last, after the seats.
The older JSON knowledge is neither read nor imported.

## Verification

Local tests cover provider argv/stream parsing, complete-vs-truncated responses,
concurrent pipe draining, process cancellation, MCP authentication/reconnection,
serialized calls and draining, transcript round trips/locks, and CLI parsing.

The turn core is covered by controlled tests in `AgentTurnTests`, with stand-in
command lines (shell fixtures), scripted transports, recorded provider output and
rollouts, and a desktop that refuses: the instructions, the turn as the provider
receives it, a resumed Codex session's reminder, the close with a child running,
Mecum's own loop and its stop, what a Codex turn cost from the rollout, and the
compaction of a context through Claude Code, Codex and the loop.

The chat host over the broker and the core is covered by controlled tests in
`MecumCLITests` (`ChatHostTests`): the broker's queue with seats that raise no
display, a seating supplied in place of macOS, and a scripted provider that speaks
to the core's real loopback host as the bridge does. They prove the 14 shared tools
over the broker's session, an open through the queue under the chat's worker id,
the seat kept between turns, a provider session resumed on the next turn,
`/release` and reopening, the idle window, the one-turn chat, a failed turn in and
outside a terminal, a transcript write that fails, a stop during a turn and a stop
while the open waits for the computer, each with the cleanup awaited; a turn's usage
kept once, an unknown context said as unknown, Codex totals counted from the one before
and a resumed session's first own count unknown; `/compact` through the core with no
tool and no Seat, its failures without a result and a stop during it; that the
same request, and the same explicit configuration (model, effort, role, web
search, environment), crosses the one core from the chat and from the app's call
with the same tools and outcome; that a turn's calls are recorded in the chat's
memory under the conversation's trace from the `cli` source and read back by a
second service after the host closed the first; that `/status` keeps its call and result in the
transcript before the first turn and after one, is refused during a turn, and
throws a record it cannot keep; that an unsupported effort is refused before the
turn; and that a resumed Codex conversation is reminded of new instructions once
across invocations. They open no real application and compare no task with the
app's running: that is live work. The one live request run from this chat with the
living memory, and what it did not prove, is described in
[the memory contracts](MemoryContracts.md#open-items-around-these-contracts).

The terminal's actions and diagnosis are covered in `MecumCLITests` too, with no
application, Seat or provider: `VerticalActionTests` reads the old `act`/`select`/`batch`
invocations and goldens of the seven operations into the tools' decoder, refuses what it
refuses before anything runs, and records direct actions and mixed batches through the real
runner and a scripted performer that writes real samples (stops, skipped steps, errors, a lost
window, a cancellation before and after an effect, the `cli` source apart from the app's);
`MemoryDiagnosisTests` reads a missing archive, an empty file, a file that is not one and one of
another schema apart from a valid empty archive, leaves each as it was, and reads traces, events,
samples, scenes and applications back as recorded.

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
