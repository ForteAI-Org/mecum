//
//  MemoryDiagnosis.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AutomationRuntime
import EngineCore
import Foundation
import Memory
import PerceptionCore

/// MemoryDiagnosisError is a diagnosis that cannot answer: said apart from an archive that answers
/// with nothing, so a failure never reads as an empty memory. Each exits 1.
nonisolated enum MemoryDiagnosisError: Error, CustomStringConvertible, Equatable {

    /// No archive at the path: nothing was created to stand in for it.
    case noArchive(path: String)

    /// A file of zero bytes at the path: not an archive yet, left as it is (opening it would make one).
    case notAnArchive(path: String)

    /// A SQLite database at the path with no schema yet: not a Mecum archive, left as it is.
    case noMecumSchema(path: String)

    /// An archive that could not be opened or read, with the reason in the store's words.
    case unavailable(String)

    case noSuchTrace(String)
    case noSuchEvent(String)
    case unknownApplication(String)
    case ambiguousApplication(String, candidates: [String])

    var description: String {
        switch self {
            case .noArchive(let path):
                "no memory archive at \(path); nothing was created. Pass --knowledge <dir> for another one."
            case .notAnArchive(let path):
                "\(path) is an empty file, not a memory archive; it was left as it is"
            case .noMecumSchema(let path):
                "\(path) is a SQLite database with no Mecum schema, not a memory archive; it was left as it is"
            case .unavailable(let reason):
                "the memory could not be read: \(reason)"
            case .noSuchTrace(let id):
                "the archive holds no event under trace \(CallText.quoted(id))"
            case .noSuchEvent(let id):
                "the archive holds no event \(CallText.quoted(id))"
            case .unknownApplication(let word):
                "no application in the archive or running matches \(CallText.quoted(word))"
            case .ambiguousApplication(let word, let candidates):
                "\(CallText.quoted(word)) names more than one application; use a bundle ID: " + candidates.joined(separator: ", ")
        }
    }
}

/// ApplicationDirectory is what the diagnosis asks the Mac about applications, for names alone: the
/// installed application's name for a bundle ID, and the running ones. It never launches anything.
struct ApplicationDirectory {

    var installedName: (String) -> String?
    var running: () -> [(name: String, bundleID: String)]

    /// The diagnosis's own stand-in: no application installed or running.
    static let none = ApplicationDirectory(installedName: { _ in nil }, running: { [] })
}

/// MemoryAppResolver finds which application a word names for `memory <app>`: a bundle ID the archive
/// holds, or a name of an application the archive holds or that is running. A name that fits more
/// than one is never settled by choosing the first: the candidates are the answer.
enum MemoryAppResolver {

    enum Resolution: Equatable {
        case bundle(String)
        case ambiguous([String])
        case unknown
    }

    static func resolve(_ word: String, catalog: [String], directory: ApplicationDirectory) -> Resolution {
        if let exact = catalog.first(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) { return .bundle(exact) }
        var names: [(name: String, bundleID: String)] = catalog.compactMap { bundle in
            directory.installedName(bundle).map { (name: $0, bundleID: bundle) }
        }
        names += directory.running()
        if let running = names.first(where: { $0.bundleID.caseInsensitiveCompare(word) == .orderedSame }) {
            return .bundle(running.bundleID)
        }
        func unique(_ matches: [(name: String, bundleID: String)]) -> [String] {
            var seen: Set<String> = []
            return matches.map(\.bundleID).filter { seen.insert($0).inserted }.sorted()
        }
        let exact = unique(names.filter { $0.name.caseInsensitiveCompare(word) == .orderedSame })
        if exact.count == 1 { return .bundle(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }
        let prefixed = unique(names.filter { $0.name.lowercased().hasPrefix(word.lowercased()) })
        if prefixed.count == 1 { return .bundle(prefixed[0]) }
        if prefixed.count > 1 { return .ambiguous(prefixed) }
        return .unknown
    }
}

/// MemoryDiagnosis answers the `memory` command's questions from the archive, through `MemoryReading`
/// alone: where it stands and what it holds (`status`), the traces (`traces`), one trace's events
/// (`trace`), one event with its call, samples and associations (`event`), and an application's Brain
/// (`app`). It opens no application, Seat or provider, and changes no row by reading it: a call left
/// `planned` or `started` is said as such, a sample that was not recorded as not recorded.
@MainActor
struct MemoryDiagnosis {

    static let defaultTraces = 20
    static let defaultEntries = 50
    static let maximumLimit = 500

    let memory: any MemoryReading
    let directory: ApplicationDirectory
    let detail: Bool
    let output: (String) -> Void

