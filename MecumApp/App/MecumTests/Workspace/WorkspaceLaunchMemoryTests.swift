import Foundation
import SQLiteLivingMemory
import Testing
@testable import Mecum

@MainActor
struct WorkspaceLaunchMemoryTests {
    @Test func workspaceAndMemoryOpenTogether() throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let launch = WorkspaceLaunch()
        launch.open(in: directory)
        #expect(launch.store != nil)
        #expect(launch.livingMemory != nil)
        #expect(launch.failure == nil)
        #expect(launch.memoryFailure == nil)
        let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: directory.appending(path: "Knowledge"))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func corruptMemoryDoesNotDiscardTheWorkspaceOrReplaceTheFile() throws {
        let directory = TemporaryStore.directory()
        defer { TemporaryStore.discard(directory) }
        let knowledge = directory.appending(path: "Knowledge")
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)
        let original = Data("synthetic unreadable memory".utf8)
        try original.write(to: file)
        let launch = WorkspaceLaunch()
        launch.open(in: directory)
        #expect(launch.store != nil)
        #expect(launch.failure == nil)
        #expect(launch.livingMemory == nil)
        #expect(launch.memoryFailure != nil)
        #expect(try Data(contentsOf: file) == original)
    }
}
