# Local MCP connections

Keep Mecum open, then choose **MCP → MCP Connections…** in the menu bar. This lets
Claude Desktop, Claude Code and Codex use the desktop tools of the current engine.
Provider settings choose the models used inside Mecum; MCP connections authorize
an external client to use Mecum's tools.

## Setup

1. Install Mecum in a stable location, such as `/Applications/Mecum.app`.
2. Open **MCP Connections**, name a client and select **Desktop apps**.
3. Click **Add Client**. New grants are disabled. Turn **Enabled** on and wait for **Ready**.
4. Expand **Client configuration** and copy the JSON for Claude Desktop, or the
   registration command for Claude Code or Codex. Paths are generated for this app.
5. Add the JSON entry to the client's existing `mcpServers` object, preserving its
   other servers, or run the copied CLI command. Reconnect the client.
6. Start with: “Use Mecum to list the open windows. Do not change anything.”

A separate grant is needed for each simultaneous client process. One grant admits
one connection at a time. If the app moves, copy its configuration again. Mecum
must stay running; the helper never launches it or silently retries an action.

## Scope and lifecycle

This connection exposes `AutomationTools` from the current engine, through the
same Seat broker as Mecum's workers. It adds no browser engine or Watcher. Its calls
are recorded with the `mcp` source and the grant as their stream in a living memory
of the grant's own, `MCP/Knowledge/<grant>` under the app's support directory, as on
main: a client learns into its own Brain, apart from the workers' and the other
clients'. Desktop access allows both reading and acting; macOS permissions still
belong to Mecum and are not bypassed by the client grant.

The bundled `mecum-bridge` forwards standard MCP JSON lines to an authenticated
loopback socket. No remote listener, HTTP endpoint or tunnel is opened. Local
connection files are private (0600 in a 0700 directory); copied configurations
contain paths, not credentials. Another process under the same macOS account can
read those files, so they do not isolate untrusted software running as that user.

Stopping or revoking a grant closes admission, cancels in-flight calls, drains
cleanup and releases its Seat. Disconnect also closes that connection's session.
An interrupted action may already have happened: reconnect, observe and decide;
never replay automatically. The existing engine releases idle sessions or makes
room for another worker between calls. Saved session IDs may therefore expire.
Enabled grants restore at app launch with fresh credentials; task state does not.

The app owns grant storage, configuration rendering and engine composition.
`LocalMCP` owns framing, authentication and connection lifetime. Internal worker
hosts retain their existing router across provider reconnections. External clients
receive a fresh router and engine session only after authenticating.

## Verification

Run `swift test --filter 'MCPTests|MCPExternalTransportTests'` with Swift 6.4.
The app suites `MCPConnectionsModelTests`, `ExternalMCPSessionTests`,
`MCPAppBridgeTests` and `MCPConnectionsViewTests` cover grants, engine boundaries,
the bundled helper and rendered configuration. The helper test uses a real child
process with synthetic controls and does not send private app data to a provider.
