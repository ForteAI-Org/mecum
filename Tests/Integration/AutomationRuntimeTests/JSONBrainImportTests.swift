//
//  JSONBrainImportTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 08/10/2026.
//

import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore
import Testing

/// The JSON Brains main left in a Knowledge directory come into the memory once, when an open creates
/// the archive there, before anything is learned into it; never into an archive that already existed or
/// that a recovery left empty, and never by changing a JSON file.
@Suite("Importing main's JSON Brains when the archive is created")
struct JSONBrainImportTests {

    private static let other = "com.example.Viewer"

    private func window(_ bundle: String, _ labels: [String]) -> PerceivedWindow {
        let elements = labels.enumerated().map { index, label in W.button(label, x: 0.1 + 0.2 * Double(index)) }
        return PerceivedWindow(
            scene  : SceneSnapshot(bundleID: bundle, appName: bundle, windowTitle: "Document",
                                   viewportPixelSize: ViewportPixelSize(width: 1600, height: 1200), elements: elements),
            frame  : CGRect(x: 0, y: 0, width: 800, height: 600),
            capture: CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true,
                                    windowRole: "AXWindow", nodesVisited: elements.count + 1, elementsEmitted: elements.count),
            surface: .window
        )
    }

    /// A Brain as learning makes it, from a window of the application's: observed in a memory of its own.
    private func learnedBrain(_ bundle: String, _ labels: [String]) async throws -> UIBrain {
        let scratch = try W.service()
        let recorder = CallRecorder(memory: scratch, brain: W.brain(scratch),
                                    context: ActionContext(source: .app, streamID: "worker-1", traceID: nil, sessionID: nil))
        _ = await recorder.observe(window(bundle, labels))
        #expect(await scratch.flush(within: .seconds(10)))
        let brain = try #require(try await scratch.brain(of: bundle))
        await scratch.close()
        return brain
    }

    /// Writes the application's Brain as main's file store writes it, and answers the file.
    @discardableResult
    private func writeJSON(_ brain: UIBrain, of bundle: String, in directory: URL) throws -> URL {
        let file = directory.appendingPathComponent("\(bundle).json")
        try KnowledgeCoding.makeEncoder().encode(AppKnowledge(bundleID: bundle, brain: brain)).write(to: file)
        return file
    }

    @Test("an archive created beside main's JSON files takes their Brains, exactly, and leaves every file as it was")
    func newArchiveImportsTheJSONBrains() async throws {
        let directory = try W.directory()
        let editor = try await learnedBrain(W.bundle, ["Open", "Format", "Save"])
        let viewer = try await learnedBrain(Self.other, ["Zoom", "Rotate"])
        let files = [try writeJSON(editor, of: W.bundle, in: directory), try writeJSON(viewer, of: Self.other, in: directory)]
        // Not applications: the allowlist, a file a recovery put aside, and main's daily copies.
        try Data("{}".utf8).write(to: directory.appendingPathComponent("allowlist.json"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("\(W.bundle).corrupt-2026.json"))
        let backups = directory.appendingPathComponent(".backup")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try writeJSON(viewer, of: "com.example.Copy", in: backups)
        let before = try files.map { try Data(contentsOf: $0) }

        let service = MemoryService(directory: directory)
        _ = try await service.ready()
        let status = await service.status()
        #expect(status.lastImport?.contains("2 of 2 JSON Brains imported") == true, "\(status.lastImport ?? "")")
        #expect(try await service.brain(of: W.bundle) == editor)
        #expect(try await service.brain(of: Self.other) == viewer)
        #expect(try await service.brain(of: "com.example.Copy") == nil, "main's daily copies are not applications")
        #expect(try files.map { try Data(contentsOf: $0) } == before, "the JSON files are only read")
        await service.close()
    }

    @Test("the import comes before the first learning: what the agent observes first adds to the imported Brain")
    func importComesBeforeTheFirstLearning() async throws {
        let directory = try W.directory()
        let earlier = try await learnedBrain(W.bundle, ["Open", "Format"])
        try writeJSON(earlier, of: W.bundle, in: directory)

        let service  = MemoryService(directory: directory)
        // The first write opens the archive: had it learned before the import, the JSON Brain would be kept out.
        _ = await W.recorder(service, session: nil).observe(W.window([W.save]))
        #expect(await service.flush(within: .seconds(10)))
        let labels = Set(try #require(try await service.brain(of: W.bundle)).objects.map(\.label))
        #expect(labels.isSuperset(of: ["Open", "Format", "Save"]), "\(labels)")
        #expect(await service.status().lastImport?.contains("1 of 1") == true)
        await service.close()
    }

    @Test("a directory that is really new makes an empty archive and imports nothing")
    func newDirectoryImportsNothing() async throws {
        let service = try W.service()
        _ = try await service.ready()
        #expect(await service.status().lastImport == nil)
        #expect(try await service.brain(of: W.bundle) == nil)
        await service.close()
    }

    @Test("an archive that already existed is never imported into, even with JSON files beside it")
    func existingArchiveIsLeftAlone() async throws {
        let directory = try W.directory()
        let first = MemoryService(directory: directory)
        _ = try await first.ready()
        await first.close()
        try writeJSON(try await learnedBrain(W.bundle, ["Open"]), of: W.bundle, in: directory)

        let again = MemoryService(directory: directory)
        _ = try await again.ready()
        #expect(await again.status().lastImport == nil)
        #expect(try await again.brain(of: W.bundle) == nil)
        await again.close()
    }

    @Test("an archive a recovery left empty is not imported into: the memory starts empty, as the recovery says")
    func recoveredArchiveIsLeftEmpty() async throws {
        let directory = try W.directory()
        try writeJSON(try await learnedBrain(W.bundle, ["Open"]), of: W.bundle, in: directory)
        try Data(repeating: 0x5A, count: 8192).write(to: directory.appendingPathComponent("memory.sqlite"))

        let service = MemoryService(directory: directory)
        _ = try await service.ready()
        let status = await service.status()
        #expect(status.lastRecovery?.contains("started empty") == true)
        #expect(status.lastImport == nil)
        #expect(try await service.brain(of: W.bundle) == nil)
        await service.close()
    }
}
