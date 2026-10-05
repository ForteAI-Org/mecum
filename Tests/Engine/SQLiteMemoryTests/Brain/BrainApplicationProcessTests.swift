//
//  BrainApplicationProcessTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// The application contract across real processes: `memory-probe` applies an observation through
/// `SQLiteBrainApplicationRepository` in a process of its own, and this process offers the very same
/// command by its key. Neither a crash after the commit nor two processes at once counts it twice.
@Suite("Brain applications across processes", .serialized)
struct BrainApplicationProcessTests {

    private typealias A = BrainApplicationFixtures

    private let requestedMS: Int64 = 1_700_000_000_000

    private func command(_ sample: CaptureSampleKey) throws -> BrainApplicationCommand {
        try A.observe(sample, A.controls(["Send", "Draft", "Discard"]), at: Date(timeIntervalSince1970: Double(requestedMS) / 1000))
    }

    @Test("a process that dies after committing an application and before answering: the same key answers alreadyApplied and nothing counts twice")
    func diedAfterCommit() async throws {
        let memory = try await A.open()
        try await memory.event("e1")
        let sample = try await memory.sample("e1")
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(memory.url.path)").hasPrefix("opened "))
        await probe.send("brain-observe-and-die \(A.bundle) e1 after 0 \(requestedMS) Send,Draft,Discard")
        #expect(try await probe.receive(waitingFor: "the end of the helper's output") == nil)
        #expect(try await probe.exit()?.reason == .uncaughtSignal)
        let retried = try await memory.applications.apply(try command(sample))
        #expect(retried.receipt == .alreadyApplied && retried.outcome == .observed(created: 3, updated: 0, skippedAmbiguous: 0))
        #expect(try await memory.count("SELECT count(*) FROM brain_applications") == 1)
        #expect(try await memory.brain()?.objects.map(\.seenCount) == [1, 1, 1])
        #expect(try await memory.count("SELECT count(*) FROM brain_evidence") == 4)
        await memory.store.close()
    }

    @Test("two processes offering one key at once conclude it once")
    func twoProcessesOneKey() async throws {
        let memory = try await A.open()
        try await memory.event("e1")
        let sample = try await memory.sample("e1")
        let probe = try ProbeProcess()
        defer { probe.end() }
        #expect(try await probe.ask("open \(memory.url.path)").hasPrefix("opened "))
        await probe.send("brain-observe \(A.bundle) e1 after 0 \(requestedMS) Send,Draft,Discard")
        let local = try await memory.applications.apply(try command(sample))
        let remote = try #require(try await probe.receive(waitingFor: "the helper's application"))
        let receipts = [local.receipt == .committed ? "committed" : "alreadyApplied", String(remote.split(separator: " ").first ?? "")]
        #expect(receipts.sorted() == ["alreadyApplied", "committed"], Comment(rawValue: remote))
        #expect(remote.contains("id=\(local.applicationID) ") && remote.contains("created=3"))
        #expect(try await memory.count("SELECT count(*) FROM brain_applications") == 1)
        #expect(try await memory.brain()?.objects.map(\.seenCount) == [1, 1, 1])
        #expect(try await probe.ask("brain-observe \(A.bundle) e1 after 0 \(requestedMS) Send,Draft,Discard").hasPrefix("alreadyApplied id=\(local.applicationID) "))
        #expect(try await probe.ask("brain-observe \(A.bundle) e1 after 0 \(requestedMS + 1) Send,Draft,Discard") == "error identity",
                "another requested instant under the key is a conflict in the other process too")
        await memory.store.close()
    }
}
