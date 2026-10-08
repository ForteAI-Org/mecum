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

/// Each external client keeps a living memory of its own, as on main: the directory main gave each
/// profile, now holding that client's SQL archive, apart from the workers' and the other clients'.
struct MCPKnowledgeDirectoryTests {

    @Test func eachProfileHasAnArchiveOfItsOwn() {
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mcp-knowledge-\(UUID().uuidString)")
        let first   = UUID(), second = UUID()
        let a = AppModel.knowledgeDirectory(of: first, under: support)
        let b = AppModel.knowledgeDirectory(of: second, under: support)
        #expect(a.path == support.appendingPathComponent("MCP/Knowledge/\(first.uuidString)").path, "the path main used")
        #expect(a != b)
        #expect(a != support.appendingPathComponent("Knowledge", isDirectory: true), "apart from the workers' memory")
        let archives = Set([a, b, support.appendingPathComponent("Knowledge")].map { MemoryService.shared(for: $0).url.path })
        #expect(archives.count == 3, "three archives: \(archives.sorted())")
    }
}
