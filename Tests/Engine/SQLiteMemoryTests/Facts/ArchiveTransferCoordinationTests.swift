//
//  ArchiveTransferCoordinationTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 10/10/2026.
//

import EngineCore
import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// ArchiveTransferCoordinationTests prove how one origin's transfer into the shared archive behaves when
/// several openers, in one process or in several, reach it at once (review F07 of plan D1): one transfer
/// at a time, each attempt with a copy of its own that no other touches, a copy that is lost or replaced
/// never certified, an empty origin told apart from a lost copy, a waiter that can be cancelled or give
/// up, a dead holder that blocks nothing, and an end certified without the facts taken again.
@Suite("One origin's transfer at a time, across openers and processes")
struct ArchiveTransferCoordinationTests {

    static let origin = "mcp-profile:A"

    /// An archive of schema 1 with a concluded call and an observation with its sample, under ids that
    /// start with `prefix`, written through this build's repositories and set back to schema 1.
    static func source(_ prefix: String) async throws -> URL {
        let memory = try await AgentCallFixtures.open()
        let call   = "\(prefix)-a1"
        _ = try await memory.calls.record(try AgentCallFixtures.call(
            call,
            .act(target: "Save", verb: .click, value: nil, section: nil)
        ))
        _ = try await memory.calls.advance([AgentCallTransition(call, .started(atMS: AgentCallFixtures.t0))])
        _ = try await memory.calls.advance([AgentCallTransition(call, AgentCallProgress(
            .completed, result: .outcome(.foundActed, message: "clicked 'Save'"), endedAtMS: AgentCallFixtures.t0 + 5
        ))])
        _ = try await memory.captures.record(SceneFixtures.event("\(prefix)-o1"))
        _ = try await memory.captures.record(SceneFixtures.sample(
            "\(prefix)-o1",
            of: SceneFixtures.pixelsOnly(["Save"])
        ))
        await memory.store.close()
        try SchemaMigrationTests.downgrade(memory.url)
        return memory.url
    }

    /// An archive of schema 1 with no facts at all.
    static func emptySource() async throws -> URL {
        let memory = try await AgentCallFixtures.open()
        await memory.store.close()
        try SchemaMigrationTests.downgrade(memory.url)
        return memory.url
    }

    /// One more event in an archive of schema 1, as a build before G76 would add it: a copy of `existing`
    /// under a new identity, at the next local order.
    static func append(_ id: String, copying existing: String, to url: URL) throws {
        let raw = try SQLiteConnection(path: url.path)
        defer { raw.close() }
        let columns = try raw.query("PRAGMA table_info(memory_events)") { try $0.text(1) ?? "" }
            .filter { $0 != "local_order" }
        // The identity and the source's own key are the new event's; the rest is the existing one's.
        let selected = columns.map { $0 == "event_id" ? "?1" : $0 == "source_key" ? "?1" : $0 }.joined(separator: ", ")
        _ = try raw.run(
            """
            INSERT INTO memory_events (\(columns.joined(separator: ", ")))
            SELECT \(selected) FROM memory_events WHERE event_id = ?2
            """,
            [.text(id), .text(existing)]
        )
    }

    static func destination() async throws -> (store: SQLiteMemoryStore, staging: URL) {
        let store = try await SQLiteMemoryStore.open(at: try temporaryDatabase())
        return (store, store.url.deletingLastPathComponent().appendingPathComponent("staging", isDirectory: true))
    }

    static func attempts(in staging: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
    }

    static func journal(_ store: SQLiteMemoryStore) async throws -> [String] {
        try await store.read { snapshot in
            try snapshot.query(
                "SELECT status || ':' || ifnull(detail, '-') FROM memory_archive_origins"
            ) { try $0.text(0) ?? "" }
        }
    }