    /// Opens an existing archive for reading (`MemoryReading.openForReading`): a missing file, a file
    /// with no schema yet (zero bytes, or SQLite with nothing in it), a schema this build refuses and
    /// an archive that does not open are each refused as such, and none is created, bootstrapped or
    /// changed; the decision is the store's, under the file's lock, whatever happened to the file
    /// since `archiveExists` was asked.
    static func open(_ memory: any MemoryReading, path: String) async throws {
        guard memory.archiveExists else { throw MemoryDiagnosisError.noArchive(path: path) }
        do {
            try await memory.openForReading()
        } catch MemoryStoreError.schema(.uninitialized(let fileIsEmpty)) {
            throw fileIsEmpty ? MemoryDiagnosisError.notAnArchive(path: path) : MemoryDiagnosisError.noMecumSchema(path: path)
        } catch MemoryStoreError.open(let fault) where fault.code.primary == 14 {
            // SQLITE_CANTOPEN: the file went away after it was seen; nothing stands in for it.
            throw MemoryDiagnosisError.noArchive(path: path)
        } catch {
            throw MemoryDiagnosisError.unavailable(MemoryService.describe(error))
        }
    }

    // MARK: status

    func status() async throws {
        let status = await memory.status()
        output("archive: \(status.path)")
        for line in status.technicalDetails { output(line) }
        let overview = try await read { try await memory.overview() }
        let traces = try await read { try await memory.traces(before: nil, limit: Self.defaultTraces) }
        output("applications: \(overview.apps.count)")
        for app in overview.apps {
            output("  " + label(app.bundleID) + ": \(app.projectionAnchors) anchors, \(app.projectionGroups) groups, "
                   + "\(app.projectionTransitions) effects, \(app.structuralScenes) scenes, \(app.events) events, \(app.samples) samples")
        }
        let routes = RouteStatus.allCases.map { "\(overview.routes[$0] ?? 0) \($0.rawValue)" }.joined(separator: ", ")
        output("routes: \(routes); experiences: \(overview.experiences); task occurrences: \(overview.taskOccurrences); "
               + "step occurrences: \(overview.stepOccurrences); events without an application: \(overview.eventsWithoutApp)")
        output("traces: \(traces.count == Self.defaultTraces ? "\(traces.count) most recent shown by `memory traces`" : "\(traces.count)")")
        if overview.apps.isEmpty && traces.isEmpty { output("the archive is valid and holds no memories yet") }
    }

    // MARK: traces

    func traces(before: Int64?, limit: Int) async throws {
        let page = try await read { try await memory.traces(before: before, limit: limit) }
        if page.isEmpty { output(before == nil ? "no traces recorded" : "no traces before \(before ?? 0)") }
        for trace in page {
            output("\(trace.traceID) · \(trace.source.rawValue) stream \(trace.streamID) · \(trace.calls) calls, \(trace.events) events · "
                   + "orders \(trace.firstLocalOrder)…\(trace.lastLocalOrder) · from \(CallText.calendar(trace.firstOccurredAtMS)) "
                   + "to \(CallText.calendar(trace.lastOccurredAtMS))")
        }
        if page.count == limit, let last = page.last { output("more: --before \(last.lastLocalOrder)") }
    }

    // MARK: trace

    func trace(_ traceID: String, after: Int64?, limit: Int) async throws {
        let page = try await read { try await memory.entries(inTrace: traceID, after: after, limit: limit) }
        if page.isEmpty {
            if after == nil { throw MemoryDiagnosisError.noSuchTrace(traceID) }
            output("no further events after \(after ?? 0)")
            return
        }
        for entry in page {
            let event = entry.event
            let indent = event.parentEventID == nil ? "" : "    "
            let step = event.parentPosition.map { "step \($0) · " } ?? ""
            let what: String
            if let call = entry.call {
                what = CallText.line(call, detail: detail)
            } else {
                what = "\(event.kind.rawValue)" + (event.originEventID.map { " for call \($0)" } ?? "")
                    + " · capture \(event.captureStatus.rawValue)"
            }
            output("\(indent)#\(entry.localOrder) \(event.eventID) · \(step)\(what)")
        }
        if page.count == limit, let last = page.last { output("more: --after \(last.localOrder)") }
    }

    // MARK: event

