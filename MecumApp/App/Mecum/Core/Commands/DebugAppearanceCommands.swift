//
//  DebugAppearanceCommands.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

#if DEBUG

import AppKit
import SwiftUI

/// DebugAppearanceCommands is the Debug menu, in debug builds only: Appearance
/// switches the whole app between light and dark on the fly, or gives it back
/// to the system's setting. The choice is the app's state, since SwiftUI does
/// not observe `NSApp.appearance`, and it lasts until the app quits.
struct DebugAppearanceCommands: Commands {

    @Binding var choice: DebugAppearance

    var body: some Commands {
        CommandMenu("Debug") {
            Picker(
                "Appearance",
                selection: Binding(
                    get: { choice },
                    set: { appearance in
                        choice           = appearance
                        NSApp.appearance = appearance.appearance
                    }
                )
            ) {
                ForEach(DebugAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance)
                }
            }
        }
    }
}

/// What the app follows: the system's setting, or one of the two appearances.
enum DebugAppearance: CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light : "Light"
        case .dark  : "Dark"
        }
    }

    /// The app's appearance for the choice; nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light : NSAppearance(named: .aqua)
        case .dark  : NSAppearance(named: .darkAqua)
        }
    }
}

#endif
