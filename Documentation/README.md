# Mecum documentation

Start with the app setup below, or choose a guide:

- [MCP setup](MCPSetup.md): connect Claude Code, Codex or another local client.
- [Compatibility and limitations](LaunchCompatibility.md): supported frameworks and workflow checks.
- [Driver](Driver/README.md): virtual displays, window placement and input routing.
- [Perception](Perception/README.md): turn the current interface into structured text.
- [Engine](Engine/README.md): resolve actions, check effects and use app knowledge.
- [Benchmarks](Driver/reports/CUADriverBenchmark20261006.md): measured results, method and per-operation data.

## Get started

Mecum runs on macOS 15+ on Apple silicon and Intel.

1. Install and open `Mecum.app`.
2. Create a worker and connect a supported model. If you use Codex or Claude Code, keep their CLIs up to date to access the latest models available to your account.
3. Grant the [Mac access](#permissions-and-data) needed for the features you use.
4. Give the worker a small task in a disposable document. Name the app, the intended result and where it should stop. Follow the activity and inspect the result.

For a first task, ask the agent to read an open TextEdit test document and summarize it without editing or saving.

To use an external assistant, keep Mecum open on the same Mac and follow the [MCP setup guide](MCPSetup.md). To build from source, follow the [developer Quickstart](../QUICKSTART.md).

## Brain

Brain builds a map of an app's controls, relationships and transitions from observations and action evidence. This gives the agent context about how the app works.

The map adds context to a fresh observation. The engine still finds targets in the current interface and checks what changed after acting. See the [Engine's memory integration](Engine/README.md#using-it) and [contracts](Engine/README.md#contracts) for the implementation.

## Memory

Memory stores past interactions and their outcomes, so agents can draw on that experience in later tasks. Recall is still in development and can be inconsistent, with improvements on the way.

App knowledge, living memory and workspace history are separate stores. External MCP clients need the **Shared Brain and living memory** capability to access shared knowledge and living memory. Without it, the client uses its own Brain. See [MCP capabilities](MCPSetup.md#choose-the-capabilities-to-expose) and the [Engine's recall contracts](Engine/README.md#contracts).

## Permissions and data

Grant access for the features you use:

| Access | Purpose |
| --- | --- |
| Accessibility | Read interface elements and enable desktop control. |
| Screen Recording | Capture windows for Perception. |
| Input Monitoring | Enable passive watching when explicitly selected. |
| Chrome connection authorization | Allow browser tools to use the connected Chrome instance. |

The desktop window-to-text pipeline runs on your Mac. A remote model can receive window text, task context and relevant app knowledge. Other tools, including browser tools, can return screenshots; the data sent depends on the tools and model connection used.

The local MCP bridge does not make model inference local. Choose the capabilities for each client and use [MCP access controls](MCPSetup.md#multiple-clients-and-stopping-access) to stop or revoke a connection.

You can follow activity and stop a worker in Mecum. Stopping does not undo actions already delivered; inspect the app before continuing. Read [background work](LaunchCompatibility.md#background-work) for session limits.
