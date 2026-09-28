//
//  SettingsCommands.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// SettingsCommands points the app menu's Settings… and Command-Comma at the
/// Settings window. Settings is a plain `Window` scene rather than the
/// `Settings` one, which draws a small title bar that has no room for the
/// page's title and toolbar, so the menu item that scene would give is made
/// here.
struct SettingsCommands: Commands {

    @Environment(\.openWindow)
    private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { openWindow(id: SettingsView.windowID) }
                .keyboardShortcut(
                    ",",
                    modifiers: .command
                )
        }
    }
}
