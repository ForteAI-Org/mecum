//
//  TemporaryStore.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation
import ModelTransports
import Workspace

/// TemporaryStore gives each test its own directory, so no test can see
/// another one's workers, messages or events.
enum TemporaryStore {

    /// A directory that does not exist yet. The store creates it.
    static func directory() -> URL {
        URL.temporaryDirectory.appending(
            path         : "WorkspaceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    /// Removes the directory a test ran in.
    ///
    /// A failure here must not fail the test it is cleaning up after, and the
    /// path is under the system temporary directory, which the system reclaims
    /// on its own schedule.
    static func discard(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) } catch { }
    }

    /// A distinctive appearance, with a seed whose top bit is set so the
    /// round trip through the store is checked on the whole 64-bit range.
    static func appearance(palette: String = "dusk") -> WorkerAppearance {
        WorkerAppearance(
            seed            : Int64(bitPattern: 0xDEAD_BEEF_CAFE_F00D),
            generatorVersion: 3,
            palette         : palette,
            roundness       : 0.25,
            wobble          : 0.75,
            glow            : 0.5
        )
    }

    static let firstSelection  = ModelSelection(provider: .anthropic, model: "claude-opus-5", effort: .high)
    static let secondSelection = ModelSelection(provider: .ollama, model: "qwen3:8b", effort: .low)
}
