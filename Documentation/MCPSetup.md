# Use Mecum with your AI assistant

Connect a local MCP client to Mecum to observe and operate macOS applications, use Chrome, and optionally access passive interaction events. Your client supplies the model; the running Mecum app supplies the tools.

Mecum exposes its bridge over **local STDIO**. The client and Mecum must run on the same Mac. The helper is included in `Mecum.app`; it needs no separate Node.js or Python installation. Tool results are passed to your AI client and may be sent to its model provider: a local bridge does not mean local model inference.

## Set up Mecum first

1. Put `Mecum.app` in a stable location, such as `/Applications`, then open it. Keep Mecum running while using its tools.
2. Grant the macOS permissions requested by Mecum for the features you use: Accessibility and Screen Recording for desktop control/perception; Input Monitoring for passive watching. Chrome connection authorization is separate.
3. Open **MCP → MCP Connections…** from Mecum's menu bar.
4. Give the client a name, select its capabilities, and click **Add Client**. Create a separate entry for each client you intend to connect.
5. Turn **Enabled** on. Wait for **Ready**.
6. Expand **Client configuration**. Use **Copy Claude Code command**, **Copy Codex command**, or **Copy JSON**. These contain your actual paths and client ID.

The generated configuration is the preferred installation method. The examples below are public templates, not credentials and not ready-to-run configurations until you replace the placeholders.

### Paths used in these examples

| Value | Example |
| --- | --- |
| Bundled helper | `/Applications/Mecum.app/Contents/Helpers/mecum-bridge` |
| Client connection file | `/Users/YOUR_USERNAME/Library/Application Support/Mecum/MCP/CLIENT_UUID.connection.json` |

Replace `YOUR_USERNAME` and `CLIENT_UUID` with the values copied from Mecum. If Mecum is elsewhere or uses a custom support directory, use the generated paths instead. Do not create a connection file yourself or copy another person's file.

Use absolute paths inside JSON and TOML. Do not substitute `~` or `$HOME` there. Keep spaces inside each path string; an argument containing a path is one argument. `mecum-bridge` is the executable filename; `mcp-bridge` is its required first argument.

Merge the relevant entry into existing client settings. Preserve unrelated servers and settings. These machine-specific configurations belong in personal settings, not a shared repository.

## Shared JSON template

Claude Desktop, Cursor, Gemini CLI, Cline and Cascade use an `mcpServers` object with this basic command/arguments shape. Their configuration locations are listed below.

```json
{
  "mcpServers": {
    "mecum": {
      "command": "/Applications/Mecum.app/Contents/Helpers/mecum-bridge",
      "args": [
        "mcp-bridge",
        "--connection",
        "/Users/YOUR_USERNAME/Library/Application Support/Mecum/MCP/CLIENT_UUID.connection.json"
      ]
    }
  }
}
```

No `url`, API key, OAuth login or environment variables are required for this bridge. Mecum creates and rotates the local connection credential. Your AI client's own model login remains separate.

## Claude Desktop

Open **Settings → Developer → Edit Config** and merge the shared JSON template into:

```text
~/Library/Application Support/Claude/claude_desktop_config.json
```

Quit Claude Desktop completely and reopen it. Check Mecum's connection status in Developer settings and confirm its tools appear in the conversation's tool controls.

This is the local MCP setup for Claude Desktop. It does not install a hosted connector for claude.ai or establish Cowork compatibility.

