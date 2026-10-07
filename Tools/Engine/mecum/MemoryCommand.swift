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
    /// migrates, recovers and copies nothing, and it has no counters of another process's writes.
    private static func printStatus(of url: URL) {
        let report = SQLiteMemoryInspection.inspect(url)
        print("archive: \(report.path)")
        print("SQLite linked into this mecum: \(SQLiteLibrary.version) (\(SQLiteLibrary.sourceID))")
        if let unmet = SQLiteLibrary.unmetRequirement() {
            print("  below the memory's requirement: \(unmet.minimumVersion)")
        }
        switch report.shape {
            case .missing:              print("state: no archive at this path")
            case .empty:                print("state: a database with no schema yet")
            case .matches:              print("state: schema \(report.schemaVersion ?? 0), exactly the shape this build creates")
            case .differs(let objects): print("state: schema \(report.schemaVersion ?? 0), another shape; this build refuses it untouched: "
                                              + objects.prefix(8).joined(separator: ", ") + (objects.count > 8 ? ", …" : ""))
            case .unreadable(let why):  print("state: not readable as a database: \(why)")
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

    /// Copies the Brain of every application file in an earlier JSON Knowledge directory into the
    /// memory, as that application's projection, when the memory holds no Brain of it yet. The JSON
    /// files are only read, never changed. An imported Brain has no evidence in the memory: the
    /// counts it carries are the file's, and what the agent learns from now on adds to them.
    private static func importJSON(from source: URL, into runtime: Runtime) async throws {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []).filter { file in
            // The allowlist and a quarantined file are the store's own, not an application's.
            let name = file.deletingPathExtension().lastPathComponent
            return file.pathExtension == "json" && name != "allowlist" && !name.contains(".corrupt-")
        }.sorted { $0.path < $1.path }
        let decoder = KnowledgeCoding.makeDecoder()
        let knowledge = files.compactMap { file -> AppKnowledge? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(AppKnowledge.self, from: data)
        }
        guard !knowledge.isEmpty else {
            print("no application files in \(source.path)")
            return
        }
        let repositories = try await runtime.service.ready()
        var imported = 0
        for app in knowledge {
            let brain = app.brain
            do {
                if try await repositories.brains.importProjection(brain, into: app.bundleID, now: Date()) {
                    imported += 1
                    print("imported \(app.bundleID): \(brain.objects.count) anchors, \(brain.groups.count) groups, "
                          + "\(brain.transitions.count) transitions")
                } else {
                    print("kept \(app.bundleID): the memory already holds its Brain")
                }
            } catch {
                print("could not import \(app.bundleID): \(MemoryService.describe(error))")
            }
        }
        await runtime.finish()
        print("\(imported) of \(knowledge.count) applications imported into \(runtime.service.url.path)")
    }
}
