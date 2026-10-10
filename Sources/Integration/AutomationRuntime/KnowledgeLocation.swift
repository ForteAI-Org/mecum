//
//  KnowledgeLocation.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import Foundation

/// KnowledgeLocation is the one place that says where the user's knowledge lives: the application
/// support folder of Mecum (`MECUM_APP_SUPPORT_DIR` when set, the user's Application Support otherwise)
/// and, under it, the one Knowledge directory every producer of the user shares, the app's workers, its
/// external MCP clients, `mecum` and `mecum chat` alike. An explicit directory a caller passes (a test's,
/// `--knowledge`) is used as it is and never resolved here.
///
/// Before G76 each external MCP client kept a private archive in `MCP/Knowledge/<profile>`. Those
/// directories are inventoried here, read only, as the origins the shared archive unifies
/// (`MemoryUnification`); nothing writes to them any more, and nothing removes them.
nonisolated public enum KnowledgeLocation {

    /// The environment variable that moves the whole support folder, for a check run or a test.
    public static let supportOverride = "MECUM_APP_SUPPORT_DIR"

    /// The support folder: the override when it is set and not empty, else `<Application Support>/Mecum`.
    public static func support(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[supportOverride], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mecum", isDirectory: true)
    }

    /// The user's one Knowledge directory under a support folder.
    public static func knowledge(under support: URL) -> URL {
        support.appendingPathComponent("Knowledge", isDirectory: true)
    }

    /// The Knowledge directory of the default support folder.
    public static func knowledge(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        knowledge(under: support(environment: environment))
    }

    /// LegacyKnowledge is one directory of an earlier layout: an external client's private Knowledge, with
    /// what it holds, read without opening or changing anything.
    public struct LegacyKnowledge: Sendable, Equatable {
        /// The origin's identity in the shared archive's journal: `mcp-profile:<profile>`.
        public let originID: String
        /// The directory, and its path relative to the support folder, as the journal records it.
        public let directory: URL
        public let location: String
        /// Whether a SQLite archive is there, and how many JSON Brains.
        public let hasArchive: Bool
        public let jsonBrains: Int

        public var archive: URL { directory.appendingPathComponent("memory.sqlite") }
    }

    /// The external clients' private Knowledge directories under a support folder, by name: each
    /// `MCP/Knowledge/<profile>` that holds an archive or a JSON Brain. An empty one is left out.
    public static func legacyProfiles(under support: URL) -> [LegacyKnowledge] {
        let root  = support.appendingPathComponent("MCP/Knowledge", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
        return names.compactMap { name -> LegacyKnowledge? in
            let directory = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard !name.hasPrefix("."),
                  FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let hasArchive = files.contains("memory.sqlite")
            let json = files.filter {
                $0.hasSuffix(".json") && $0 != "allowlist.json" && !$0.contains(".corrupt-")
            }.count
            guard hasArchive || json > 0 else { return nil }
            return LegacyKnowledge(originID: "mcp-profile:\(name)", directory: directory,
                                   location: "MCP/Knowledge/\(name)", hasArchive: hasArchive, jsonBrains: json)
        }
    }
}
