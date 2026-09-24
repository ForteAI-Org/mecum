//
//  BrainSettings.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import SwiftUI

/// BrainSettings is what the engine's Brain has learned, one application at a
/// time: the applications it knows, each of which pushes its own page with
/// the application's name as the title and the window's back button to come
/// back. The Brain is shared by every worker and the command line, so it is
/// the computer's and not a worker's. It is read, never changed, here.
struct BrainSettings: View {

    /// The knowledge directory the workers and the command line write.
    let directory: URL

    @State private var apps: [BrainApp] = []

    var body: some View {
        NavigationStack {
            Group {
                if apps.isEmpty {
                    ContentUnavailableView(
                        "Nothing Learned Yet",
                        systemImage: "brain",
                        description: Text("The Brain learns an application the first time a worker uses it.")
                    )
                } else {
                    Form {
                        Section {
                            ForEach(apps) { app in
                                NavigationLink(value: app.bundleID) { BrainAppRow(app: app) }
                            }
                        } header: {
                            Text("Applications")
                        } footer: {
                            Text("Every worker and the mecum command line share what is learned here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationTitle("Brain")
            .navigationDestination(for: String.self) { bundleID in
                if let app = apps.first(where: { $0.bundleID == bundleID }) { BrainAppView(app: app) }
            }
        }
        .task { apps = BrainLibrary.apps(in: directory) }
    }
}
