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
                    "Show the time under messages",
                    isOn: $showsTimes
                )
                Toggle(
                    "Show tool steps open",
                    isOn: $opensToolSteps
                )
            }

            Section {
                Picker(
                    "Send with",
                    selection: $sendsWithCommandReturn
                ) {
                    Text("Return").tag(false)
                    Text("Command-Return").tag(true)
                }
            } header: {
                Text("Composer")
            } footer: {
                Text(sendsWithCommandReturn
                    ? "Return starts a new line."
                    : "Shift-Return or Option-Return starts a new line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
