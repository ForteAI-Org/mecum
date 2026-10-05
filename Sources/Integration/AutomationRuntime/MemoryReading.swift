//
//  MemoryReading.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import Foundation
import Memory
import PerceptionCore

/// MemoryReading is the living memory as a reader sees it, and nothing more: where the archive stands,
/// what it holds per application, an application's Brain, the traces and their events, a call, an
/// event, a sample and its scene associations. The app's Brain library and the command line's
/// diagnosis depend on this role alone, so neither can write, and neither reaches SQLite: the owner's
/// `MemoryService` is the one conformer, and its owner closes it, never a reader.
///
/// `archiveExists` is asked before a reading opens anything, so a reader can say an archive is
/// missing. `openForReading` opens only an archive that already is one at this build's schema: it
/// creates no file and no schema, and a file it refuses is left as it was, however it changed
/// since `archiveExists` was asked (the store decides under the file's lock); an open of the owner
/// already in flight is joined. Every read is one snapshot and moves no row. The producers' open
/// (`MemoryService.ready`/`open`, which creates and bootstraps) is not part of this role.
nonisolated public protocol MemoryReading: BrainReading, MemoryTraceReading {

    /// Whether the archive's file is there now, without opening it.
    var archiveExists: Bool { get }

    /// Where the archive stands, without opening it.
    func status() async -> MemoryService.Status

    /// Opens an existing archive for reading, or throws why not, changing nothing (`MemoryService.openForReading`).
    func openForReading() async throws

    func overview() async throws -> MemoryOverview
    func call(_ eventID: String) async throws -> AgentCall?
    func steps(ofBatch eventID: String) async throws -> [AgentCall]
    func event(_ eventID: String) async throws -> MemoryEventRecord?
    func sample(_ key: CaptureSampleKey) async throws -> CaptureSample?
    func associations(of key: CaptureSampleKey) async throws -> [SceneAssociation]
}

/// BrainCatalogEntry is one application whose Brain the archive holds: its bundle ID, the active
/// projection as read, and the archive's counts for it. Nothing in it is made up: no Route,
/// experience or knowledge aggregate the archive does not hold.
nonisolated public struct BrainCatalogEntry: Sendable, Equatable {

    public let bundleID: String
    public let brain: UIBrain
    public let summary: MemoryOverview.App

    public init(bundleID: String, brain: UIBrain, summary: MemoryOverview.App) {
        self.bundleID = bundleID
        self.brain    = brain
        self.summary  = summary
    }

    /// When the Brain last saw anything of the application, nil before it saw anything.
    public var lastLearned: Date? {
        (brain.objects.map(\.lastSeen) + brain.groups.map(\.lastSeen) + brain.transitions.map(\.lastObserved)).max()
    }
}

/// BrainCatalog is what the archive's Brain holds, application by application, read through
/// `MemoryReading`: three answers a reader must never confuse. `missing` is no archive at all (nothing
/// was ever learned on this Mac, or the archive is elsewhere); `unavailable` is an archive that could
/// not be read, with the reason, never shown as empty; `loaded` is a readable archive, whose list may
/// be empty.
nonisolated public enum BrainCatalogState: Sendable, Equatable {
    case missing(path: String)
    case unavailable(reason: String)
    case loaded([BrainCatalogEntry])
}

nonisolated public enum BrainCatalog {

    /// Reads the catalogue: the archive's applications (`overview`), each with its Brain when the
    /// archive holds one, in bundle-ID order. One read per call; no cache, so a reading after a new
    /// write sees it. It opens through `openForReading`: a file that is not a Mecum archive yet (zero
    /// bytes, or SQLite with no schema) or one of a schema this build refuses is `unavailable` and left
    /// as it was, never `loaded` empty; it never closes the service, which is its owner's.
    public static func load(from memory: any MemoryReading) async -> BrainCatalogState {
        let before = await memory.status()
        if before.state == .notOpened, !memory.archiveExists { return .missing(path: before.path) }
        do {
            try await memory.openForReading()
        } catch {
            return .unavailable(reason: MemoryService.describe(error))
        }
        do {
            var entries: [BrainCatalogEntry] = []
            for app in try await memory.overview().apps {
                guard let brain = try await memory.brain(of: app.bundleID) else { continue }
                entries.append(BrainCatalogEntry(bundleID: app.bundleID, brain: brain, summary: app))
            }
            return .loaded(entries)
        } catch {
            return .unavailable(reason: MemoryService.describe(error))
        }
    }
}