Reference: [MCP local-server setup for Claude Desktop](https://modelcontextprotocol.io/docs/develop/connect-local-servers).

## Claude Code

Prefer **Copy Claude Code command** in Mecum. The equivalent template is:

```sh
claude mcp add --scope user --transport stdio mecum -- \
  "/Applications/Mecum.app/Contents/Helpers/mecum-bridge" \
  mcp-bridge --connection \
  "/Users/YOUR_USERNAME/Library/Application Support/Mecum/MCP/CLIENT_UUID.connection.json"
```

Check registration with:

```sh
claude mcp get mecum
```

Start a new Claude Code session and use `/mcp` to check the live connection. User scope makes the configuration available across your projects. If `mecum` already exists, inspect and update that entry instead of adding duplicates.

Reference: [Claude Code MCP configuration](https://code.claude.com/docs/en/mcp).

## Codex CLI and IDE extension

Prefer **Copy Codex command** in Mecum:

```sh
codex mcp add mecum -- \
  "/Applications/Mecum.app/Contents/Helpers/mecum-bridge" \
  mcp-bridge --connection \
  "/Users/YOUR_USERNAME/Library/Application Support/Mecum/MCP/CLIENT_UUID.connection.json"
```

Alternatively, add this to `~/.codex/config.toml`:

```toml
[mcp_servers.mecum]
command = "/Applications/Mecum.app/Contents/Helpers/mecum-bridge"
args = [
  "mcp-bridge",
  "--connection",
  "/Users/YOUR_USERNAME/Library/Application Support/Mecum/MCP/CLIENT_UUID.connection.json"
]
```

Use `codex mcp list` to check registration and `/mcp` inside Codex to inspect active servers. Restart an existing client session after changing configuration.

## ChatGPT desktop / Codex desktop host

For desktop versions exposing local MCP settings, open **Settings → MCP servers → Add server**. Choose **STDIO**, then enter:

| Field | Value |
| --- | --- |
| Name | `mecum` |
| Command | `/Applications/Mecum.app/Contents/Helpers/mecum-bridge` |
| Argument 1 | `mcp-bridge` |
| Argument 2 | `--connection` |
| Argument 3 | The absolute connection-file path copied from Mecum |

Save and restart the server. Desktop, Codex CLI and IDE configuration is shared for the same Codex host; avoid duplicate entries.

Reference for both sections: [OpenAI MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

## Cursor

Merge the shared JSON template into your personal configuration:

```text
~/.cursor/mcp.json
```

Open Cursor's MCP settings, enable or reload the server, and confirm its tools are available to the agent. Project configuration can override a same-named personal entry, so inspect it if Cursor uses an unexpected path.

Reference: [Cursor MCP configuration](https://prod.cursor.com/help/customization/mcp).

## VS Code with GitHub Copilot

Open the Command Palette and run **MCP: Open User Configuration**. VS Code's MCP configuration uses `servers`, rather than `mcpServers`:

```json
{
  "servers": {
    "mecum": {
      "type": "stdio",
      "command": "/Applications/Mecum.app/Contents/Helpers/mecum-bridge",
      "args": [
        "mcp-bridge",
        "--connection",
        "/Users/YOUR_USERNAME/Library/Application Support/Mecum/MCP/CLIENT_UUID.connection.json"
      ]
    }
  }
}
```

Save, use **MCP: List Servers** to start or restart Mecum, and select its tools in Copilot's agent workflow. Keep the server in the local user configuration: a container or remote host cannot use this Mac's executable and loopback connection.

Reference: [VS Code MCP configuration](https://code.visualstudio.com/docs/agent-customization/mcp-servers).

## Gemini CLI

Merge the shared JSON template into:

```text
~/.gemini/settings.json
```

Preserve any existing authentication and model settings. Start a new Gemini CLI session. Check the server with:

```sh
gemini mcp list
```

Use `/mcp` inside Gemini CLI to inspect available MCP servers and tools. Keep the client's normal tool-approval settings.

Reference: [Gemini CLI MCP configuration](https://geminicli.com/docs/tools/mcp-server/).

## Cline

In the extension, open **MCP Servers → Configure → Configure MCP Servers**. Merge this into its settings file:

```json
{
  "mcpServers": {
    "mecum": {
      "command": "/Applications/Mecum.app/Contents/Helpers/mecum-bridge",
      "args": [
        "mcp-bridge",
        "--connection",
        "/Users/YOUR_USERNAME/Library/Application Support/Mecum/MCP/CLIENT_UUID.connection.json"
      ],
      "disabled": false,
      "autoApprove": []
    }
  }
}
```

For Cline CLI, the configuration file is `~/.cline/mcp.json`. Enable or restart the server through Cline's MCP controls. The empty `autoApprove` list leaves tool approvals with the client.

Reference: [Cline MCP documentation](https://github.com/cline/cline/blob/main/docs/mcp/mcp-overview.mdx).

## Windsurf / Cascade

Use Cascade's MCP controls to **Open MCP config file**, then merge the shared JSON template under `mcpServers`. Enable the server and check its tools in Cascade.

Use the file opened by your installed editor. The current documentation redirects to Devin Desktop and lists `~/.config/devin/mcp_config.json`; older Windsurf installations can use a different location.

Reference: [Cascade MCP configuration](https://docs.devin.ai/desktop/cascade/mcp).

## Other local MCP clients

A client that supports launching a local STDIO server can use the same values:

```text
Transport: stdio
Command:   /Applications/Mecum.app/Contents/Helpers/mecum-bridge
Arguments:
  mcp-bridge
  --connection
  /Users/YOUR_USERNAME/Library/Application Support/Mecum/MCP/CLIENT_UUID.connection.json
```

If a client requires an array containing the whole command, place the executable first, followed by those three arguments. Follow that client's configuration schema; not every client uses an `mcpServers` wrapper.

If the interface only accepts a server URL, this local configuration cannot be pasted there. Mecum currently provides no public HTTP/SSE endpoint or hosted OAuth connector. Direct web/cloud connection requires a separate integration; do not describe this feature as universal ChatGPT web, claude.ai or cloud-agent support.

## Choose the capabilities to expose

| Mecum capability | Tools and behavior |
| --- | --- |
| Desktop apps | Discover applications/windows, observe interfaces, resolve targets and perform engine actions. |
| Browser | Use the Chrome tools through the engine's supported browser connection modes. |
| Passive Watcher | Explicitly start, read and stop passive interaction observation. |

Desktop and Browser are selected by default when creating a grant. Watcher requires explicit selection. Watcher events are not automatically learned.

Each grant has a living memory and a Brain of its own, in `MCP/Knowledge/<grant>` under Mecum's support directory: what one client learns is not read by the app's workers or by another client. No option shares it.

The helper forwards requests to the running app. It does not grant macOS permissions or start Mecum automatically. Changing capabilities requires revoking the grant and creating a new one.

## Test the connection

Start with this prompt in your configured client, with **Desktop apps** enabled:

> Use Mecum to report permission status, list running applications and list the open windows of one application. Do not open, move, click or change anything.

Confirm that the client actually calls Mecum tools and returns their results. A saved configuration alone does not prove a working connection.

For a subsequent action, name the app, window and intended result:

> Use Mecum in Pro Tools. In the I/O Setup window, select Output Busses in the All Busses filter. Observe first, verify the resulting value, and stop if the target is ambiguous. Do only this operation.

The relevant application and window must already be available, and the selected Mecum build must permit that operation. Client connectivity does not establish compatibility with every application or macOS build.

Mecum supplies workflow instructions during MCP initialization. Agents should call `task_begin` with the user's request before desktop/browser work, then `task_end` with `completed`, `failed` or `interrupted`. `status`, `apps` and `windows` are available without beginning a task. Calling a task completed does not by itself establish a successful UI action or qualify it for learning.

## Multiple clients and stopping access

Each Mecum grant accepts **one active connection at a time**, including connections opened for tool discovery. Create different grants for Claude Desktop, Claude Code, Cursor and other independently running clients. Each gets its own connection-file path.

Shared settings do not remove this limit. For clients sharing one configuration, use one frontend at a time unless you explicitly arrange separate grants and effective configurations. A health check can also encounter an already occupied grant.

All clients still share Mecum's Seat broker, browser profile pool and passive Watcher. Separate grants do not mean simultaneous unrestricted control of the same app, Chrome profile or Watcher run.

Turn **Enabled** off to stop access while retaining the grant. **Revoke** removes the saved authorization. Quitting Mecum disconnects clients. After reopening Mecum, restart or reconnect the client; the helper does not automatically reconnect or replay requests.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| `Mecum is unavailable` | Mecum must be running, the grant enabled, and the connection-file path correct. Copy configuration again if needed. |
| Server exits immediately | Check both paths, including the helper's execute permission, and keep the whole app bundle intact. |
| Connection refused or another client works instead | Another process may already hold this grant. Stop it or use a separate grant. |
| Tools missing | Check the grant's selected capabilities and the client's tool selection, then restart its MCP connection. |
| Tools connect but desktop work fails | Check Mecum's macOS permissions and engine result. MCP registration does not override permission or compatibility checks. |
| Connection stopped after repeated failures | Inspect the reported cause. Mecum pauses a client after three unsuccessful desktop attempts; turn it off and on after resolving the issue. |
| App moved after setup | Copy new configuration so the helper path points to the current app. |
| Uncertain result after disconnect | Observe the application before retrying; the previous action might already have taken effect. |

Never publish the contents of `*.connection.json`: those files contain local connection credentials. Share these templates, not live endpoint files. No real username, client UUID or token is needed in public documentation.

## Verification scope

These instructions were checked on 6 October 2026 against Mecum commit `e28b9f0` on `ron/app-engine-integration`, the generated client configuration, the installed Claude Code/Codex command help, and the linked client documentation. Other branches or later releases may differ.

Previous Mecum checks covered the bundled helper, local app host, cancellation/revocation and synthetic engine calls. These examples have not all been exercised end to end in every listed client. Treat them as configuration instructions, not a claim of tested compatibility with every version, account or real-app workflow.
