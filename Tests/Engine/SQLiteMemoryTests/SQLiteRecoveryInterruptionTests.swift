//
//  SQLiteRecoveryInterruptionTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 08/10/2026.
//

import Foundation
import Memory
@testable import SQLiteMemory
import Testing

/// T13b: a recovery stopped between its file operations never leaves an empty archive behind as if
/// nothing happened. A real `memory-probe` stops at a chosen stage and is killed there, or meets a
/// copy it cannot read; the next opens either complete the recovery from its record, with the copy's
/// data, or refuse and say why, with every file kept. None of them answers `bootstrapped=1` on the
/// recovered archive. Synthetic fixtures only.
@Suite("Recovering after a recovery that stopped half way", .serialized)
struct SQLiteRecoveryInterruptionTests {

    private typealias A = BrainApplicationFixtures

    /// A corrupt archive and its sound copy, which holds one event, one sample of it and the Brain an
    /// observation of three controls taught.
    private struct Fixture {
        let url : URL
        let copy: String
        let copyBytes: Data
        let garbage = Data(repeating: 0x5A, count: 8192)

        var directory: URL { url.deletingLastPathComponent() }
        var record: String { url.path + ".recovering" }
        var copyURL: URL { directory.appendingPathComponent(copy) }
    }

    private func fixture(withCopy: Bool = true) async throws -> Fixture {
        let memory = try await A.open()
        try await memory.event("e1")
        let sample = try await memory.sample("e1")
        _ = try await memory.applications.apply(try A.observe(sample, A.controls(["Send", "Draft", "Discard"]), at: A.t0))
        let copy = "\(memory.url.lastPathComponent).backup-2026-10-07T000000.000Z"
        if withCopy { _ = try await memory.store.snapshot(to: memory.url.deletingLastPathComponent().appendingPathComponent(copy)) }
        await memory.store.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: memory.url.path + suffix) }
        let fixture = Fixture(url: memory.url, copy: copy,
                              copyBytes: withCopy ? try Data(contentsOf: memory.url.deletingLastPathComponent().appendingPathComponent(copy)) : Data())
        try fixture.garbage.write(to: fixture.url)
        return fixture
    }

    /// The copy is as it was, and the corrupt original is kept, at the archive's place or aside.
    private func preserved(_ fixture: Fixture, withCopy: Bool = true) throws {
        if withCopy { #expect(try Data(contentsOf: fixture.copyURL) == fixture.copyBytes, "the copy is unchanged") }
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        let originals = try names.filter { name in
            let file = fixture.directory.appendingPathComponent(name)
            return (try? Data(contentsOf: file)) == fixture.garbage
        }
        #expect(originals.count == 1, "the corrupt original is kept once: \(names.sorted())")
    }

    /// The copy's data, read by a reader that never makes an archive.
    private func expectCopysData(at url: URL) async throws {
        let store = try await SQLiteMemoryStore.open(at: url)
        defer { Task { await store.close() } }
        #expect(!(try await store.diagnostics().bootstrappedNow))
        #expect(try await count("SELECT count(*) FROM memory_events WHERE event_id = 'e1'", in: store) == 1)
        #expect(try await count("SELECT count(*) FROM memory_event_observations WHERE observation_kind = 'capture' AND event_id = 'e1'", in: store) == 1)
        #expect(try await count("SELECT count(*) FROM brain_applications", in: store) == 1)
        #expect(try await SQLiteBrainRepository(store: store).brain(of: A.bundle)?.objects.count == 3)
    }

    /// Stops a recovery at the stage in a helper and kills it there.
    private func killed(at stage: String, _ fixture: Fixture) async throws {
        let helper = try ProbeProcess()
        defer { helper.end() }
        #expect(try await helper.ask("recover-stop \(fixture.url.path) \(stage)") == "stopped \(stage)")
        helper.kill()
        _ = try await helper.exit()
    }

    /// An open and a diagnosis after the interruption: both say a recovery stopped, and no archive is made.
    private func openIsRefused(_ fixture: Fixture) async throws {
        let before = FileManager.default.fileExists(atPath: fixture.url.path) ? try Data(contentsOf: fixture.url) : nil
        let helper = try ProbeProcess()
        defer { helper.end() }
        let answer = try await helper.ask("open \(fixture.url.path)")
        #expect(answer.hasPrefix("error unavailable interruptedRecovery"), "\(answer)")
        #expect(try await helper.ask("inspect \(fixture.url.path)") == "inspect interruptedRecovery version=none",
                "the diagnosis says a recovery stopped and reads nothing")
        let after = FileManager.default.fileExists(atPath: fixture.url.path) ? try Data(contentsOf: fixture.url) : nil
        #expect(after == before, "the open made or changed nothing at the archive's place")
        #expect(FileManager.default.fileExists(atPath: fixture.record), "the record stays")
    }

    /// The next open as the memory service does it: completes the recovery and opens the copy's data.
    private func reopenCompletes(_ fixture: Fixture) async throws {
        let helper = try ProbeProcess()
        defer { helper.end() }
        helper.send("open-recovering \(fixture.url.path)")
        let recovery = try await helper.expect(prefix: "recovery ")
        #expect(recovery.hasPrefix("recovery resumed aside=") && recovery.hasSuffix("restored=\(fixture.copy)"), "\(recovery)")
        #expect(try await helper.expect(prefix: "opened ").hasPrefix("opened bootstrapped=0 version=1"))
        #expect(try await helper.ask("close") == "closed")
        #expect(!FileManager.default.fileExists(atPath: fixture.record), "the record is gone once complete")
        try preserved(fixture)
        try await expectCopysData(at: fixture.url)
    }

    @Test("killed after the record and before anything moved: an open refuses, the next recovery completes it")
    func killedAfterTheRecord() async throws {
        let fixture = try await fixture()
        try await killed(at: "recorded", fixture)
        #expect(try Data(contentsOf: fixture.url) == fixture.garbage, "nothing moved yet")
        try await openIsRefused(fixture)
        try await reopenCompletes(fixture)
    }

    @Test("killed with the files aside and no copy in place: no empty archive is made, the next recovery puts the recorded copy back")
    func killedBeforePublication() async throws {
        let fixture = try await fixture()
        try await killed(at: "movedAside", fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path), "the archive's place is empty")
        try preserved(fixture)
        try await openIsRefused(fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path), "and stays empty after the refused open")
        try await reopenCompletes(fixture)
    }

    @Test("killed with the copy in place and the record still there: an open refuses until the next recovery confirms the copy and removes the record")
    func killedAfterPublication() async throws {
        let fixture = try await fixture()
        try await killed(at: "published", fixture)
        #expect(try Data(contentsOf: fixture.url) == fixture.copyBytes, "the copy is in place")
        try await openIsRefused(fixture)
        try await reopenCompletes(fixture)
    }

    @Test("the copy cannot be read once the files moved: the recovery stops with an explicit error, the opens refuse, and it completes once the copy reads again")
    func copyFailsAfterTheFilesMoved() async throws {
        let fixture = try await fixture()
        let helper  = try ProbeProcess()
        defer { helper.end() }
        #expect(try await helper.ask("recover-stop \(fixture.url.path) movedAside") == "stopped movedAside")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.copyURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.copyURL.path) }
        let failed = try await helper.ask("continue")
        #expect(failed.hasPrefix("error unavailable interruptedRecovery") && failed.contains(fixture.copy), "\(failed)")
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path) && FileManager.default.fileExists(atPath: fixture.record))

        let again = try await helper.ask("open-recovering \(fixture.url.path)")
        #expect(again.hasPrefix("error unavailable interruptedRecovery") && again.contains("cannot be completed"), "\(again)")
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path), "no empty archive in its place")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.copyURL.path)
        try preserved(fixture)
        try await reopenCompletes(fixture)
    }

    @Test("two processes restarting at once on a recovery that stopped: one completes it, neither makes an empty archive, both open the copy's data")
    func twoRestartsAtOnce() async throws {
        let fixture = try await fixture()
        try await killed(at: "movedAside", fixture)
        let first  = try ProbeProcess()
        let second = try ProbeProcess()
        defer { first.end(); second.end() }
        first.send("open-recovering \(fixture.url.path)")
        second.send("open-recovering \(fixture.url.path)")
        var lines: [String] = []
        for helper in [first, second] {
            while true {
                let line = try await helper.expect("the helper's open")
                lines.append(line)
                if line.hasPrefix("opened ") || line.hasPrefix("error ") { break }
            }
        }
        #expect(lines.filter { $0.hasPrefix("opened bootstrapped=0") }.count == 2, "\(lines)")
        #expect(!lines.contains { $0.contains("bootstrapped=1") }, "\(lines)")
        #expect(lines.filter { $0.hasPrefix("recovery resumed") }.count == 1, "\(lines)")
        #expect(try await first.ask("close") == "closed")
        #expect(try await second.ask("close") == "closed")
        try preserved(fixture)
        try await expectCopysData(at: fixture.url)
    }

    @Test("an open while another process completes the stopped recovery waits for it or says so, and never makes an archive")
    func openDuringTheCompletion() async throws {
        let fixture = try await fixture()
        try await killed(at: "movedAside", fixture)
        let completing = try ProbeProcess()
        let opening    = try ProbeProcess()
        defer { completing.end(); opening.end() }
        completing.send("open-recovering \(fixture.url.path) published")
        #expect(try await completing.expect("the stop") == "stopped published")
        let refused = try await opening.ask("open \(fixture.url.path) 100")
        #expect(refused.hasPrefix("error contention") && refused.contains("phase=open"), "the open waited for the presence lock: \(refused)")
        completing.send("continue")
        #expect(try await completing.expect(prefix: "recovery ").hasPrefix("recovery resumed"))
        #expect(try await completing.expect(prefix: "opened ").hasPrefix("opened bootstrapped=0"))
        #expect(try await opening.ask("open \(fixture.url.path)").hasPrefix("opened bootstrapped=0"))
    }

    @Test("a directory that is really new still makes its archive, and a corruption with no copy starts empty saying so, even after a stop")
    func newDirectoryAndNoCopy() async throws {
        let fresh  = try temporaryDatabase()
        let helper = try ProbeProcess()
        defer { helper.end() }
        #expect(try await helper.ask("open-recovering \(fresh.path)").hasPrefix("opened bootstrapped=1 version=1"))
        #expect(try await helper.ask("close") == "closed")
        #expect(!FileManager.default.fileExists(atPath: fresh.path + ".recovering"))

        let bare = try await fixture(withCopy: false)
        try await killed(at: "movedAside", bare)
        try await openIsRefused(bare)
        helper.send("open-recovering \(bare.url.path)")
        let recovery = try await helper.expect(prefix: "recovery ")
        #expect(recovery.hasPrefix("recovery resumed aside=") && recovery.hasSuffix("restored=none"),
                "the outcome says the memory starts empty: \(recovery)")
        #expect(try await helper.expect(prefix: "opened ").hasPrefix("opened bootstrapped=1"),
                "an empty archive only after the recovery said so, as the contract has it for a corruption with no copy")
        #expect(try await helper.ask("close") == "closed")
        #expect(!FileManager.default.fileExists(atPath: bare.record))
        try preserved(bare, withCopy: false)
    }
}
