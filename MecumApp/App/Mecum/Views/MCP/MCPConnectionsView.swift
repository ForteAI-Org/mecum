import AppKit
import SwiftUI

/// MCPConnectionsView exposes explicit local grants and client setup without modifying other apps.
struct MCPConnectionsView: View {
    static let windowID = "mcp-connections"
    let model: MCPConnectionsModel
    @State private var name = ""
    @State private var desktop = true
    @State private var browser = true
    @State private var watcher = false
    @State private var memory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Use Mecum from a local AI client").font(.title2.bold())
                Text("Connect Claude Desktop, Claude Code or Codex using MCP over standard input/output. Mecum must stay open. Each client can have one active connection.")
                    .foregroundStyle(.secondary)
                if let issue = model.issue {
                    Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
                GroupBox("Add a client") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Client name, for example Claude Code", text: $name)
                        Toggle("Desktop apps", isOn: $desktop)
                        Toggle("Browser", isOn: $browser)
                        Toggle("Passive Watcher", isOn: $watcher)
                        Toggle("Shared Brain and living memory", isOn: $memory)
                        Text("Desktop and browser access can read and change your apps. Watcher access can start observing your interactions. Shared memory includes previously learned workflows; otherwise this client has its own Brain.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Add Client") {
                            model.add(MCPClientProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                       desktop: desktop, browser: browser, watcher: watcher,
                                                       sharedMemory: memory))
                            name = ""
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
                    }.padding(8)
                }
                .disabled(!model.isReady || model.isBusy)
                if model.clients.isEmpty {
                    Text(emptyState)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.clients) { client in
                    MCPClientRow(client: client, model: model)
                }
                Text("Enabled clients are restored when Mecum starts. Stop closes the connection and cancels its work. Revoke also removes the saved grant. No remote server or tunnel is opened.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
        }
        .frame(minWidth: 610, idealWidth: 700, minHeight: 570, idealHeight: 720)
    }

    private var emptyState: String {
        if model.isReady { return "No clients authorized. Add a client, enable it, then copy its configuration." }
        if model.issue != nil { return "Connections unavailable. Resolve the issue above and reopen Mecum." }
        return "Opening local connections…"
    }

}

struct MCPConnectionsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("MCP") {
            Button("MCP Connections…") { openWindow(id: MCPConnectionsView.windowID) }
        }
    }
}
