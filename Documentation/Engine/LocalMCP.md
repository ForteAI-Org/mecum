# Local MCP connections

Mecum's running macOS application can serve its engine to local MCP clients.
Open **MCP → MCP Connections…** in the menu bar. No connection is enabled until
someone creates and enables a grant. This is separate from model-provider
settings: the external client chooses and pays for its own model.

## Connect a client

1. Build and launch Mecum, and keep it open. Use a stable app location; moving the
   app changes the path to its bundled helper.
2. Open **MCP Connections**, give the client a name, and choose its capabilities.
3. Click **Add Client**, then turn **Enabled** on. The row should read **Ready**.
4. Expand **Client configuration**. Copy the command for **Claude Code** or
   **Codex**, or the JSON for a desktop client supporting local stdio MCP.
5. Run the copied CLI command, or merge the `mecum` entry into the desktop client's
   existing `mcpServers` object. Do not replace unrelated servers. Restart or
   reconnect that client as its MCP settings require.
6. Ask it to list Mecum's tools and begin with a read-only task. For example:
   “Use Mecum to list the open windows. Do not open or change anything.”

The CLI commands follow these forms; copy the actual absolute paths from Mecum:

```sh
claude mcp add --scope user --transport stdio mecum -- \
  '/absolute/path/Mecum.app/Contents/Helpers/mecum-bridge' \
  mcp-bridge --connection '/absolute/path/MCP/client-uuid.connection.json'

codex mcp add mecum -- \
  '/absolute/path/Mecum.app/Contents/Helpers/mecum-bridge' \
  mcp-bridge --connection '/absolute/path/MCP/client-uuid.connection.json'
```

