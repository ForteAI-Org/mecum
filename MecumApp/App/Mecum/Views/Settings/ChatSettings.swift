//
//  ChatSettings.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// ChatSettings is how a conversation reads and how a message is sent.
struct ChatSettings: View {

    @AppStorage(AppPreferences.chatShowsTimes)
    private var showsTimes = AppPreferences.chatShowsTimesDefault

    @AppStorage(AppPreferences.chatOpensToolSteps)
    private var opensToolSteps = AppPreferences.chatOpensToolStepsDefault

    @AppStorage(AppPreferences.chatSendsWithCommandReturn)
    private var sendsWithCommandReturn = AppPreferences.chatSendsWithCommandReturnDefault

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
        }
        .formStyle(.grouped)
    }
}
