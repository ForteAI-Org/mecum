//
//  MemoryDiagnosisTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AutomationRuntime
import CoreGraphics
import CryptoKit
import EngineCore
import Foundation
import Memory
import PerceptionCore
import Testing
@testable import mecum

/// The `memory` command's diagnosis, offline: a missing archive, an empty file, a file that is not an
/// archive and one of another schema each refused apart from a valid empty archive, none of them
/// created or changed; traces, events, calls, samples and scenes read back as recorded, incomplete
/// states said as such; applications by bundle ID even when not installed, and ambiguous names
/// answered with candidates. No application, Seat or provider is reached.
@MainActor
@Suite("The memory command's offline diagnosis", .serialized)
struct MemoryDiagnosisTests {

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-diagnosis-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Knowledge", isDirectory: true)
    }

    /// Runs `memory <words>` over `directory` and answers what it printed, or the error it threw.
    private static func run(_ words: [String], in directory: URL, applications: ApplicationDirectory = .none)
        async -> (lines: [String], error: (any Error)?) {
        var lines: [String] = []
        let memory = MemoryService(directory: directory)
        do {
            let invocation = try Invocation(arguments: ["memory"] + words + ["--knowledge", directory.path], spec: CommandSpecs.memory)
            try await MemoryCommand.diagnose(invocation, memory: memory, directory: applications, output: { lines.append($0) })
            await memory.close()
            return (lines, nil)
        } catch {
            await memory.close()
            return (lines, error)
        }
    }

    private static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static func window(_ labels: [String], bundle: String) -> PerceivedWindow {
        let elements = labels.enumerated().map { index, label in
            SceneElement(id: "control|\(label.lowercased())", kind: .control, label: label,
                         bounds: NormalizedRect(x: 0.1 + Double(index) * 0.2, y: 0.1, width: 0.1, height: 0.05), role: "AXButton")
        }
        return PerceivedWindow(
            scene: SceneSnapshot(bundleID: bundle, appName: "Ghost", windowTitle: "Secret title",
                                 viewportPixelSize: ViewportPixelSize(width: 1000, height: 800), elements: elements),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            capture: CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true, windowRole: "AXWindow",
                                    nodesVisited: 6, elementsEmitted: labels.count),
            surface: .window
        )
    }

    /// An archive with an observed application, a partial batch and a call left started, through the real APIs.
    private static func populated() async throws -> (directory: URL, trace: CLITrace, started: String, observation: String) {
        let directory = Self.directory()
        let memory = MemoryService(directory: directory)
        let clock = memory.clock
        let brain = BrainMemory(brains: memory, applications: memory, clock: { clock.brainNow() })
        let trace = CLITrace()
        // An observation of an application that is not installed, as `scene` records one.
        let observe = CLICall(memory: memory, request: .observe, context: trace.context(.observe),
                              app: AppContextIdentity(bundleID: "com.example.ghost"))
        try await observe.begin()
        let recorder = CallRecorder(memory: memory, brain: brain, context: observe.context, sessionRevision: 1, requestedAt: clock.brainNow())
        _ = await recorder.observe(window(["Export", "Cancel"], bundle: "com.example.ghost"))
        await observe.complete(observe.observationResult(from: await recorder.report()))
        // A batch stopped at its second step, the third skipped.
        let batch = CLICall(memory: memory, request: .batch, context: trace.context(.batch), app: AppContextIdentity(bundleID: "com.example.ghost"))
        let requests: [AgentCallRequest] = [.act(target: "Export", verb: .click, value: nil, section: nil),
                                            .typeText(target: "Name", text: "Secret text", section: nil, replace: true),
                                            .pressKey(key: .return, modifiers: [.cmd], count: 1)]
        let steps = requests.enumerated().map { position, request in
            CLICall(memory: memory, request: request, context: trace.context(request.tool, parent: batch.context, position: position),
                    app: AppContextIdentity(bundleID: "com.example.ghost"))
        }
        try await CLICall.begin(batch: batch, steps: steps)
        try await steps[0].beginStep()
        await steps[0].complete(.outcome(.foundActed, message: "done"))
        try await steps[1].beginStep()
        await steps[1].complete(.outcome(.actedUnverified, message: "not verified"))
        await steps[2].skip()
        await batch.complete(.batch(stopped: true, attempted: 2, verified: 1))
        // A call left started: the process ended before its outcome.
        let started = CLICall(memory: memory, request: .scroll(direction: .down, lines: 3, target: nil, section: nil),
                              context: trace.context(.scroll), app: AppContextIdentity(bundleID: "com.example.ghost"))
        try await started.begin()
        await memory.close()
        return (directory, trace, started.context.eventID, observe.context.eventID)
    }

    // MARK: Archives that cannot answer

    @Test("no archive is refused and nothing is created")
    func missingArchive() async throws {
        let directory = Self.directory()
        let (lines, error) = await Self.run(["status"], in: directory)
        #expect(error as? MemoryDiagnosisError == .noArchive(path: directory.appendingPathComponent("memory.sqlite").path))
        #expect(lines.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "the diagnosis created nothing")
    }

    @Test("an empty file is not an archive, and stays an empty file")
    func emptyFile() async throws {
        let directory = Self.directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("memory.sqlite")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let (_, error) = await Self.run(["status"], in: directory)
        #expect(error as? MemoryDiagnosisError == .notAnArchive(path: file.path))
        #expect(try Data(contentsOf: file).isEmpty, "not bootstrapped by the reading")
    }

    @Test("a SQLite database with no schema is not an archive: said so, and left byte for byte, with no table added")
    func sqliteWithoutSchema() async throws {
        let directory = Self.directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("memory.sqlite")
        let made = Process()
        made.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        made.arguments = [file.path, "VACUUM;"]
        try made.run()
        made.waitUntilExit()
        try #require(made.terminationStatus == 0)
        let before = try Self.digest(file)
        for words in [["status"], ["traces"], ["com.example.app"]] {
            let (lines, error) = await Self.run(words, in: directory)
            #expect(error as? MemoryDiagnosisError == .noMecumSchema(path: file.path), "\(words): \(String(describing: error))")
            #expect(lines.isEmpty)
        }
        #expect(try Self.digest(file) == before)
        #expect(!FileManager.default.fileExists(atPath: file.path + "-wal"))
    }

    @Test("a file that is not a database, and a database of another schema, are unreadable and left byte for byte as they were")
    func malformedAndIncompatible() async throws {
        let garbage = Self.directory()
        try FileManager.default.createDirectory(at: garbage, withIntermediateDirectories: true)
        let garbageFile = garbage.appendingPathComponent("memory.sqlite")
        try Data(String(repeating: "not a database ", count: 300).utf8).write(to: garbageFile)
        let before = try Self.digest(garbageFile)
        let (_, malformed) = await Self.run(["status"], in: garbage)
        guard case .unavailable? = malformed as? MemoryDiagnosisError else { Issue.record("\(String(describing: malformed))"); return }
        #expect(try Self.digest(garbageFile) == before)

        let other = Self.directory()
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherFile = other.appendingPathComponent("memory.sqlite")
        let made = Process()
        made.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        made.arguments = [otherFile.path, "CREATE TABLE unrelated(x); INSERT INTO unrelated VALUES (1);"]
        try made.run()
        made.waitUntilExit()
        try #require(made.terminationStatus == 0)
        let otherBefore = try Self.digest(otherFile)
        let (_, incompatible) = await Self.run(["status"], in: other)
        guard case .unavailable(let reason)? = incompatible as? MemoryDiagnosisError else {
            Issue.record("\(String(describing: incompatible))"); return
        }
        #expect(reason.contains("schema") || reason.contains("open"), "\(reason)")
        #expect(try Self.digest(otherFile) == otherBefore, "refused untouched")
    }

    @Test("a valid empty archive answers, says it holds nothing, and exits normally")
    func validEmptyArchive() async throws {
        let directory = Self.directory()
        let made = MemoryService(directory: directory)
        try await made.open()
        await made.close()
        let (lines, error) = await Self.run(["status"], in: directory)
        #expect(error == nil)
        #expect(lines.contains("applications: 0"))
        #expect(lines.contains("the archive is valid and holds no memories yet"))
        let (traces, none) = await Self.run(["traces"], in: directory)
        #expect(none == nil && traces == ["no traces recorded"])
        let (_, unknown) = await Self.run(["trace", "nope"], in: directory)
        #expect(unknown as? MemoryDiagnosisError == .noSuchTrace("nope"))
    }

    // MARK: What the archive holds

    @Test("status, traces and a trace read back as recorded, partial batches and started calls said as such, nothing changed by the reading")
    func tracesReadBack() async throws {
        let (directory, trace, started, _) = try await Self.populated()
        let file = directory.appendingPathComponent("memory.sqlite")
        let (status, statusError) = await Self.run(["status"], in: directory)
        #expect(statusError == nil)
        #expect(status.contains { $0.hasPrefix("  (com.example.ghost, not installed): ") }, "\(status)")
        let (traces, _) = await Self.run(["traces"], in: directory)
        #expect(traces.count == 1 && traces[0].hasPrefix("\(trace.traceID) · cli stream \(trace.streamID) · 6 calls, 6 events"),
                "\(traces)")
        let (lines, error) = await Self.run(["trace", trace.traceID], in: directory)
        #expect(error == nil)
        #expect(lines.contains { $0.contains("observe · completed · observation session=") })
        #expect(lines.contains { $0.contains("batch · completed · batch stopped, 2 attempted, 1 verified") })
        #expect(lines.contains { $0.hasPrefix("    ") && $0.contains("step 1 · type_text target=\"Name\" text=<11 characters>") },
                "a typed text is counted, not written, without --detail")
        #expect(lines.contains { $0.contains("step 2 · press_key key=return modifiers=[cmd] count=1 · skipped") })
        #expect(lines.contains { $0.contains(started) && $0.contains("started (no terminal state recorded: its outcome is unknown)") })
        let (page, _) = await Self.run(["trace", trace.traceID, "--limit", "2"], in: directory)
        #expect(page.count == 3 && page[2].hasPrefix("more: --after "))
        // The reading wrote nothing: the started call is still started, and the file's rows are the same.
        let reader = MemoryService(directory: directory)
        #expect(try await reader.call(started)?.progress.status == .started)
        #expect(await reader.status().technicalDetails.contains { $0.hasPrefix("since the open: 0 commits") },
                "no commit by a reading service")
        await reader.close()
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("an event shows its identity, call, three times, result, samples with quality and scenes; --detail writes the texts")
    func eventReadsBack() async throws {
        let (directory, trace, started, observation) = try await Self.populated()
        let (lines, error) = await Self.run(["event", observation], in: directory)
        #expect(error == nil)
        #expect(lines.first == "event \(observation)")
        #expect(lines.contains { $0.contains("source cli") && $0.contains("stream \(trace.streamID)") })
        #expect(lines.contains("  trace \(trace.traceID) · session \(trace.sessionID)"))
        #expect(lines.contains { $0.hasPrefix("call observe") })
        #expect(lines.contains { $0.contains("planned ") && $0.contains("started ") && $0.contains("duration ") })
        #expect(lines.contains { $0.hasPrefix("  result observation session=") })
        #expect(lines.contains { $0.hasPrefix("sample current#0: complete, surface window, 2 elements, revision 1") })
        #expect(lines.contains { $0.hasPrefix("  scenes: ") })
        #expect(!lines.joined().contains("Secret title"), "a window title is local content, written only with --detail")
        let (detailed, _) = await Self.run(["event", observation, "--detail"], in: directory)
        #expect(detailed.contains { $0.contains("title \"Secret title\"") })
        let (open, _) = await Self.run(["event", started], in: directory)
        #expect(open.contains { $0.contains("state started (no terminal state recorded: its outcome is unknown)") })
        #expect(open.contains { $0.contains("ended not recorded · duration not recorded") })
        #expect(open.contains("samples: none recorded under this event"))
        let (_, missing) = await Self.run(["event", "nope"], in: directory)
        #expect(missing as? MemoryDiagnosisError == .noSuchEvent("nope"))
    }

    @Test("an application is read by bundle ID when not installed, by a name when one fits, and an ambiguous name answers candidates")
    func applicationsAreResolved() async throws {
        let (directory, _, _, _) = try await Self.populated()
        let (byBundle, error) = await Self.run(["com.example.ghost"], in: directory)
        #expect(error == nil)
        #expect(byBundle.first == "(com.example.ghost, not installed)")
        #expect(byBundle.contains { $0.hasPrefix("2 anchors") })
        let (explicit, _) = await Self.run(["app", "com.example.ghost"], in: directory)
        #expect(explicit == byBundle)
        let (nothing, _) = await Self.run(["com.example.other"], in: directory)
        #expect(nothing.last == "nothing remembered about com.example.other in this archive")
        let named = ApplicationDirectory(installedName: { $0 == "com.example.ghost" ? "Ghost" : nil },
                                         running: { [(name: "Ghostwriter", bundleID: "com.example.writer")] })
        let (byName, _) = await Self.run(["ghost"], in: directory, applications: named)
        #expect(byName.first == "Ghost (com.example.ghost, installed)")
        let twins = ApplicationDirectory(installedName: { $0 == "com.example.ghost" ? "Ghost" : nil },
                                         running: { [(name: "Ghost", bundleID: "com.example.twin")] })
        let (_, ambiguous) = await Self.run(["Ghost"], in: directory, applications: twins)
        guard case .ambiguousApplication(_, let candidates)? = ambiguous as? MemoryDiagnosisError else {
            Issue.record("\(String(describing: ambiguous))"); return
        }
        #expect(candidates.count == 2)
        let (_, unknown) = await Self.run(["Nobody"], in: directory)
        #expect(unknown as? MemoryDiagnosisError == .unknownApplication("Nobody"))
    }

    @Test("the resolver never picks the first of several: bundle IDs first, then one exact name, then one prefix")
    func resolver() {
        let directory = ApplicationDirectory(installedName: { ["a.one": "Final Cut", "a.two": "Final Draft"][$0] },
                                             running: { [] })
        let catalog = ["a.one", "a.two"]
        #expect(MemoryAppResolver.resolve("A.ONE", catalog: catalog, directory: directory) == .bundle("a.one"))
        #expect(MemoryAppResolver.resolve("final cut", catalog: catalog, directory: directory) == .bundle("a.one"))
        #expect(MemoryAppResolver.resolve("Final", catalog: catalog, directory: directory) == .ambiguous(["a.one", "a.two"]))
        #expect(MemoryAppResolver.resolve("Logic", catalog: catalog, directory: directory) == .unknown)
    }

    @Test("limits and orders are checked, and a subcommand takes only its own options")
    func optionsAreChecked() async throws {
        let directory = Self.directory()
        for words in [["traces", "--limit", "0"], ["traces", "--limit", "501"], ["trace", "t", "--after", "-1"],
                      ["status", "--limit", "3"], ["event"], ["trace"], ["status", "extra"]] {
            let (_, error) = await Self.run(words, in: directory)
            #expect(error is UsageError, "\(words): \(String(describing: error))")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
