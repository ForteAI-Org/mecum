//
//  MemoryCommand.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import AutomationRuntime
import Foundation
import Memory
import PerceptionCore
import SQLiteMemory

/// MemoryCommand prints what the living memory holds for an application: the Brain's size and clock,
/// its most established anchors with what they do, and its groups. With `--import-json <dir>` it
/// copies the Brains of an earlier JSON Knowledge directory into the memory instead.
enum MemoryCommand {

    static func run(_ invocation: Invocation) async throws {
        if invocation.flags.contains("status") {
            printStatus(of: Runtime.knowledgeDirectory(invocation).appendingPathComponent("memory.sqlite"))
            return
        }
        let runtime = Runtime(invocation: invocation)
        if let source = invocation.options["import-json"] {
            try await importJSON(from: URL(fileURLWithPath: (source as NSString).expandingTildeInPath, isDirectory: true),
                                 into: runtime)
            return
        }
        let application = try ApplicationLookup.running(try invocation.positional(0, "<app>"))
        let bundleID = application.bundleIdentifier ?? "pid.\(application.processIdentifier)"
        let brain: UIBrain
        do {
            guard let stored = try await runtime.service.brain(of: bundleID) else {
                print("nothing remembered about \(bundleID) in \(runtime.service.url.path)")
                return
            }
            brain = stored
        } catch {
            print("the memory in \(runtime.service.url.path) cannot be read: \(MemoryService.describe(error))")
            return
        }
        print("\(bundleID): \(brain.objects.count) anchors, \(brain.groups.count) groups, "
            + "\(brain.transitions.count) transitions; observed \(brain.ingestEpoch) times")
        let established = brain.objects.sorted { $0.seenCount > $1.seenCount }.prefix(15)
        if !established.isEmpty { print("anchors, most seen first:") }
        for anchor in established {
            let name = anchor.label.isEmpty ? "(unnamed)" : anchor.label
            let source = anchor.labelSource.map { " [\($0.rawValue)]" } ?? ""
            let does = brain.does(anchorKey: anchor.anchorKey).map { ", \($0)" } ?? ""
            let states = anchor.statesSeen.isEmpty
                ? ""
                : ", states " + anchor.statesSeen.keys.sorted().joined(separator: "/")
            let at = String(format: "%.2f,%.2f", anchor.boundsTypical.x, anchor.boundsTypical.y)
            print("  \(name)\(source) ×\(anchor.seenCount) at \(at)\(does)\(states)")
        }
        for group in brain.groups {
            let members = "\(group.memberAnchors.count) \(group.sharedKind.rawValue)s"
            print("group \(group.name ?? group.axis.rawValue): \(members), seen \(group.seenCount)×")
        }
        let opportunities = brain.namingOpportunities(limit: 5)
        if !opportunities.isEmpty { print("worth naming:") }
        for opportunity in opportunities {
            print("  \(opportunity.anchor.anchorKey.prefix(8)) score \(opportunity.score): \(opportunity.context)")
        }
    }

    /// Prints what the archive file is, read only: this command opens no memory service, so it creates,
    /// migrates, recovers and copies nothing, and it has no counters of another process's writes. It
    /// reads in one read transaction under the archive's presence lock, so it never reads while a
    /// recovery moves the files, and says so instead.
    private static func printStatus(of url: URL) {
        let report = SQLiteMemoryInspection.inspect(url)
        print("archive: \(report.path)")
        print("SQLite linked into this mecum: \(SQLiteLibrary.version) (\(SQLiteLibrary.sourceID))")
        if let unmet = SQLiteLibrary.unmetRequirement() {
            print("  below the memory's requirement: \(unmet.minimumVersion)")
        }
        let known = SQLiteMemoryInspection.supportedVersion
        if let version = report.schemaVersion { print("schema version: \(version); this build opens version \(known)") }
        switch report.shape {
            case .missing:               print("this build: no archive at this path; Mecum's memory would create it")
            case .empty:                 print("this build: a database with no schema yet; Mecum's memory would create its schema in it, "
                                               + "a reader refuses it")
            case .current:               print("this build: opens it; version \(known) and exactly the shape this build creates")
            case .refused(let mismatch): print("this build: refuses it and leaves it as it is; " + describe(mismatch))
            case .unreadable(let why):   print("this build: cannot read it as a database: \(why)")
            case .unavailable(let why):  print("this build: did not read it: \(why)")
            case .interruptedRecovery(let why):
                print("this build: did not read it: \(why). Mecum's memory opens nothing until a recovery completes "
                      + "it from that record, on its next open, or says why it cannot")
        }
        if let bytes = report.bytes { print("size: \(bytes) bytes" + (report.journalBytes.map { ", journal \($0) bytes" } ?? "")) }
        for table in SQLiteMemoryInspection.countedTables {
            if let count = report.counts[table] { print("  \(table): \(count) rows") }
        }
        print("copies: " + (report.backups.isEmpty ? "none" : report.backups.joined(separator: ", ")))
        if !report.quarantined.isEmpty { print("moved aside after a recovery: " + report.quarantined.joined(separator: ", ")) }
        print("writes waiting, failed or dropped live in the memory of the process that offered them;")
        print("this command has its own and shows none. The app shows its own on Settings > Brain.")
    }

    /// Why this build refuses a file, in a sentence.
    private static func describe(_ mismatch: MemorySchemaMismatch) -> String {
        func listed(_ names: [String]) -> String { names.prefix(8).joined(separator: ", ") + (names.count > 8 ? ", …" : "") }
        switch mismatch {
            case .future(let found, let supported): return "schema \(found) is newer than the \(supported) this build knows; "
                                                           + "its shape was not compared"
            case .unknownTables(let tables):        return "version 0 with tables of somebody else's: \(listed(tables))"
            case .missingTables(let tables):        return "tables missing: \(listed(tables))"
            case .missingColumns(let columns):      return "an earlier development form, columns missing: \(listed(columns))"
            case .differentShape(let objects):      return "another shape: \(listed(objects))"
            case .uninitialized:                    return "no schema yet"
        }
    }

    /// Copies the Brain of every application file in an earlier JSON Knowledge directory into the
    /// memory, as that application's projection, when the memory holds no Brain of it yet
    /// (`JSONBrainImport`). The JSON files are only read, never changed. An archive this command creates
    /// first imports the JSON Brains beside it on its own, as every opener of a new archive does, and the
    /// command says so before its own lines.
    private static func importJSON(from source: URL, into runtime: Runtime) async throws {
        let knowledge = JSONBrainImport.applications(in: source)
        guard !knowledge.isEmpty else {
            print("no application files in \(source.path)")
            return
        }
        let repositories = try await runtime.service.ready()
        let created = await runtime.service.status().lastImport
        if let created { print(created) }
        let report = await JSONBrainImport.run(knowledge, into: repositories.brains, now: Date())
        for entry in report.entries {
            switch entry.outcome {
                case .imported(let anchors, let groups, let transitions):
                    print("imported \(entry.bundleID): \(anchors) anchors, \(groups) groups, \(transitions) transitions")
                case .kept:
                    print("kept \(entry.bundleID): the memory already holds its Brain")
                case .failed(let why):
                    print("could not import \(entry.bundleID): \(why)")
            }
        }
        await runtime.finish()
        print("\(report.imported) of \(knowledge.count) applications imported into \(runtime.service.url.path)"
              + (created == nil ? "" : " by this command, after the archive's creation imported those beside it"))
    }
}
