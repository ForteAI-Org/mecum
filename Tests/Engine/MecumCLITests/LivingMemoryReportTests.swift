//
//  LivingMemoryReportTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import EngineCore
import Foundation
import Memory
@testable import mecum
import SQLite3
import SQLiteLivingMemory
import Testing

/// Synthetic stores in temporary knowledge directories; no application, provider or capture.
@Suite("The living memory inspector", .serialized)
struct LivingMemoryReportTests {

    private let phrase = "Seleziona Output Busses nel filtro della scheda Bus e verifica il nuovo valore."
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func file(_ knowledge: URL) -> URL {
        SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)
    }

    private func withKnowledge(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-inspector-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// Writes one verified experience, one correction, one recall decision and one sighting for `bundle`.
    private func fixture(_ store: SQLiteLivingMemoryStore, bundle: String, item: String,
                         withDecision: Bool = true) async throws {
        let context = WindowContext(bundleID: bundle, windowTitle: "Synthetic Routing")!
        let proof = DropdownEvidence(bundleID: bundle, windowTitle: "Synthetic Routing", control: "All Busses",
                                     controlRole: nil, section: nil, valueBefore: "All Busses", requestedItem: item,
                                     readback: .controlCrop(item), menuClosedByChoice: true)
        let draft = ExperienceDraft(phrase: phrase.replacingOccurrences(of: "Output Busses", with: item),
                                    step: ExperienceStep(proof), context: context)!
        let learned = try await store.record(ExperienceEvent(id: "\(bundle)-e1", subject: .step(draft),
                                                             outcome: .verified(proof), at: t0))
        let id = try #require(learned.experience?.id)
        _ = try await store.record(ExperienceEvent(id: "\(bundle)-e2", subject: .experience(id),
                                                   outcome: .contradicted(.userCorrection), at: t0 + 60))
        _ = try await store.recordSightings([SightingObservation(
            key: SightingKey(context: context, identity: .anchor("\(bundle)-anchor")), name: "All Busses",
            nameSource: .observed, seenAt: t0, observationBlock: 1)])
        guard withDecision else { return }
        try await store.record(RecallDecisionRecord(id: "\(bundle)-d1", at: t0 + 120, phrase: "Seleziona \(item)",
                                                    context: context, experienceID: id, verdict: .suggested,
                                                    reason: "sameStep match, notObserved"))
    }

    @Test("a stored experience is explained: window, request, step, proof, counts, history and decisions")
    func dataPresent() async throws {
        try await withKnowledge { knowledge in
            do {
                let store = try SQLiteLivingMemoryStore(file: Self.file(knowledge))
                try await fixture(store, bundle: "test.synthetic.mixer", item: "Output Busses")
            }
            let text = await report("test.synthetic.mixer", knowledge).joined(separator: "\n")
            #expect(text.contains("1 experiences, 1 sightings"))
            #expect(text.contains("sighted in window 'syntheticrouting': All Busses ×1"))
            #expect(text.contains("in window 'syntheticrouting'"))
            #expect(text.contains("request: \"\(phrase)\""))
            #expect(text.contains("step: select 'Output Busses' in the control that read 'All Busses'"))
            #expect(text.contains("verified ×1, contradicted ×1; last verified \(t0.ISO8601Format())"))
            #expect(text.contains("proof: 'All Busses' before, 'Output Busses' read in the control crop after"))
            #expect(text.contains("verified; \((t0 + 60).ISO8601Format()) contradicted (corrected by the user)"))
            #expect(text.contains("recall suggested \((t0 + 120).ISO8601Format()): sameStep match, notObserved"))
        }
    }

    @Test("the living memory is read even with no brain JSON, and records without decisions say so")
    func onlySQLite() async throws {
        try await withKnowledge { knowledge in
            do {
                let store = try SQLiteLivingMemoryStore(file: Self.file(knowledge))
                try await fixture(store, bundle: "test.synthetic.mixer", item: "Output Busses", withDecision: false)
            }
            let brainFiles = try FileManager.default.contentsOfDirectory(atPath: knowledge.path)
                .filter { $0.hasSuffix(".json") }
            #expect(brainFiles.isEmpty)
            let lines = await report("test.synthetic.mixer", knowledge)
            #expect(lines.contains("  recall decisions: none recorded yet"))
            #expect(!lines.joined().contains("recall suggested"))
        }
    }

    @Test("no store and no records for the application are distinct, and neither creates anything")
    func noData() async throws {
        try await withKnowledge { knowledge in
            let none = await report("test.synthetic.mixer", knowledge)
            #expect(none.first?.hasPrefix("living memory: nothing recorded yet (no store at") == true)
            #expect(!FileManager.default.fileExists(atPath: knowledge.path))
            do {
                let store = try SQLiteLivingMemoryStore(file: Self.file(knowledge))
                try await fixture(store, bundle: "test.synthetic.editor", item: "Stereo")
            }
            let other = await report("test.synthetic.mixer", knowledge)
            #expect(other.first?.hasPrefix("living memory: nothing recorded for test.synthetic.mixer") == true)
        }
    }

    @Test("two applications in one store are reported apart")
    func isolatedApplications() async throws {
        try await withKnowledge { knowledge in
            do {
                let store = try SQLiteLivingMemoryStore(file: Self.file(knowledge))
                try await fixture(store, bundle: "test.synthetic.mixer", item: "Output Busses")
                try await fixture(store, bundle: "test.synthetic.editor", item: "Stereo")
            }
            let mixer = await report("test.synthetic.mixer", knowledge)
                .joined(separator: "\n")
            #expect(mixer.contains("Output Busses"))
            #expect(!mixer.contains("Stereo"))
            #expect(!mixer.contains("test.synthetic.editor"))
            let editor = await report("test.synthetic.editor", knowledge)
                .joined(separator: "\n")
            #expect(editor.contains("Stereo"))
            #expect(!editor.contains("Output Busses"))
        }
    }

    @Test("an unsupported schema or a non-database is reported with the store's own error")
    func unreadableStore() async throws {
        try await withKnowledge { knowledge in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)
            do { _ = try SQLiteLivingMemoryStore(file: file) }
            var handle: OpaquePointer?
            #expect(sqlite3_open(file.path, &handle) == SQLITE_OK)
            #expect(sqlite3_exec(handle, "PRAGMA user_version = 99", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(handle)
            let newer = await report("test.synthetic.mixer", knowledge)
            #expect(newer == ["living memory: could not be read: the living memory store at \(file.path) "
                              + "has schema 99; this build supports up to 1"])
            try Data(repeating: 0x5A, count: 4096).write(to: file)
            let garbage = await report("test.synthetic.mixer", knowledge)
            #expect(garbage.first?.contains("is not a readable database") == true)
        }
    }

    @Test("inspecting leaves the database exactly as it was")
    func databaseUnchanged() async throws {
        try await withKnowledge { knowledge in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)
            do {
                let store = try SQLiteLivingMemoryStore(file: file)
                try await fixture(store, bundle: "test.synthetic.mixer", item: "Output Busses")
            }
            let before = try snapshot(file)
            let reader = try SQLiteLivingMemoryStore(file: file, access: .readOnly)
            let id = try #require(try await reader.experiences(in: ["test.synthetic.mixer"]).first?.id)
            let decisions = try await reader.decisions(about: id)
            for _ in 0..<3 {
                _ = await report("test.synthetic.mixer", knowledge)
            }
            #expect(try snapshot(file) == before)
            #expect(try await reader.decisions(about: id) == decisions)
        }
    }

    private func report(_ bundle: String, _ knowledge: URL) async -> [String] {
        await LivingMemoryReport.lines(bundleID: bundle, knowledgeDirectory: knowledge)
    }

    /// The store's data files: the database and, when present, its write-ahead log.
    private func snapshot(_ file: URL) throws -> [Data] {
        try [file, URL(fileURLWithPath: file.path + "-wal")]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { try Data(contentsOf: $0) }
    }
}
