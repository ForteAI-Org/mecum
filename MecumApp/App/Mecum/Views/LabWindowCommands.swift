//
//  LabWindowCommands.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import SwiftUI

/// LabWindowCommands is how the desktop lab is opened once the team became the
/// app's front door.
///
/// The lab drives a seat through `SeatBroker` and is reshaped in increment 6,
/// not removed. It is a window of its own rather than a tab of the team: the
/// team holds no seat, and putting the two in one window would suggest that
/// selecting a worker takes one.
struct LabWindowCommands: Commands {

    @Environment(\.openWindow)
    private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Desktop Lab") { openWindow(id: MecumApp.labWindowID) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
