//
//  ProfileHeader.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import SwiftUI
import Workspace

/// The profile's title: the worker's mascot and name, the area's name under
/// it, and the configuration version at the trailing edge once there is one.
struct ProfileHeader: View {

    let worker: WorkerSnapshot

    var body: some View {
        HStack(spacing: 12) {
            MascotView(
                appearance: worker.appearance,
                size      : 36
            )

            VStack(
                alignment: .leading,
                spacing  : 2
            ) {
                Text(worker.name)
                    .font(.title3.bold())
                Text("Model and connection")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let version = worker.configurationVersion {
                Text("Version \(version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
