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

/// BrainApp is what the engine's Brain has learned about one application, as
/// the living memory holds it, with the name and icon the person knows it by:
/// the active projection and the archive's counts, nothing else. An
/// application that is not installed keeps its bundle ID as its name.
struct BrainApp: Identifiable {

    let bundleID: String
    let name    : String
    let icon    : NSImage?
    let entry   : BrainCatalogEntry

    var id: String { bundleID }

    var brain: UIBrain { entry.brain }

    /// When the Brain last saw anything of the application, nil before it saw anything.
    var lastLearned: Date? { entry.lastLearned }
}

/// BrainLibrary is what Settings' Brain page shows: the living memory's
/// applications read through `MemoryReading`, the app's memory shared with the
/// workers (`AppModel`), never a file of its own and never the older JSON
/// knowledge. Each load reads again, off the main actor inside the memory's
/// actor, so a refresh after a new write sees it; nothing is cached across
/// loads. A missing archive, an archive that could not be read and a readable
/// one with nothing learned are three different answers.
enum BrainLibrary {

    enum State {
        /// Not read yet, or being read.
        case loading
        /// No archive at the path: the workers have not learned anything on this Mac yet.
        case missing(path: String)
        /// The archive could not be read; the reason is technical, for the details.
        case failed(reason: String)
        /// The archive was read; it may hold no application.
        case loaded([BrainApp])
    }

    static func load(from memory: any MemoryReading) async -> State {
        switch await BrainCatalog.load(from: memory) {
            case .missing(let path)      : return .missing(path: path)
            case .unavailable(let reason): return .failed(reason: reason)
            case .loaded(let entries)    :
                return .loaded(entries.map(app(for:))
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    /// The name and icon Launch Services knows the application by, else its bundle ID and no icon.
    private static func app(for entry: BrainCatalogEntry) -> BrainApp {
        let url  = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path) }
            .map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 }
        return BrainApp(
            bundleID: entry.bundleID,
            name    : name ?? entry.bundleID,
            icon    : url.map { NSWorkspace.shared.icon(forFile: $0.path) },
            entry   : entry
        )
    }
}
