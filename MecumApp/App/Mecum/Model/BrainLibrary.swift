//
//  BrainLibrary.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AppKit
import AutomationRuntime
import Foundation
import Memory

/// BrainApp is what the engine's Brain has learned about one application, with
/// the name and icon the person knows it by.
struct BrainApp: Identifiable {

    let bundleID : String
    let name     : String
    let icon     : NSImage?
    let knowledge: AppKnowledge

    var id: String { bundleID }

    var brain: UIBrain { knowledge.brain }

    /// When the Brain last saw anything of the application, nil before it saw anything.
    var lastLearned: Date? {
        (brain.objects.map(\.lastSeen) + brain.groups.map(\.lastSeen) + brain.transitions.map(\.lastObserved)).max()
    }
}

/// BrainLibraryState is what the Brain page can show: the applications the living memory holds a
/// Brain of, possibly none yet, or an archive that cannot be read, with the reason, which is never
/// shown as an empty Brain.
enum BrainLibraryState {
    case loaded([BrainApp])
    case unavailable(String)
}

/// BrainLibrary reads the Brain from the living memory of the knowledge directory the workers and the
/// command line share: the process's own `MemoryService` for it, which reads without waiting for a
/// worker writing at the same time. A directory with no archive yet holds no Brain, and reading it
/// creates nothing.
enum BrainLibrary {

    static func apps(in directory: URL) async -> BrainLibraryState {
        let memory = MemoryService.shared(for: directory)
        guard memory.archiveExists else { return .loaded([]) }
        do {
            var apps: [BrainApp] = []
            for entry in try await memory.overview().apps {
                guard let brain = try await memory.brain(of: entry.bundleID) else { continue }
                apps.append(app(for: AppKnowledge(bundleID: entry.bundleID, brain: brain)))
            }
            return .loaded(apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        } catch {
            return .unavailable(MemoryService.describe(error))
        }
    }

    private static func app(for knowledge: AppKnowledge) -> BrainApp {
        let bundleID = knowledge.bundleID
        let url      = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name     = url.map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        return BrainApp(
            bundleID : bundleID,
            name     : name ?? bundleID,
            icon     : url.map { NSWorkspace.shared.icon(forFile: $0.path) },
            knowledge: knowledge
        )
    }
}
