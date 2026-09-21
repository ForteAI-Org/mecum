import XCTest
import Foundation
@testable import LocatorCore

final class KnowledgeStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testMutateCreatesLoadsAndSaves() throws {
        let store = KnowledgeStore(directory: tempDir())
        let n: Int = try store.mutate(bundleID: "com.x.app") { app in app.brain.ingestEpoch = 7; return app.brain.ingestEpoch }
        XCTAssertEqual(n, 7)
        XCTAssertEqual(try store.load(bundleID: "com.x.app")?.brain.ingestEpoch, 7)
        try store.mutate(bundleID: "com.x.app") { $0.brain.ingestEpoch += 1 }
        XCTAssertEqual(try store.load(bundleID: "com.x.app")?.brain.ingestEpoch, 8)
    }

    /// Eight writers, 25 increments each, from concurrent threads: a lost update would show as < 200.
    func testConcurrentMutationsNeverLoseAnUpdate() throws {
        let store = KnowledgeStore(directory: tempDir())
        try store.mutate(bundleID: "com.x.app") { $0.brain.ingestEpoch = 0 }
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<25 { try? store.mutate(bundleID: "com.x.app") { $0.brain.ingestEpoch += 1 } }
        }
        XCTAssertEqual(try store.load(bundleID: "com.x.app")?.brain.ingestEpoch, 200)
    }

    func testFirstSaveOfADayKeepsABackupAndOldOnesArePruned() throws {
        let dir = tempDir(), store = KnowledgeStore(directory: dir)
        try store.save(AppKnowledge(bundleID: "com.x.app"))                       // nothing on disk yet → no backup
        let backups = dir.appendingPathComponent(".backup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path) && !((try? FileManager.default.contentsOfDirectory(atPath: backups.path))?.isEmpty ?? true))
        try store.save(AppKnowledge(bundleID: "com.x.app", brain: UIBrain(ingestEpoch: 1)))   // overwrites → today's backup
        try store.save(AppKnowledge(bundleID: "com.x.app", brain: UIBrain(ingestEpoch: 2)))   // same day → no second backup
        let files = try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { $0.hasPrefix("com.x.app.") }
        XCTAssertEqual(files.count, 1)
        // The backup holds the PREVIOUS version (epoch 0), not the one being written.
        let data = try Data(contentsOf: backups.appendingPathComponent(files[0]))
        XCTAssertEqual(try DescriptorStore.makeDecoder().decode(AppKnowledge.self, from: data).brain.ingestEpoch, 0)
        // An old backup is pruned.
        let stale = backups.appendingPathComponent("com.x.app.2020-01-01.json")
        try data.write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86400)], ofItemAtPath: stale.path)
        KnowledgeStore.backupIfNeeded(current: dir.appendingPathComponent("com.x.app.json"), bundleID: "com.x.app", in: dir,
                                      now: Date(timeIntervalSinceNow: 86400))   // "tomorrow" → a new backup, and the prune runs
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }

    func testBrainEpochRoundTripsAndLegacyDecodesToZero() throws {
        let enc = DescriptorStore.makeEncoder(), dec = DescriptorStore.makeDecoder()
        let app = AppKnowledge(bundleID: "com.x.app", brain: UIBrain(ingestEpoch: 42))
        XCTAssertEqual(try dec.decode(AppKnowledge.self, from: enc.encode(app)).brain.ingestEpoch, 42)
        let legacy = Data(#"{"bundleID":"com.x.app","windows":[],"menuCommands":[],"routes":[],"brain":{"objects":[],"groups":[],"transitions":[]}}"#.utf8)
        XCTAssertEqual(try dec.decode(AppKnowledge.self, from: legacy).brain.ingestEpoch, 0)
    }

    /// Write-behind: a mutation is visible to every load at once and reaches disk on flush.
    func testMutateIsVisibleImmediatelyAndReachesDiskOnFlush() throws {
        let dir = tempDir(), store = KnowledgeStore(directory: dir)
        try store.mutate(bundleID: "com.x.wb") { $0.brain.ingestEpoch = 3 }
        XCTAssertEqual(try store.load(bundleID: "com.x.wb")?.brain.ingestEpoch, 3, "pending copy wins")
        let file = dir.appendingPathComponent("com.x.wb.json")
        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let onDisk = try DescriptorStore.makeDecoder().decode(AppKnowledge.self, from: Data(contentsOf: file))
        XCTAssertEqual(onDisk.brain.ingestEpoch, 3)
    }

    /// A corrupt file is quarantined and the newest daily backup restored — writing never silently stops.
    func testCorruptFileIsQuarantinedAndRecoveredFromBackup() throws {
        let dir = tempDir(), store = KnowledgeStore(directory: dir)
        try store.save(AppKnowledge(bundleID: "com.x.bad", brain: UIBrain(ingestEpoch: 5)))
        try store.save(AppKnowledge(bundleID: "com.x.bad", brain: UIBrain(ingestEpoch: 6)))   // makes today's backup (epoch 5)
        let file = dir.appendingPathComponent("com.x.bad.json")
        try Data("{not json".utf8).write(to: file)
        KnowledgeMemo.shared.put(file.path, mtime: Date(timeIntervalSince1970: 0), size: 0, app: AppKnowledge(bundleID: "poison"))   // stale memo must not mask the corruption
        let epoch: Int = try store.mutate(bundleID: "com.x.bad") { $0.brain.ingestEpoch += 1; return $0.brain.ingestEpoch }
        XCTAssertEqual(epoch, 6, "restored from the backup (5) and mutated")
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("corrupt") }
        XCTAssertEqual(quarantined.count, 1)
    }
}
