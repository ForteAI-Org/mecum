//
//  GeneralSettings.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AppKit
import SwiftUI

/// GeneralSettings is how the conversation reads, its text size and font
/// with an example reply set in them, and whether the connections are checked
/// as the app starts. The size is the one View > Bigger and Smaller change.
struct GeneralSettings: View {

    @AppStorage(TextSizeCommands.storageKey)
    private var bodyPointSize = Double(TranscriptStyle.actualSize.bodyPointSize)

    @AppStorage(AppPreferences.chatFontFamily)
    private var fontFamily = AppPreferences.chatFontFamilyDefault

    @AppStorage(AppPreferences.checksConnectionsAtLaunch)
    private var checksConnectionsAtLaunch = AppPreferences.checksConnectionsAtLaunchDefault

    /// The families installed on this Mac, read once for the menu.
    @State private var families = NSFontManager.shared.availableFontFamilies

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
        }
        .formStyle(.grouped)
    }
}
