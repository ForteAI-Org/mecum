//
//  BrainLibraryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import AutomationRuntime
import Foundation
import Memory
import Testing
@testable import Mecum

/// The Brain page's reader over SQLite: a memory prepared through the real APIs reads back as the
/// applications it holds; a missing archive, an unreadable one and an empty one are three answers; a
/// reload after a new write sees it. No JSON is read anywhere.
@MainActor
@Suite("The Brain library over the living memory")
struct BrainLibraryTests {

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "mecum-brain-library-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("a memory prepared through the real APIs lists its application, with the bundle ID as the name when it is not installed")
    func preparedMemoryIsListed() async throws {
        let directory = await BrainFixture.prepare(in: Self.directory())
        let memory = MemoryService(directory: directory)
        guard case .loaded(let apps) = await BrainLibrary.load(from: memory) else {
            Issue.record("the prepared memory did not load")
            return
        }
        #expect(apps.map(\.bundleID) == [BrainFixture.bundleID])
        #expect(apps.first.map { !$0.brain.objects.isEmpty } == true)
        #expect(apps.first?.lastLearned != nil)
        await memory.close()
        // An application that is not installed keeps its bundle ID as its name, and has no icon.
        let ghost = await BrainFixture.prepare(in: Self.directory(), bundleID: "com.example.not-installed")
        let other = MemoryService(directory: ghost)
        guard case .loaded(let ghosts) = await BrainLibrary.load(from: other) else { Issue.record("expected loaded"); return }
        #expect(ghosts.map(\.name) == ["com.example.not-installed"])
        #expect(ghosts.first?.icon == nil)
        await other.close()
    }

    @Test("no archive is missing, never created; an empty archive is loaded with nothing; an unreadable one fails")
    func threeAnswersAreDistinct() async throws {
        let missing = MemoryService(directory: Self.directory())
        guard case .missing = await BrainLibrary.load(from: missing) else { Issue.record("expected missing"); return }
        #expect(!missing.archiveExists, "reading created nothing")

        let empty = MemoryService(directory: Self.directory())
        try await empty.open()
        guard case .loaded(let none) = await BrainLibrary.load(from: empty) else { Issue.record("expected loaded"); return }
        #expect(none.isEmpty)
        await empty.close()

        let broken = Self.directory()
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not a database, and long enough to be read as one".utf8).write(to: broken.appending(path: "memory.sqlite"))
        let unreadable = MemoryService(directory: broken)
        guard case .failed = await BrainLibrary.load(from: unreadable) else { Issue.record("expected failed"); return }
        await unreadable.close()
    }

    @Test("a reload after a new write sees it: nothing is cached across loads")
    func reloadSeesNewWrites() async throws {
        let directory = Self.directory()
        let memory = MemoryService(directory: directory)
        try await memory.open()
        guard case .loaded(let before) = await BrainLibrary.load(from: memory) else { Issue.record("expected loaded"); return }
        #expect(before.isEmpty)
        // Another writer on the same file (a worker's session, here the fixture's own service), while this one stays open.
        await BrainFixture.prepare(in: directory)
        guard case .loaded(let after) = await BrainLibrary.load(from: memory) else { Issue.record("expected loaded"); return }
        #expect(after.map(\.bundleID) == [BrainFixture.bundleID])
        await memory.close()
    }
}
