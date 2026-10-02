//
//  GeneralSettings.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// GeneralSettings is how the conversation reads, its text size and font
/// with an example reply set in them, and whether the connections are checked
/// as the app starts. The size is the one View > Bigger and Smaller change.
/// Troubleshooting exports the log for a bug report.
struct GeneralSettings: View {

    @AppStorage(TextSizeCommands.storageKey)
    private var bodyPointSize = Double(TranscriptStyle.actualSize.bodyPointSize)

    @AppStorage(AppPreferences.chatFontFamily)
    private var fontFamily = AppPreferences.chatFontFamilyDefault

    @AppStorage(AppPreferences.checksConnectionsAtLaunch)
    private var checksConnectionsAtLaunch = AppPreferences.checksConnectionsAtLaunchDefault

    /// The families installed on this Mac, read once for the menu.
    @State private var families = NSFontManager.shared.availableFontFamilies

    @State private var isExportingLog = false

    /// Why the last export failed, shown in an alert until dismissed.
    @State private var logExportFailure: String?

    var body: some View {
        Form {
            Section("Conversation Appearance") {
                Picker(
                    "Text Size",
                    selection: $bodyPointSize
                ) {
                    ForEach(TranscriptStyle.bodyPointSizes, id: \.self) { size in
                        Text(size == TranscriptStyle.actualSize.bodyPointSize ? "\(Int(size)) pt (Default)" : "\(Int(size)) pt")
                            .tag(Double(size))
                    }
                }

                Picker(
                    "Font",
                    selection: $fontFamily
                ) {
                    Text("System").tag("")
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
            }

            Section("Preview") {
                FontExample(
                    family: fontFamily,
                    size  : CGFloat(bodyPointSize)
                )
            }

            Section {
                Toggle(
                    "Check providers when Mecum opens",
                    isOn: $checksConnectionsAtLaunch
                )
            } footer: {
                Text("Mecum checks each provider, including the Codex and Claude command-line tools.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button(
                        "Export Log…",
                        action: exportLog
                    )
                    .disabled(isExportingLog)

                    if isExportingLog {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Saves Mecum’s log from the last 24 hours to a file you choose, to attach to a bug report.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert(
            "Mecum Couldn’t Export the Log",
            isPresented: Binding(
                get: { logExportFailure != nil },
                set: { if !$0 { logExportFailure = nil } }
            )
        ) {
            Button(
                "OK",
                role: .cancel
            ) {}
        } message: {
            Text(logExportFailure ?? "")
        }
    }

    /// Asks where to save the log and exports it there. Cancelling does nothing.
    private func exportLog() {
        guard !isExportingLog else { return }
        let panel                  = NSSavePanel()
        panel.allowedContentTypes  = [.plainText]
        panel.nameFieldStringValue = LogExport.defaultFileName(at: .now)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExportingLog = true
        Task {
            defer { isExportingLog = false }
            do {
                try await LogExport.export(to: url)
            } catch {
                logExportFailure = error.localizedDescription
            }
        }
    }
}
