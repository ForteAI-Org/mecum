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
    @State private var unavailable: String?

    var body: some View {
        NavigationStack {
            Group {
                if let unavailable {
                    ContentUnavailableView(
                        "Brain Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The Brain's memory could not be read: \(unavailable)")
                    )
                } else if apps.isEmpty {
                    ContentUnavailableView(
                        "No App Knowledge Yet",
                        systemImage: "brain",
                        description: Text("The Brain learns how an app works when a worker first uses it.")
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
                            Text("Workers and the Mecum command-line tool share what the Brain learns.")
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
        .task {
            switch await BrainLibrary.apps(in: directory) {
                case .loaded(let loaded)    : apps = loaded; unavailable = nil
                case .unavailable(let why)  : apps = []; unavailable = why
            }
        }
    }
}
