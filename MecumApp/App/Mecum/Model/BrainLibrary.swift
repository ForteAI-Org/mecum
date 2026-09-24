//
//  BrainLibrary.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AppKit
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

/// BrainLibrary reads the Brain's files, one JSON file per application in the
/// knowledge directory the workers and the command line share. It only reads,
/// through the kit's own decoder and without the store's lock, so a worker
/// writing at the same time is never held up; a file caught mid-write is read
/// again on the next visit.
enum BrainLibrary {

    static func apps(in directory: URL) -> [BrainApp] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at                        : directory,
            includingPropertiesForKeys: nil,
            options                   : [.skipsHiddenFiles]
        )) ?? []
        let decoder = KnowledgeCoding.makeDecoder()

        return files
            .filter { $0.pathExtension == "json" && !isBookkeeping($0) }
            .compactMap { file -> BrainApp? in
                guard let data = try? Data(contentsOf: file),
                      let knowledge = try? decoder.decode(AppKnowledge.self, from: data)
                else { return nil }

                return app(for: knowledge)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The allowlist and a quarantined file are the store's own, not an application's.
    private static func isBookkeeping(_ file: URL) -> Bool {
        let name = file.deletingPathExtension().lastPathComponent
        return name == "allowlist" || name.contains(".corrupt-")
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
