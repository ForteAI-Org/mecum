//
//  VirtualDisplaySettings.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SeatBroker
import SwiftUI

/// VirtualDisplaySettings is the display a worker's seat is made with: its
/// size and its refresh rate. A change reaches the broker at once and applies
/// from the next seat; one in use keeps its display until it is given back.
struct VirtualDisplaySettings: View {

    let broker: SeatBroker

    @AppStorage(AppPreferences.seatDisplaySize)
    private var size = AppPreferences.seatDisplaySizeDefault

    @AppStorage(AppPreferences.seatRefreshRate)
    private var refreshRate = AppPreferences.seatRefreshRateDefault

    var body: some View {
        Form {
            Section {
                Picker(
                    "Resolution",
                    selection: $size
                ) {
                    ForEach(SeatDisplay.sizes, id: \.self) { display in
                        Text(title(of: display)).tag(display.sizeKey)
                    }
                }

                Picker(
                    "Refresh rate",
                    selection: $refreshRate
                ) {
                    Text("60 Hz").tag(60)
                    Text("120 Hz").tag(120)
                }
            } footer: {
                Text("""
                    Applies from the next time a worker takes the computer. A smaller display gives a \
                    worker's window less room, so more windows are resized while a worker holds them.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: size) { apply() }
        .onChange(of: refreshRate) { apply() }
    }

    private func title(of display: SeatDisplay) -> String {
        let pixels = "\(display.pixelWidth) × \(display.pixelHeight)"
        return display == .standard ? "\(pixels) (Default)" : pixels
    }

    private func apply() {
        broker.display = AppModel.storedDisplay
    }
}
