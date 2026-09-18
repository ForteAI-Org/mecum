//
//  FileKnowledgeStoreTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

@testable import FileKnowledge
import Foundation
import Memory
import PerceptionCore
import Synchronization
import Testing

@Suite("The file-backed knowledge store")
struct FileKnowledgeStoreTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-knowledge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ directory: URL, now: Date? = nil, diagnostics: @escaping @Sendable (String) -> Void = { _ in }) -> FileKnowledgeStore {
        let clock = now ?? t0
        return FileKnowledgeStore(directory: directory, clock: { clock }, flushDelay: .seconds(60), diagnostics: diagnostics)
    }

    private func onDisk(_ directory: URL, _ bundleID: String) throws -> AppKnowledge {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(bundleID).json"))
        return try KnowledgeCoding.makeDecoder().decode(AppKnowledge.self, from: data)
    }

    @Test("save and load round-trip exactly, an absent application is nil, and bundles are listed")
    func roundTrip() async throws {
        let directory = try directory(), store = store(directory)
        #expect(try await store.load(bundleID: "com.x") == nil)
        var app = AppKnowledge(bundleID: "com.avid.ProTools")
        app.observe(windowTitlePattern: "Edit", objects: [
            ObservedObject(identityKey: "a", selfText: "Audio 3", role: "AXButton", source: .ax,
                           boundsNormalized: .zero, firstSeen: t0, lastSeen: t0)], now: t0)
        try await store.save(app)
        #expect(try await store.load(bundleID: "com.avid.ProTools") == app)
        #expect(try onDisk(directory, "com.avid.ProTools") == app)
        try FileAllowlistStore(directory: directory).save(Allowlist())
        #expect(try await store.bundleIDs() == ["com.avid.ProTools"])
    }

    @Test("mutate creates, is visible at once, and reaches disk on flush")
    func writeBehind() async throws {
        let directory = try directory(), store = store(directory)
        let epoch: Int = try await store.mutate(bundleID: "com.x.app") { app in
            app.brain.ingestEpoch = 7
            return app.brain.ingestEpoch
        }
        #expect(epoch == 7)
        #expect(try await store.load(bundleID: "com.x.app")?.brain.ingestEpoch == 7)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("com.x.app.json").path))
        try await store.mutate(bundleID: "com.x.app") { $0.brain.ingestEpoch += 1 }
        await store.flush()
        #expect(try onDisk(directory, "com.x.app").brain.ingestEpoch == 8)
    }

    @Test("a pending change is flushed on its own after the delay")
    func scheduledFlush() async throws {
        let directory = try directory()
        let store = FileKnowledgeStore(directory: directory, clock: { self.t0 }, flushDelay: .milliseconds(50), diagnostics: { _ in })
        try await store.mutate(bundleID: "com.x.app") { $0.brain.ingestEpoch = 3 }
        let file = directory.appendingPathComponent("com.x.app.json")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try onDisk(directory, "com.x.app").brain.ingestEpoch == 3)
    }

    @Test("eight writers and two hundred increments lose nothing")
    func concurrent() async throws {
        let store = store(try directory())
        try await store.mutate(bundleID: "com.x.app") { $0.brain.ingestEpoch = 0 }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<25 { try? await store.mutate(bundleID: "com.x.app") { $0.brain.ingestEpoch += 1 } }
                }
            }
        }
        #expect(try await store.load(bundleID: "com.x.app")?.brain.ingestEpoch == 200)
    }

    @Test("the first save of a day keeps a backup of the previous version and old backups are pruned")
    func backups() async throws {
        let directory = try directory(), store = store(directory)
        let backups = directory.appendingPathComponent(".backup")
        try await store.save(AppKnowledge(bundleID: "com.x.app"))
        let afterFirst = (try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []
        #expect(afterFirst.isEmpty, "nothing on disk yet, so nothing to back up")
        try await store.save(AppKnowledge(bundleID: "com.x.app", brain: UIBrain(ingestEpoch: 1)))
        try await store.save(AppKnowledge(bundleID: "com.x.app", brain: UIBrain(ingestEpoch: 2)))
        let files = try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { $0.hasPrefix("com.x.app.") }
        #expect(files.count == 1)
        let backedUp = try KnowledgeCoding.makeDecoder().decode(AppKnowledge.self,
                                                                 from: Data(contentsOf: backups.appendingPathComponent(files[0])))
        #expect(backedUp.brain.ingestEpoch == 0)

        let stale = backups.appendingPathComponent("com.x.app.2020-01-01.json")
        try Data("{}".utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(-30 * 86400)], ofItemAtPath: stale.path)
        FileKnowledgeStore.backupIfNeeded(current: directory.appendingPathComponent("com.x.app.json"), bundleID: "com.x.app",
                                          in: directory, now: t0.addingTimeInterval(86400), keepDays: 14)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
    }

    @Test("a corrupt file is quarantined, the newest backup restored, and the event reported")
    func corruptRecovery() async throws {
        let directory = try directory()
        let lines = Diagnostics()
        let store = store(directory) { line in lines.append(line) }
        try await store.save(AppKnowledge(bundleID: "com.x.bad", brain: UIBrain(ingestEpoch: 5)))
        try await store.save(AppKnowledge(bundleID: "com.x.bad", brain: UIBrain(ingestEpoch: 6)))
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("com.x.bad.json"))
        let fresh = self.store(directory) { line in lines.append(line) }
        let epoch: Int = try await fresh.mutate(bundleID: "com.x.bad") { app in
            app.brain.ingestEpoch += 1
            return app.brain.ingestEpoch
        }
        #expect(epoch == 6, "restored from the backup at epoch 5, then mutated")
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains("corrupt") }
        #expect(quarantined.count == 1)
        let reported = lines.all
        #expect(reported.count == 2)
        #expect(reported.first?.contains("quarantined") == true)
        #expect(reported.last?.contains("restored") == true)
    }

    @Test("the allowlist store reads the default when absent and round-trips otherwise")
    func allowlist() throws {
        let directory = try directory()
        let store = FileAllowlistStore(directory: directory)
        #expect(store.load().allows("com.avid.ProTools"))
        try store.save(Allowlist(bundleIDs: ["com.avid.ProTools"], allowAll: false))
        #expect(store.load().allows("com.avid.ProTools"))
        #expect(!store.load().allows("com.apple.Safari"))
        #expect(!store.load().allowsActive("com.avid.ProTools"))
    }
}

/// Diagnostics collects the lines a store reports, from any thread; the mutex is the invariant.
private final class Diagnostics: Sendable {

    private let lines = Mutex<[String]>([])

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var all: [String] {
        lines.withLock { $0 }
    }
}
