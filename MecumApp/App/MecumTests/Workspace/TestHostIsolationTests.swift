//
//  TestHostIsolationTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import AutomationRuntime
import Foundation
import Testing
@testable import Mecum

/// Where the host of the unit tests puts the workspace and the living memory, read inside the host
/// itself: `WorkspaceLaunch.directory` and `AppModel.memory`'s file. A run that passes
/// `TEST_RUNNER_MECUM_APP_SUPPORT_DIR` to `xcodebuild test` reaches the host as `MECUM_APP_SUPPORT_DIR`
/// and both paths are under it; a run that passes nothing gets the temporary check directory. Never the
/// person's Application Support. The `ISOLATION` line is the evidence a runbook reads: a directory that
/// merely fills up proves nothing about which process wrote it.
///
/// Paths are compared as `CanonicalPath`s: the memory's URL and the workspace's may name one directory
/// as `/private/tmp/…` and `/tmp/…`, depending on whether it existed when each was read.
@MainActor
@Suite("The test host's workspace and memory are isolated")
struct TestHostIsolationTests {

    @Test("the workspace and memory.sqlite resolve under MECUM_APP_SUPPORT_DIR when the run gives one, and never under the person's Application Support")
    func theHostResolvesItsDirectories() {
        let override  = ProcessInfo.processInfo.environment["MECUM_APP_SUPPORT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let workspace = WorkspaceLaunch.directory.standardizedFileURL
        let memory    = AppModel().memory.url.standardizedFileURL
        let canonicalWorkspace = CanonicalPath(workspace), canonicalMemory = CanonicalPath(memory)
        print("ISOLATION testHost=\(MecumApp.isTestHost) override=\(override ?? "none") "
              + "workspace=\(workspace.path) memory=\(memory.path) "
              + "canonicalWorkspace=\(canonicalWorkspace) canonicalMemory=\(canonicalMemory)")
        #expect(MecumApp.isTestHost)
        #expect(canonicalMemory == canonicalWorkspace.appending("Knowledge", "memory.sqlite"))
        let personal = CanonicalPath(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mecum", directoryHint: .isDirectory))
        #expect(!canonicalWorkspace.isWithin(personal), "never the person's workspace")
        #expect(!canonicalMemory.isWithin(personal), "never the person's memory")
        if let override {
            let root = CanonicalPath(URL(filePath: override, directoryHint: .isDirectory))
            #expect(canonicalWorkspace == root)
            #expect(canonicalMemory.isWithin(root))
        } else {
            #expect(workspace.lastPathComponent == "MecumCheckSupport", "the check runs' temporary directory")
            #expect(canonicalWorkspace.isWithin(CanonicalPath(URL.temporaryDirectory)), "under the temporary directory")
        }
    }
}

/// The comparison the isolation check relies on, on real directories in a temporary root: one path
/// spelled through `/tmp` and through `/private/tmp`, read before and after its directories exist, and
/// paths that really are elsewhere. No app state.
@Suite("Canonical paths compare directories, not spellings")
struct CanonicalPathTests {

    /// A fresh root under `/private/tmp`, the alias pair the host met, removed afterwards.
    private static func root() throws -> (canonical: URL, alias: URL) {
        let name = "mecum-canonical-\(UUID().uuidString)"
        let canonical = URL(fileURLWithPath: "/private/tmp/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        return (canonical, URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true))
    }

    @Test("the host's case: Support created between the two readings, /private/tmp against /tmp, one path")
    func aDirectoryCreatedBetweenTwoReadings() throws {
        let (canonical, alias) = try Self.root()
        defer { try? FileManager.default.removeItem(at: canonical) }
        let workspace = alias.appending(path: "Support", directoryHint: .isDirectory)
        let expectedBefore = CanonicalPath(workspace.appending(path: "Knowledge").appending(path: "memory.sqlite"))
        try FileManager.default.createDirectory(at: canonical.appending(path: "Support"), withIntermediateDirectories: true)
        let memory = canonical.appending(path: "Support").appending(path: "Knowledge").appending(path: "memory.sqlite")
        // The spellings differ and the URL comparison the test used to make says so.
        #expect(memory.standardizedFileURL != workspace.appending(path: "Knowledge").appending(path: "memory.sqlite").standardizedFileURL)
        #expect(CanonicalPath(memory) == expectedBefore)
        #expect(CanonicalPath(memory) == CanonicalPath(workspace).appending("Knowledge", "memory.sqlite"))
        #expect(CanonicalPath(memory).isWithin(CanonicalPath(workspace)))
    }

    @Test("present or absent, Knowledge and memory.sqlite are the same path through either alias")
    func presentAndAbsent() throws {
        let (canonical, alias) = try Self.root()
        defer { try? FileManager.default.removeItem(at: canonical) }
        let relative = "Support/Knowledge/memory.sqlite"
        #expect(CanonicalPath(canonical.appending(path: relative)) == CanonicalPath(alias.appending(path: relative)))
        #expect(CanonicalPath(canonical.appending(path: relative)).identity == nil)
        try FileManager.default.createDirectory(at: canonical.appending(path: "Support/Knowledge"), withIntermediateDirectories: true)
        #expect(CanonicalPath(canonical.appending(path: relative)) == CanonicalPath(alias.appending(path: relative)))
        #expect(FileManager.default.createFile(atPath: canonical.appending(path: relative).path, contents: Data()))
        let present = CanonicalPath(alias.appending(path: relative))
        #expect(present.identity != nil)
        #expect(present == CanonicalPath(canonical.appending(path: relative)))
        #expect(present.isWithin(CanonicalPath(alias.appending(path: "Support"))))
    }

    @Test("a path really elsewhere is refused: a sibling with the same prefix, another root, a link that leaves")
    func pathsElsewhere() throws {
        let (canonical, alias) = try Self.root()
        let (other, _) = try Self.root()
        defer {
            try? FileManager.default.removeItem(at: canonical)
            try? FileManager.default.removeItem(at: other)
        }
        let support = CanonicalPath(alias.appending(path: "Support"))
        // A string prefix would accept the sibling; components do not.
        let sibling = canonical.appending(path: "Support-other/Knowledge/memory.sqlite")
        #expect(sibling.path.hasPrefix(canonical.appending(path: "Support").path))
        #expect(!CanonicalPath(sibling).isWithin(support))
        #expect(!CanonicalPath(other.appending(path: "Support/Knowledge/memory.sqlite")).isWithin(support))
        #expect(CanonicalPath(other.appending(path: "Support")) != support)
        // A link inside the root that points out of it is outside once resolved.
        try FileManager.default.createDirectory(at: canonical.appending(path: "Support"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other.appending(path: "Knowledge"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: canonical.appending(path: "Support/Knowledge"),
                                                   withDestinationURL: other.appending(path: "Knowledge"))
        #expect(!CanonicalPath(alias.appending(path: "Support/Knowledge/memory.sqlite")).isWithin(support))
        // And the person's Application Support is never inside a temporary root.
        let personal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mecum/Knowledge/memory.sqlite")
        #expect(!CanonicalPath(personal).isWithin(support))
    }
}