    func event(_ eventID: String) async throws {
        guard let event = try await read({ try await memory.event(eventID) }) else {
            throw MemoryDiagnosisError.noSuchEvent(eventID)
        }
        output("event \(event.eventID)")
        output("  kind \(event.kind.rawValue) · source \(event.source.rawValue) · stream \(event.streamID)"
               + (event.sourceKey.map { " · source key \(CallText.quoted($0))" } ?? ""))
        output("  trace \(event.traceID ?? "none") · session \(event.sessionID ?? "none")")
        output("  parent \(event.parentEventID.map { "\($0) at position \(event.parentPosition ?? -1)" } ?? "none")"
               + " · origin \(event.originEventID ?? "none")")
        output("  application " + (event.app.map { "\($0.bundleID) version \($0.version ?? "unknown") locale \($0.locale ?? "unknown")" }
                                   ?? "unknown"))
        output("  occurred \(CallText.calendar(event.occurredAtMS)) · monotonic \(event.monotonicNS.map { "\($0) ns" } ?? "not recorded")"
               + " · capture \(event.captureStatus.rawValue)")
        if let call = try await read({ try await memory.call(eventID) }) {
            output("call \(CallText.request(call.request, detail: detail))")
            output("  contract \(call.contractVersion) · state \(CallText.status(call.progress.status))")
            output("  planned \(CallText.calendar(event.occurredAtMS)) · started \(CallText.calendar(call.startedAtMS)) · "
                   + "ended \(CallText.calendar(call.progress.endedAtMS)) · duration "
                   + (call.durationMS.map { "\($0) ms (monotonic)" } ?? "not recorded"))
            output("  result \(CallText.result(call.progress.result, detail: detail))")
            output("  effect \(CallText.effect(call.progress.observedEffect, detail: detail))")
            if call.request.tool == .batch {
                let steps = try await read { try await memory.steps(ofBatch: eventID) }
                output("  steps: \(steps.count) of \(call.requestedSteps.map(String.init) ?? "unknown") requested")
                for step in steps {
                    output("    \(step.event.parentPosition ?? -1): \(step.event.eventID) · \(CallText.line(step, detail: detail))")
                }
            }
        }
        var recorded = 0
        for phase in CapturePhase.allCases {
            let key = CaptureSampleKey(eventID: eventID, phase: phase)
            guard let sample = try await read({ try await memory.sample(key) }) else { continue }
            recorded += 1
            output("sample \(CallText.sample(sample, detail: detail))")
            let associations = try await read { try await memory.associations(of: key) }
            output("  scenes: " + (associations.isEmpty ? "none associated"
                : associations.map { "\($0.sceneID) (\($0.status.rawValue) by \($0.matchedBy) \($0.matcherVersion))" }
                    .joined(separator: ", ")))
        }
        if recorded == 0 { output("samples: none recorded under this event") }
        for observation in try await read({ try await memory.observations(originatedBy: eventID) }) {
            output("observation \(observation.eventID) was taken for this call · capture \(observation.captureStatus.rawValue)")
        }
    }

    // MARK: app

    func app(_ word: String) async throws {
        let overview = try await read { try await memory.overview() }
        let catalog = overview.apps.map(\.bundleID)
        let bundleID: String
        switch MemoryAppResolver.resolve(word, catalog: catalog, directory: directory) {
            case .bundle(let found): bundleID = found
            case .ambiguous(let candidates): throw MemoryDiagnosisError.ambiguousApplication(word, candidates: candidates.map(label))
            case .unknown:
                // A bundle ID the archive does not hold is still a fair question: it has nothing for it.
                guard word.contains(".") else { throw MemoryDiagnosisError.unknownApplication(word) }
                bundleID = word
        }
        output(label(bundleID))
        guard let brain = try await read({ try await memory.brain(of: bundleID) }) else {
            output("nothing remembered about \(bundleID) in this archive")
            return
        }
        output("\(brain.objects.count) anchors, \(brain.groups.count) groups, \(brain.transitions.count) transitions; "
               + "observed \(brain.ingestEpoch) times")
        if let summary = overview.apps.first(where: { $0.bundleID == bundleID }) {
            output("archive: \(summary.events) events, \(summary.samples) samples, \(summary.structuralScenes) scenes, "
                   + "\(summary.sceneElements) scene elements, \(summary.menuCommands) menu commands, \(summary.brainEvidence) evidence rows")
        }
        let established = brain.objects.sorted { $0.seenCount > $1.seenCount }.prefix(15)
        if !established.isEmpty { output("anchors, most seen first:") }
        for anchor in established {
            let name = anchor.label.isEmpty ? "(unnamed)" : (detail ? CallText.quoted(anchor.label) : anchor.label)
            let source = anchor.labelSource.map { " [\($0.rawValue)]" } ?? ""
            let does = brain.does(anchorKey: anchor.anchorKey).map { ", \($0)" } ?? ""
            let states = anchor.statesSeen.isEmpty ? "" : ", states " + anchor.statesSeen.keys.sorted().joined(separator: "/")
            let at = String(format: "%.2f,%.2f", anchor.boundsTypical.x, anchor.boundsTypical.y)
            output("  \(name)\(source) ×\(anchor.seenCount) at \(at)\(does)\(states)")
        }
        for group in brain.groups {
            output("group \(group.name ?? group.axis.rawValue): \(group.memberAnchors.count) \(group.sharedKind.rawValue)s, seen \(group.seenCount)×")
        }
        let opportunities = brain.namingOpportunities(limit: 5)
        if !opportunities.isEmpty { output("worth naming:") }
        for opportunity in opportunities {
            output("  \(opportunity.anchor.anchorKey.prefix(8)) score \(opportunity.score): \(opportunity.context)")
        }
        output("window states, menu commands as knowledge and routes: not recorded by this build's producers")
    }

    // MARK: Helpers

    /// A bundle ID with the name the Mac knows it by, and whether it is installed or running.
    private func label(_ bundleID: String) -> String {
        let running = directory.running().first { $0.bundleID == bundleID }
        let installed = directory.installedName(bundleID)
        let name = installed ?? running?.name
        let presence = installed == nil ? (running == nil ? "not installed" : "running") : (running == nil ? "installed" : "running")
        return (name.map { "\($0) (\(bundleID)" } ?? "(\(bundleID)") + ", \(presence))"
    }

    /// A read that failed is said as a failure of the archive, never as an empty answer.
    private func read<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() }
        catch { throw MemoryDiagnosisError.unavailable(MemoryService.describe(error)) }
    }
}
