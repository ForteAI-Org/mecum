import AppKit
import SwiftUI

/// MCPConnectionsView exposes explicit local grants and client setup without modifying other apps.
struct MCPConnectionsView: View {
    static let windowID = "mcp-connections"
    let model: MCPConnectionsModel
    @State private var name = ""
    @State private var desktop = true

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
                        Text("Desktop access lets this client read and control apps through Mecum. macOS permissions still apply. Enable only clients you trust.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Add Client") {
                            model.add(MCPClientProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                       desktop: desktop))
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
