//
//  ChatSettings.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// ChatSettings is how a conversation reads, how a message is sent, and whether workers may go online.
struct ChatSettings: View {

    @AppStorage(AppPreferences.chatShowsTimes)
    private var showsTimes = AppPreferences.chatShowsTimesDefault

    @AppStorage(AppPreferences.chatOpensToolSteps)
    private var opensToolSteps = AppPreferences.chatOpensToolStepsDefault

    @AppStorage(AppPreferences.chatSendsWithCommandReturn)
    private var sendsWithCommandReturn = AppPreferences.chatSendsWithCommandReturnDefault

    @AppStorage(AppPreferences.workersSearchWeb)
    private var workersSearchWeb = AppPreferences.workersSearchWebDefault

    var body: some View {
        Form {
            Section("Messages") {
                Toggle(
                    "Show message times",
                    isOn: $showsTimes
                )
                Toggle(
                    "Expand tool activity by default",
                    isOn: $opensToolSteps
                )
            }

            Section {
                Picker(
                    "Send Messages With",
                    selection: $sendsWithCommandReturn
                ) {
                    Text("Return").tag(false)
                    Text("Command-Return").tag(true)
                }
            } header: {
                Text("Sending")
            } footer: {
                Text(sendsWithCommandReturn
                    ? "Return inserts a line break."
                    : "Shift-Return or Option-Return inserts a line break.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Workers can search the web",
                    isOn: $workersSearchWeb
                )
            } header: {
                Text("Web")
            } footer: {
                Text("Claude Code and Codex workers can look things up online. Turn this off to keep workers offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
