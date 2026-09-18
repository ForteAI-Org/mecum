//
//  FileAllowlistStore.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import Memory

/// FileAllowlistStore keeps the `Allowlist` as `allowlist.json` in the knowledge directory. An absent
/// or unreadable file reads as the default allowlist.
public struct FileAllowlistStore: Sendable {

    public static let fileName = "allowlist.json"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var url: URL { directory.appendingPathComponent(Self.fileName) }

    public func load() -> Allowlist {
        guard let data = try? Data(contentsOf: url),
              let allowlist = try? KnowledgeCoding.makeDecoder().decode(Allowlist.self, from: data) else {
            return Allowlist()
        }
        return allowlist
    }

    public func save(_ allowlist: Allowlist) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileKnowledgeStore.excludeFromBackup(directory)
        try KnowledgeCoding.makeEncoder().encode(allowlist).write(to: url, options: [.atomic])
    }
}
