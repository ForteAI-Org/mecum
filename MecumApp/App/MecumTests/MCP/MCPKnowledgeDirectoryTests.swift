//
//  MCPKnowledgeDirectoryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import AutomationRuntime
import Foundation
import Testing
@testable import Mecum

/// G76 D1: external clients share the user's one living memory with the workers. Before it each client kept
/// a memory of its own in the directory main gave its profile (the C07 decision of the merge); that
/// directory is now only an origin the shared archive takes in once, read only, and keeps where it was.
struct MCPKnowledgeDirectoryTests {

    @Test func clientsShareTheUsersArchiveAndTheirEarlierDirectoriesAreOrigins() throws {
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-knowledge-\(UUID().uuidString)")
        let first   = UUID(), second = UUID()
        let a = AppModel.knowledgeDirectory(of: first, under: support)
        let b = AppModel.knowledgeDirectory(of: second, under: support)
        #expect(a.path == support.appendingPathComponent("MCP/Knowledge/\(first.uuidString)").path, "the path main used")
        #expect(a != b)
        let shared = KnowledgeLocation.knowledge(under: support)
        #expect(shared.path == support.appendingPathComponent("Knowledge").path, "the workers' and the clients' one directory")

        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: a.appendingPathComponent("com.example.Editor.json"))
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let origins = KnowledgeLocation.legacyProfiles(under: support)
        #expect(origins.map(\.originID) == ["mcp-profile:\(first.uuidString)"], "an empty earlier directory is no origin")
        #expect(origins.first?.location == "MCP/Knowledge/\(first.uuidString)" && origins.first?.hasArchive == false)
        #expect(MemoryService.shared(for: shared).url.path == shared.appendingPathComponent("memory.sqlite").path)
    }
}