Claude Desktop uses the copied `mcpServers` JSON. In ChatGPT desktop, open **Settings → MCP servers → Add server**, choose **STDIO**
and enter the helper command and arguments, then save and restart the server.
The desktop app and Codex CLI share their MCP configuration; see the
[OpenAI MCP guide](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).
The [Claude Code MCP guide](https://code.claude.com/docs/en/mcp) documents stdio
registration and the desktop JSON format.
A web/remote connector expecting an HTTPS URL cannot use this bridge. This feature
adds no remote endpoint, tunnel, OAuth service or cloud access.

Use a separate Mecum grant for each client process. One grant admits one connection
at a time, including discovery connections. If another instance already owns it,
close that instance or create a second grant. Configuration paths remain stable
across app restarts; the endpoint and credential inside the private file rotate.

## Capabilities and permissions

| Capability | What the client can do |
| --- | --- |
| Desktop apps | Discover apps/windows, observe, resolve and act using the existing engine and background Seat. |
| Browser | Use the existing Chrome tools, browser authorization and current/managed profile modes. |
| Passive Watcher | Explicitly start observation and read recent events from its own run. |
| Shared Brain and living memory | Read shared suggestions and contribute only evidence admitted by the existing learning rules. |

Desktop and browser are selected in the creation form. Watcher and shared memory
are initially unselected. **Add Client** saves a disabled grant. Capability changes
require revoking and recreating the grant, so an existing connection never silently
acquires broader access. Without shared memory, a client uses its own Brain directory
and has no access to the shared living-memory store.

macOS grants belong to **Mecum.app**, where capture and input execute, not to the
stdio helper. The client grant does not bypass Accessibility, Screen Recording,
Input Monitoring or browser authorization. Missing grants retain the engine's
explicit refusal. A rebuilt or relocated app can still require macOS permission
repair; this bridge does not change TCC identity or reset system permissions.

The connection directory is mode `0700`; the registry and endpoint files are
`0600`. Endpoints bind to `127.0.0.1`, use an unguessable credential and are not HTTP
servers. A process lease prevents two Mecum instances using the same support
directory from overwriting each other's endpoints. These files protect against
other OS users; they are not a sandbox against malicious software running as the
same user. Treat a connection file as a credential and do not share it.

## Tasks, memory and observation

A client calls `task_begin(request)` before desktop/browser work. It receives a
connection-local task ID and any permitted memory context. It calls
`task_end(task, ending)` with `completed`, `failed` or `interrupted` when done.
`status`, `apps` and `windows` do not need a task. A second unfinished task and a
foreign task ID are rejected before effects.

Completion is a lifecycle statement, not proof of success. Existing `TurnCycle`
and typed engine evidence decide what can enter memory. Disconnecting an unfinished
task interrupts it; the bridge never promotes it as completed. UI text, browser
content, memory suggestions and Watcher events remain data, not instructions.

The app and external clients share one Seat broker and browser-profile pool.
Another worker may acquire the Seat between MCP calls. The previous session ID
then becomes invalid: reopen and observe, rather than replaying an action. `batch`
keeps known consecutive steps in one engine call and stops on an uncertain result.
A browser profile stays owned until its client disconnects the browser or its MCP
session ends.

`watch_start(app)` starts a new run for an exact running name/bundle ID, or `*` for
all apps. It cannot take over a manual run or another client's run. `watch_recent`
returns at most 100 recent bounded records, with separate before/after/AX evidence.
`watch_stop` joins cleanup. Disconnect stops and clears its owned run. A manual
restart gets a new run ID, so the old client cannot read or stop it. Watcher events
are not automatically learned or proof that an action caused a change.

## Stop, revoke and failure behavior

- **Enabled off** closes admission, removes the endpoint, cancels active calls and
  joins cleanup. The saved grant remains disabled across restarts.
- **Revoke** closes admission and persists removal before cleanup, so a crash after
  persistence cannot restore the grant.
  The client's old configuration then fails until a new grant is configured.
  Revocation does not erase previously learned knowledge. If saving a stop or
  revocation fails, the live connection still stops; the row remains with an
  explicit warning that the old grant may return on restart.
- Quitting Mecum removes endpoints and drains clients within the app's bounded
  shutdown. An abrupt process termination can leave a stale file; the next launch
  replaces it, and a stale token cannot authorize a new host.
- Three unsuccessful desktop attempts stop that client's listener. Reconnecting
  cannot reset this in the same app run. Review the failure, stop and enable it.
- The helper does not launch Mecum, reconnect or replay requests. If the host exits,
  it terminates even while stdin is idle. Client EOF closes the host connection
  immediately and cancels pending work. Do not close stdin before reading replies.
- Stopping input cannot undo an action already delivered. After interruption,
  observe the actual app before deciding what to do next.

Only tool names and the latest status appear in the connections panel. The bridge
adds no transcript or Watcher-event persistence. Enabled grants are restored when
Mecum next starts; task IDs, sessions and credentials are never resumed implicitly.

## Boundaries and checks

`LocalMCP` owns framing, authentication, routing and resource lifetime, independent
of the app UI, engine, model providers and storage for knowledge. The app composes
`ExternalMCPSession` with `AutomationTools`, `TurnCycle`, `BrokeredAutomationSession`,
the shared browser pool and `WatcherMCPAccess`. Existing internal worker hosts keep
their per-worker router across provider connections; external hosts create a fresh
session only after authentication. Neither path launches an engine in the helper.

```sh
xcrun --toolchain org.swift.640202609131a swift test \
  --filter 'MCPTests|MCPExternalTransportTests'
make test SWIFT='xcrun --toolchain org.swift.640202609131a swift'
```

App suites: `MCPConnectionsModelTests`, `ExternalMCPSessionTests`,
`WatcherMCPAccessTests`, `MCPAppBridgeTests`, `MCPConnectionsViewTests`; regressions: `WatcherModelTests`, `WorkerAgentHostTests`,
`WorkerBrowserTests`. These use controlled adapters and synthetic content. They
verify authorization, lifecycle, memory evidence and ownership; they do not prove
that a model completes a real Pro Tools or browser workflow.
