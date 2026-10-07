//
//  SQLiteRecoveryCoordinationTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Synchronization
import Testing

/// C09: a recovery moves an archive's files only while nobody holds them. Real processes through
/// `memory-probe` hold, open, diagnose and recover synthetic archives; every order of events is
/// decided on a line a helper answers, and a crash is a real `SIGKILL`. No personal archive is
/// touched and no live file is corrupted: the corrupt archives are fixtures made for the test.
@Suite("Recovering an archive while other processes hold it", .serialized)
struct SQLiteRecoveryCoordinationTests {

    /// A corrupt archive with a sound copy beside it holding one known row: the archive's own state
    /// before the corruption, as the day's copy keeps it.
    private func corruptWithCopy() async throws -> (url: URL, copy: String) {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url)
        _ = try await store.write { try $0.execute("INSERT INTO brain_apps (bundle_id) VALUES ('com.example.kept')") }
        let copy = "\(url.lastPathComponent).backup-2026-10-07T000000.000Z"
        _ = try await store.snapshot(to: url.deletingLastPathComponent().appendingPathComponent(copy))
        await store.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        try Data(repeating: 0x5A, count: 8192).write(to: url)
        return (url, copy)
    }

    private func inode(_ url: URL) throws -> UInt64? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    private func kept(in url: URL) async throws -> Int64 {
        let store = try await SQLiteMemoryStore.open(at: url)
        defer { Task { await store.close() } }
        return try await count("SELECT count(*) FROM brain_apps WHERE bundle_id = 'com.example.kept'", in: store)
    }

    @Test("a recovery asked while another process holds the archive open is refused and moves nothing; that process's later writes land in the same file")
    func refusedWhileAnotherProcessHoldsIt() async throws {
        let url    = try temporaryDatabase()
        let holder = try ProbeProcess()
        defer { holder.end() }
        #expect(try await holder.ask("open \(url.path)").hasPrefix("opened "))
        #expect(try await holder.ask("record e1 k1 100") == "committed")
        let before = try inode(url)

        #expect(try SQLiteMemoryRecovery.recover(url, copies: { [] }, stamp: "refused") == .inUse)
        #expect(try strayFiles(beside: url).isEmpty, "nothing was moved aside or copied")
        #expect(try inode(url) == before, "the file the holder writes is still the archive")

        #expect(try await holder.ask("record e2 k2 100") == "committed")
        #expect(try await holder.ask("close") == "closed")
        #expect(try rawCount("SELECT count(*) FROM memory_events", at: url) == 2, "no write went to another generation")
    }

    @Test("two recoveries that both saw the old error before the lock: one recovers, the other is refused while it works and then finds the archive sound and leaves it; an open and a diagnosis meanwhile wait or say so")
    func twoRecoveriesThatSawTheOldError() async throws {
        let (url, copy) = try await corruptWithCopy()
        let first  = try ProbeProcess()
        let second = try ProbeProcess()
        defer { first.end(); second.end() }
        let sawFirst  = try await first.ask("recover-after \(url.path) hold")
        let sawSecond = try await second.ask("recover-after \(url.path)")
        #expect(sawFirst.contains("code=26") && sawSecond.contains("code=26"), "\(sawFirst) / \(sawSecond)")

        first.send("go")
        #expect(try await first.expect("holding") == "holding")
        second.send("go")
        #expect(try await second.expect("the second recovery") == "recovery inUse")

        let opening = await storeError {
            _ = try await SQLiteMemoryStore.open(at: url, configuration: .init(lockBudget: .milliseconds(50)))
        }
        guard case .contention(let fault, _, _)? = opening else {
            Issue.record("an open during the recovery: \(String(describing: opening))")
            return
        }
        #expect(fault.phase == .open && fault.message.contains("recovery"))
        let diagnosis = try await second.ask("inspect \(url.path)")
        #expect(diagnosis == "inspect unavailable version=none", "a diagnosis in a third process reads nothing")

        first.send("release")
        let recovered = try await first.expect(prefix: "recovery ")
        let aside     = "\(url.lastPathComponent).corrupt-probe-\(first.process.processIdentifier)"
        #expect(recovered == "recovery recovered aside=\(aside) restored=\(copy)")
        #expect(try await second.ask("recover \(url.path)") == "recovery notCorrupt",
                "the recovered archive is not put aside on the strength of the old error")
        #expect(try strayFiles(beside: url).filter { $0.contains(".corrupt-") } == [aside], "one generation moved aside")
        #expect(try Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(aside)) == Data(repeating: 0x5A, count: 8192))
        #expect(try await kept(in: url) == 1, "the copy's data is back")
    }

    @Test("a process killed while it holds the archive, exclusive or shared, leaves no lock behind: the next one proceeds at once")
    func deathReleasesTheLock() async throws {
        let (url, _) = try await corruptWithCopy()
        let recovering = try ProbeProcess()
        defer { recovering.end() }
        #expect(try await recovering.ask("recover-after \(url.path) hold").contains("code=26"))
        recovering.send("go")
        #expect(try await recovering.expect("holding") == "holding")
        recovering.kill()
        _ = try await recovering.exit()
        #expect(try SQLiteMemoryRecovery.recover(url, copies: { [] }, stamp: "after-kill") == .notCorrupt)

        let holding = try ProbeProcess()
        defer { holding.end() }
        #expect(try await holding.ask("open \(url.path)").hasPrefix("opened "))
        #expect(try SQLiteMemoryRecovery.recover(url, copies: { [] }, stamp: "held") == .inUse)
        holding.kill()
        _ = try await holding.exit()
        #expect(try SQLiteMemoryRecovery.recover(url, copies: { [] }, stamp: "after-kill") == .notCorrupt)
        #expect(try await kept(in: url) == 1)
    }

    @Test("a copy still letting go of its connections after the store closed keeps the archive held until it has")
    func copyStillCleaningUpHoldsTheArchive() async throws {
        let url   = try temporaryDatabase()
        let store = try await SQLiteMemoryStore.open(at: url, configuration: .init(snapshotPagesPerStep: 1))
        let between = StepGate()
        await store.holdSnapshots { await between.pass() }
        let destination = url.deletingLastPathComponent().appendingPathComponent("copy.sqlite")
        let copying = Task { try await store.snapshot(to: destination) }
        #expect(await between.reached(), "the copy is between two steps")

        await store.close()
        #expect(await store.holdsPresence, "the copy's two connections are still open")
        #expect(await store.liveHandles == 2)
        #expect(try SQLiteMemoryRecovery.recover(url, copies: { [] }, stamp: "early") == .inUse)

        between.open()
        if case .success = await copying.result { Issue.record("a copy that found its store closed was handed over") }
        let holds = await store.holdsPresence, handles = await store.liveHandles
        #expect(!holds && handles == 0)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try SQLiteMemoryRecovery.recover(url, copies: { [] }, stamp: "late") == .notCorrupt)
    }
}

/// StepGate holds a snapshot between two of its steps until the test opens it.
final class StepGate: Sendable {

    private let opened  = Mutex(false)
    private let arrived = Mutex(0)

    func pass() async {
        arrived.withLock { $0 += 1 }
        while !opened.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func open() { opened.withLock { $0 = true } }

    func reached(within limit: Duration = .seconds(5)) async -> Bool {
        let start = ContinuousClock.now
        while arrived.withLock({ $0 }) == 0 {
            guard start.duration(to: .now) < limit else { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }
}
