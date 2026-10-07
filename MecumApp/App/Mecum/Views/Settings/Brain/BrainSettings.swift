//
//  BrainSettings.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AutomationRuntime
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
    @State private var memory: MemoryService.Status?

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
            .safeAreaInset(edge: .bottom) {
                if let memory {
                    Text(Self.summary(of: memory))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("Brain")
            .navigationDestination(for: String.self) { bundleID in
                if let app = apps.first(where: { $0.bundleID == bundleID }) { BrainAppView(app: app) }
            }
        }
        .task {
            // This process's own view of its memory: read without opening, creating or copying anything.
            memory = await MemoryService.shared(for: directory).status()
            switch await BrainLibrary.apps(in: directory) {
                case .loaded(let loaded)    : apps = loaded; unavailable = nil
                case .unavailable(let why)  : apps = []; unavailable = why
            }
        }
    }

    /// The memory's state in two lines: the archive and the library, then this run's writes. The
    /// counts start at zero with each launch of Mecum.
    static func summary(of status: MemoryService.Status) -> String {
        let state: String = switch status.state {
            case .notOpened         : "not opened yet"
            case .open              : "open"
            case .degraded(let why) : "unavailable: \(why)"
            case .closed            : "closed"
        }
        var lines = ["Memory \(state) at \(status.path), SQLite \(status.libraryVersion ?? "unknown")."]
        lines.append("Since Mecum started: \(status.written) saved, \(status.failed) failed, \(status.dropped) dropped, "
                     + "\(status.pending + status.inFlight) not yet saved."
                     + (status.partial > 0 ? " \(status.partial) saved in part." : ""))
        if let copy = status.lastBackup { lines.append("Last copy: \(copy.formatted(date: .abbreviated, time: .shortened)).") }
        if let recovery = status.lastRecovery { lines.append(recovery) }
        return lines.joined(separator: "\n")
    }
}