    /// Gate holds a transfer at a stage until the test opens it, and tells the test once it is held.
    actor Gate {
        private var held: CheckedContinuation<Void, Never>?
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var reached = false
        private(set) var passes = 0

        func hold() async {
            passes += 1
            reached = true
            waiters.forEach { $0.resume() }
            waiters = []
            await withCheckedContinuation { held = $0 }
        }

        func pass() { passes += 1 }

        func untilHeld() async {
            guard !reached else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Opens the gate and lets every waiter go, held or not: what a test does whatever happened.
        func open() {
            reached = true
            held?.resume()
            held = nil
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    // MARK: Openers in one process

    @Test("a second opener of the same origin waits for the first, never touches its copy, and finds every fact transferred once: past its wait it gives up having done nothing")
    func twoOpenersOneAtATime() async throws {
        let source = try await Self.source("a")
        let (destination, staging) = try await Self.destination()
        let gate = Gate()
        defer { Task { await gate.open() } }
        let first = Task {
            try await SQLiteArchiveTransfer.transfer(
                from: source, origin: Self.origin, location: "A", into: destination, staging: staging, nowMS: 1,
                at: { stage in if stage == .copied { await gate.hold() } }
            )
        }
        Task { _ = await first.result; await gate.open() }
        await gate.untilHeld()
        let held = Self.attempts(in: staging)
        #expect(held.count == 1)
        await #expect(throws: SQLiteArchiveTransfer.TransferError.busy(origin: Self.origin)) {
            _ = try await SQLiteArchiveTransfer.transfer(
                from: source, origin: Self.origin, location: "A", into: destination, staging: staging, nowMS: 2,
                lockWait: .milliseconds(200), at: { stage in if stage == .copied { await gate.pass() } }
            )
        }
        #expect(Self.attempts(in: staging) == held, "the first attempt's copy is untouched")
        async let second = SQLiteArchiveTransfer.transfer(
            from: source, origin: Self.origin, location: "A", into: destination, staging: staging, nowMS: 3,
            at: { stage in if stage == .copied { await gate.pass() } }
        )
        await gate.open()
        let (a, b) = try await (first.value, second)
        #expect(a.status == "completed" && b.status == "completed" && a.eventsAdded == 2)
        #expect(await gate.passes == 1, "only the first attempt copied the origin")
        #expect(try await count("SELECT count(*) FROM memory_events", in: destination) == 2)
        #expect(try await count("SELECT count(*) FROM memory_origin_events WHERE origin_id = 'mcp-profile:A'",
                                in: destination) == 2)
        #expect(try await count("SELECT count(*) FROM memory_agent_actions WHERE execution_status = 'completed'",
                                in: destination) == 1)
        #expect(try await destination.read { try $0.query("PRAGMA foreign_key_check") { _ in () } }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staging.path), "no copy left behind")
        await destination.close()
    }

    enum Loss: String, CaseIterable, Sendable {
        case removed, emptied, replaced
    }

    @Test("a staging copy lost, emptied or replaced after it was verified is never certified: the attempt fails typed, nothing is written, and the next transfer takes every fact",
          arguments: Loss.allCases)
    func lostCopyNeverCompletes(loss: Loss) async throws {
        let source = try await Self.source("a")
        let (destination, staging) = try await Self.destination()
        await #expect {
            _ = try await SQLiteArchiveTransfer.transfer(
                from: source, origin: Self.origin, location: "A", into: destination, staging: staging, nowMS: 1,
                at: { stage in
                    guard stage == .copied, let attempt = Self.attempts(in: staging).first else { return }
                    let copy = attempt.appendingPathComponent("archive.sqlite")
                    switch loss {
                        case .removed:
                            // What another opener's cleanup of a shared directory did.
                            try FileManager.default.removeItem(at: staging)
                            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                        case .emptied:
                            try Data().write(to: copy)
                        case .replaced:
                            try FileManager.default.removeItem(at: copy)
                            await (try SQLiteMemoryStore.open(at: copy)).close()
                    }
                }
            )
        } throws: { error in
            if case SQLiteArchiveTransfer.TransferError.stagingLost = error { return true }
            return false
        }
        #expect(try await count("SELECT count(*) FROM memory_events", in: destination) == 0)
        #expect(try await Self.journal(destination).first?.hasPrefix("failed:") == true)
        let report = try await SQLiteArchiveTransfer.transfer(from: source, origin: Self.origin, location: "A",
                                                              into: destination, staging: staging, nowMS: 2)
        #expect(report.status == "completed" && report.eventsAdded == 2)
        await destination.close()
    }

    @Test("an origin whose archive holds no facts completes, and says so: it is told apart from a copy that was lost")
    func emptyOriginCompletes() async throws {
        let (destination, staging) = try await Self.destination()
        let report = try await SQLiteArchiveTransfer.transfer(
            from: try await Self.emptySource(),
            origin: Self.origin,
            location: "A",
            into: destination,
            staging: staging,
            nowMS: 1
        )
        #expect(report.status == "completed" && report.eventsAdded == 0)
        #expect(report.detail == "the origin's archive held no facts")
        await destination.close()
    }

    @Test("a waiter can be cancelled and gives up past its wait, writing nothing; once the holder ends, the transfer goes on")
    func waitingIsCancellableAndBounded() async throws {
        let source = try await Self.source("a")
        let (destination, staging) = try await Self.destination()
        let gate = Gate()
        defer { Task { await gate.open() } }
        let holder = Task {
            try await SQLiteArchiveTransfer.coordinated(
                destination: destination,
                origin: Self.origin,
                wait: .seconds(30)
            ) {
                await gate.hold()
            }
        }
        await gate.untilHeld()
        let waiter = Task {
            try await SQLiteArchiveTransfer.transfer(
                from: source,
                origin: Self.origin,
                location: "A",
                into: destination,
                staging: staging,
                nowMS: 1
            )
        }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiter.value }
        await #expect(throws: SQLiteArchiveTransfer.TransferError.busy(origin: Self.origin)) {
            _ = try await SQLiteArchiveTransfer.transfer(
                from: source,
                origin: Self.origin,
                location: "A",
                into: destination,
                staging: staging,
                nowMS: 2,
                lockWait: .milliseconds(150)
            )
        }
        #expect(try await Self.journal(destination).isEmpty, "a waiter writes nothing")
        await gate.open()
        try await holder.value
        let report = try await SQLiteArchiveTransfer.transfer(from: source, origin: Self.origin, location: "A",
                                                              into: destination, staging: staging, nowMS: 3)
        #expect(report.status == "completed" && report.eventsAdded == 2)
        await destination.close()
    }

    @Test("two origins transferred at once into one archive do not wait for each other and keep their own facts and mappings")
    func differentOrigins() async throws {
        let (a, b) = (try await Self.source("a"), try await Self.source("b"))
        let (destination, staging) = try await Self.destination()
        async let first  = SQLiteArchiveTransfer.transfer(from: a, origin: "mcp-profile:A", location: "A",
                                                          into: destination, staging: staging, nowMS: 1)
        async let second = SQLiteArchiveTransfer.transfer(from: b, origin: "mcp-profile:B", location: "B",
                                                          into: destination, staging: staging, nowMS: 1)
        let (reportA, reportB) = try await (first, second)
        #expect(reportA.status == "completed" && reportB.status == "completed")
        let mapped = try await destination.read { snapshot in
            try snapshot.query(
                "SELECT origin_id || '>' || event_id FROM memory_origin_events ORDER BY 1"
            ) { try $0.text(0) ?? "" }
        }
        #expect(mapped == ["mcp-profile:A>a-a1", "mcp-profile:A>a-o1", "mcp-profile:B>b-a1", "mcp-profile:B>b-o1"])
        #expect(try await destination.read { try $0.query("PRAGMA foreign_key_check") { _ in () } }.isEmpty)
        await destination.close()
    }

    // MARK: Ends to take again

    @Test("an origin a defect certified completed without its facts is taken again by the next transfer, and a further one takes nothing twice")
    func falseCompletedIsRecovered() async throws {
        let source = try await Self.source("a")
        let (destination, staging) = try await Self.destination()
        // The journal the lost copy left: completed, the source's last order recorded, no mapping.
        _ = try await destination.write { transaction in
            try transaction.execute(
                """
                INSERT INTO memory_archive_origins (origin_id, origin_kind, location, status, first_seen_at_ms,
                                                    updated_at_ms, high_local_order)
                VALUES (?, 'mcp_profile', 'A', 'completed', 1, 1, 2)
                """,
                [.text(Self.origin)]
            )
        }
        #expect(await SQLiteArchiveTransfer.needsTransfer(source: source, origin: Self.origin, into: destination))
        let report = try await SQLiteArchiveTransfer.transfer(from: source, origin: Self.origin, location: "A",
                                                              into: destination, staging: staging, nowMS: 2)
        #expect(report.status == "completed" && report.eventsAdded == 2)
        #expect(await !SQLiteArchiveTransfer.needsTransfer(source: source, origin: Self.origin, into: destination))
        let again = try await SQLiteArchiveTransfer.transfer(from: source, origin: Self.origin, location: "A",
                                                             into: destination, staging: staging, nowMS: 3)
        #expect(again.eventsAdded == 2, "nothing was taken twice")
        #expect(try await count("SELECT count(*) FROM memory_events", in: destination) == 2)
        await destination.close()
    }

    @Test("a source written to after its snapshot was taken: the transfer certifies the snapshot it read, and the next one takes the later fact once")
    func sourceChangedAfterSnapshot() async throws {
        let source = try await Self.source("a")
        let (destination, staging) = try await Self.destination()
        let gate = Gate()
        defer { Task { await gate.open() } }
        let first = Task {
            try await SQLiteArchiveTransfer.transfer(
                from: source, origin: Self.origin, location: "A", into: destination, staging: staging, nowMS: 1,
                at: { stage in if stage == .copied { await gate.hold() } }
            )
        }
        Task { _ = await first.result; await gate.open() }
        await gate.untilHeld()
        try Self.append("a-o2", copying: "a-o1", to: source)
        await gate.open()
        let report = try await first.value
        #expect(report.status == "completed" && report.eventsAdded == 2, "the snapshot, as read")
        #expect(await SQLiteArchiveTransfer.needsTransfer(source: source, origin: Self.origin, into: destination))
        let later = try await SQLiteArchiveTransfer.transfer(from: source, origin: Self.origin, location: "A",
                                                             into: destination, staging: staging, nowMS: 2)
        #expect(later.eventsAdded == 3)
        _ = try await SQLiteArchiveTransfer.transfer(from: source, origin: Self.origin, location: "A",
                                                     into: destination, staging: staging, nowMS: 3)
        #expect(try await count("SELECT count(*) FROM memory_events", in: destination) == 3)
        await destination.close()
    }

    // MARK: Openers in two processes

    @Test("two processes: while one holds the origin's transfer the other cannot take it, then finds every fact transferred once; the holder's copy is never touched")
    func twoProcesses() async throws {
        let source = try await Self.source("a")
        let (destination, staging) = try await Self.destination()
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(destination.url.path)").hasPrefix("opened "))
        probe.send("transfer \(source.path) \(Self.origin) \(staging.path) pause")
        #expect(try await probe.receive(waitingFor: "the helper's copy") == "copied")
        let held = Self.attempts(in: staging)
        #expect(held.count == 1)
        await #expect(throws: SQLiteArchiveTransfer.TransferError.busy(origin: Self.origin)) {
            _ = try await SQLiteArchiveTransfer.transfer(from: source, origin: Self.origin, location: "A",
                                                         into: destination, staging: staging, nowMS: 2,
                                                         lockWait: .milliseconds(200))
        }
        #expect(Self.attempts(in: staging) == held, "the helper's copy is untouched")
        let here = Task {
            try await SQLiteArchiveTransfer.transfer(
                from: source,
                origin: Self.origin,
                location: "A",
                into: destination,
                staging: staging,
                nowMS: 3
            )
        }
        probe.send("go")
        #expect(try await probe.receive(waitingFor: "the helper's transfer") == "transferred completed added=2")
        let report = try await here.value
        #expect(report.status == "completed")
        #expect(try await count("SELECT count(*) FROM memory_events", in: destination) == 2)
        #expect(try await count("SELECT count(*) FROM memory_origin_events", in: destination) == 2)
        await destination.close()
    }

    @Test("two processes: a holder killed half way blocks nobody; the next transfer clears its copy, takes the origin over and completes it")
    func holderKilled() async throws {
        let source = try await Self.source("a")
        let (destination, staging) = try await Self.destination()
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(destination.url.path)").hasPrefix("opened "))
        probe.send("transfer \(source.path) \(Self.origin) \(staging.path) pause")
        #expect(try await probe.receive(waitingFor: "the helper's copy") == "copied")
        #expect(try await Self.journal(destination).first?.hasPrefix("in_progress:attempt ") == true)
        probe.kill()
        _ = try await probe.exit()
        let report = try await SQLiteArchiveTransfer.transfer(from: source, origin: Self.origin, location: "A",
                                                              into: destination, staging: staging, nowMS: 2)
        #expect(report.status == "completed" && report.eventsAdded == 2)
        #expect(!FileManager.default.fileExists(atPath: staging.path), "the dead attempt's copy is gone")
        await destination.close()
    }
}
