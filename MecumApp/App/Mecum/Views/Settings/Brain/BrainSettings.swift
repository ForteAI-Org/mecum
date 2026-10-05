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
/// the computer's and not a worker's. It is read, never changed, here, from
/// the app's living memory (`MemoryReading`), whose owner is the app: leaving
/// the page closes nothing.
///
/// Reading, a memory that does not exist yet, one that could not be read and
/// one with nothing learned are each said as such; a failure is never shown
/// as an empty Brain. Reload reads again, after the workers have learned more.
/// The memory's state is said in plain words, with the technical details
/// under a disclosure; a memory that cannot be used stops no worker.
struct BrainSettings: View {

    /// The app's living memory, read only.
    let memory: any MemoryReading

    /// A state read before the page is drawn (a snapshot's), shown without a first read.
    private let preloaded: BrainLibrary.State?

    @State private var state: BrainLibrary.State

    @State private var status: MemoryService.Status?

    @State private var generation = 0

    init(memory: any MemoryReading, preloaded: BrainLibrary.State? = nil) {
        self.memory    = memory
        self.preloaded = preloaded
        _state         = State(initialValue: preloaded ?? .loading)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch state {
                case .loading:
                    ProgressView("Reading the Brain…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .missing:
                    unavailable(
                        "No Memory Yet",
                        systemImage: "brain",
                        description: "Nothing has been learned on this Mac yet. The Brain learns how an app works when a worker first uses it."
                    )
                case .failed:
                    unavailable(
                        "Brain Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: "Mecum couldn’t read what the Brain has learned. Workers keep using apps; what they learn may not be saved until the memory can be used again."
                    )
                case .loaded(let apps) where apps.isEmpty:
                    unavailable(
                        "No App Knowledge Yet",
                        systemImage: "brain",
                        description: "The memory is ready. The Brain learns how an app works when a worker first uses it."
                    )
                case .loaded(let apps):
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

                        memorySection
                    }
                    .formStyle(.grouped)
                }
            }
            .navigationTitle("Brain")
            .navigationDestination(for: String.self) { bundleID in
                if case .loaded(let apps) = state, let app = apps.first(where: { $0.bundleID == bundleID }) {
                    BrainAppView(app: app)
                }
            }
            .toolbar {
                ToolbarItem {
                    Button("Reload", systemImage: "arrow.clockwise") { generation += 1 }
                        .help("Read what the Brain has learned again.")
                }
            }
        }
        .task(id: generation) {
            if generation > 0 || preloaded == nil {
                state = .loading
                state = await BrainLibrary.load(from: memory)
            }
            status = await memory.status()
        }
    }

    /// A state with nothing to list, with the memory's state under it.
    private func unavailable(_ title: String, systemImage: String, description: String) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                title,
                systemImage: systemImage,
                description: Text(description)
            )
            Form { memorySection }
                .formStyle(.grouped)
                .frame(maxHeight: 220)
        }
    }

    /// The memory's state in plain words, and the technical details for a diagnosis.
    @ViewBuilder
    private var memorySection: some View {
        Section("Memory") {
            LabeledContent("State", value: plainState)
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(details, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var plainState: String {
        switch state {
        case .missing: return "Not created yet"
        case .failed : return "Unavailable — workers go on without it"
        default      : break
        }
        switch status?.state {
        case .ready?   : return "Ready"
        case .degraded?: return "Unavailable — workers go on without it"
        case .closed?  : return "Closed"
        default        : return "Not open yet"
        }
    }

    private var details: [String] {
        var lines: [String] = []
        if let status { lines.append(status.sentence) }
        if case .failed(let reason) = state { lines.append("read failed: \(reason)") }
        if case .missing(let path) = state { lines.append("no archive at \(path)") }
        lines += status?.technicalDetails ?? []
        return lines
    }
}
