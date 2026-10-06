import AppKit
import SwiftUI

struct MCPClientRow: View {
    let client: MCPClientConnection
    let model: MCPConnectionsModel
    @State private var copied: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(client.profile.name).font(.headline)
                        Text(scopes).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: { client.profile.enabled }, set: {
                        model.setEnabled($0, for: client.id)
                    }))
                    .toggleStyle(.switch).fixedSize()
                }
                Label(status, systemImage: client.connections > 0 ? "link.circle.fill" : "link.circle")
                    .foregroundStyle(client.isListening ? Color.accentColor : Color.secondary)
                Text(client.activity).font(.callout).textSelection(.enabled)
                if let failure = client.failure {
                    Text(failure).foregroundStyle(.orange).textSelection(.enabled)
                }
                DisclosureGroup("Client configuration") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Paste the JSON into your desktop client's local MCP configuration, or run the command for your CLI. If Mecum moves to another folder, copy the configuration again.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Copy JSON") { copy(model.configuration(for: client.id).json, label: "JSON") }
                            Button("Copy Claude Code command") {
                                copy(model.configuration(for: client.id).claudeCommand, label: "Claude Code command")
                            }
                            Button("Copy Codex command") {
                                copy(model.configuration(for: client.id).codexCommand, label: "Codex command")
                            }
                        }
                        if let copied { Text("Copied \(copied)").font(.caption).foregroundStyle(.secondary) }
                        Text(model.configuration(for: client.id).json)
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.padding(.top, 8)
                }
                HStack {
                    Text("To change capabilities, revoke this grant and create a new one.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revoke", role: .destructive) { model.revoke(client.id) }
                }
            }.padding(8)
        }.disabled(model.isBusy)
    }

    private var scopes: String {
        client.profile.desktop ? "Desktop apps" : "No desktop access"
    }

    private var status: String {
        if client.failure != nil { return "Needs attention" }
        if client.connections > 0 { return "Connected" }
        return client.isListening ? "Ready" : "Stopped"
    }

    private func copy(_ value: String, label: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(value, forType: .string) { copied = label }
    }
}
