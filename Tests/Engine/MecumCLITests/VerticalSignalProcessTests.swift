//
//  VerticalSignalProcessTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import AppKit
import AutomationRuntime
import Darwin
import Foundation
import SQLite3
import Testing

/// Real signals to a real `mecum`: the built product, in a process of its own, runs `scene` on Finder
/// without `--seat`, with its memory in a temporary Knowledge directory whose archive this test holds
/// with a write lock. The command waits on that lock while its memory opens, before its first call and
/// any perception, and the signal is sent there: SIGINT, SIGTERM, or SIGINT twice then SIGTERM. A stop
/// that lands in a call's `begin` is `VerticalStopTests`'. What it proves is the
/// path signal → `TerminalSignals` → `VerticalInvocation` stop → the command's task cancelled and
/// finished, cleanup included → the exit status, with nothing perceived and nothing recorded. The
/// signal goes to the child only, never to this runner. No Seat, no window, no capture: the Seat's
/// release under a stop is `VerticalStopTests`' with a stand-in, and the real window's is C9-A's.
@MainActor
@Suite("Vertical commands: real signals to a real mecum process", .serialized)
struct VerticalSignalProcessTests {

    /// The `mecum` built into the products directory beside this test bundle, found the way
    /// `memory-probe` is for the store's tests; `MECUM_CLI_EXECUTABLE` names another.
    private static var executable: URL? {
        if let named = ProcessInfo.processInfo.environment["MECUM_CLI_EXECUTABLE"], !named.isEmpty {
            return URL(fileURLWithPath: named)
        }
        var candidates: [URL] = []
        var directory = Bundle(for: BundleMarker.self).bundleURL
        for _ in 0..<6 {
            candidates.append(directory.appendingPathComponent("mecum"))
            directory = directory.deletingLastPathComponent()
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private final class BundleMarker {}

    private static var finderIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").isEmpty
    }

    /// What one run left: its status, the lines it wrote, the events its archive holds.
    private struct Run {
        let status: Int32
        let exitedNormally: Bool
        let output: String
        let errors: [String]
        let events: Int
        let afterSignal: Duration
    }

    /// Starts `mecum scene com.apple.finder` on a held archive, sends `signals` once it waits, and answers
    /// what it left. A process still running after the timeout is killed and reported as such.
    private static func run(sending signals: [Int32]) async throws -> Run {
        let mecum = try #require(executable, "mecum is not built beside the test bundle; run swift build --product mecum")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-signal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let knowledge = root.appendingPathComponent("Knowledge", isDirectory: true)
        let memory = MemoryService(directory: knowledge)
        _ = await memory.ready()
        await memory.close()
        var holder: OpaquePointer?
        try #require(sqlite3_open(memory.url.path, &holder) == SQLITE_OK)
        defer { sqlite3_close(holder) }
        try #require(sqlite3_exec(holder, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        let output = root.appendingPathComponent("stdout.txt"), errors = root.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let process = Process()
        process.executableURL = mecum
        process.arguments = ["scene", "com.apple.finder", "--knowledge", knowledge.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()

        // The memory's open waits for the lock held above, cycle after cycle, and says nothing until it
        // ends; a second lets the process reach that wait.
        try await Task.sleep(for: .seconds(1))
        #expect(process.isRunning, "mecum ended before the signal")
        #expect((try? String(contentsOf: errors, encoding: .utf8)) == "", "still waiting for its memory")
        let signalled = ContinuousClock.now
        for signal in signals {
            kill(process.processIdentifier, signal)
            try await Task.sleep(for: .milliseconds(30))
        }
        while process.isRunning, signalled.duration(to: .now) < .seconds(15) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let afterSignal = signalled.duration(to: .now)
        if process.isRunning {
            Issue.record("mecum did not exit within 15 s of the signal; killed")
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        sqlite3_exec(holder, "ROLLBACK", nil, nil, nil)
        var statement: OpaquePointer?
        var events: Int32 = -1
        if sqlite3_prepare_v2(holder, "SELECT count(*) FROM memory_events", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            events = sqlite3_column_int(statement, 0)
        }
        sqlite3_finalize(statement)
        let lines = (try String(contentsOf: errors, encoding: .utf8)).split(separator: "\n").map(String.init)
        return Run(status: process.terminationStatus, exitedNormally: process.terminationReason == .exit,
                   output: try String(contentsOf: output, encoding: .utf8), errors: lines, events: Int(events),
                   afterSignal: afterSignal)
    }

    private static func check(_ run: Run, status: Int32, signal: String) {
        print("SIGNAL-PROCESS \(signal) status=\(run.status) normal=\(run.exitedNormally) afterSignal=\(run.afterSignal) "
              + "events=\(run.events) stderr=\(run.errors)")
        #expect(run.exitedNormally, "the process exited by itself, not killed by the signal")
        #expect(run.status == status)
        #expect(run.errors.filter { $0.hasPrefix("mecum: ") && $0.contains("received") }.count == 1, "one stop")
        #expect(run.errors.first?.hasPrefix("mecum: \(signal) received") == true, "the stop is said first")
        #expect(run.errors.last == "mecum: stopped by \(signal)", "the last line, after the cleanup")
        #expect(!run.errors.contains { $0.hasPrefix("perceived") }, "nothing perceived")
        #expect(run.output.isEmpty, "no scene printed")
        #expect(run.events == 0, "nothing recorded: the call never began")
    }

    @Test("SIGINT while the command waits for its memory: stop, cleanup, exit 130; nothing perceived or recorded")
    func interrupt() async throws {
        guard Self.finderIsRunning else { return }
        Self.check(try await Self.run(sending: [SIGINT]), status: 130, signal: "SIGINT")
    }

    @Test("SIGTERM: the same stop, exit 143")
    func terminate() async throws {
        guard Self.finderIsRunning else { return }
        Self.check(try await Self.run(sending: [SIGTERM]), status: 143, signal: "SIGTERM")
    }

    @Test("SIGINT twice then SIGTERM: one stop, one cleanup, the first signal's status")
    func repeatedSignals() async throws {
        guard Self.finderIsRunning else { return }
        Self.check(try await Self.run(sending: [SIGINT, SIGINT, SIGTERM]), status: 130, signal: "SIGINT")
    }
}
