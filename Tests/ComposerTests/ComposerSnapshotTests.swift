//
//  ComposerSnapshotTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Composer

/// Draws the composer offscreen into PNGs, for a person to look at, the way the
/// transcript snapshots do: `cacheDisplay` into a bitmap, no window on screen
/// and no Screen Recording grant. Gated by MECUM_SNAPSHOTS=1; the files go to
/// MECUM_SNAPSHOT_DIR, or to a folder under the temporary directory.
@Suite("Composer snapshots", .enabled(if: ProcessInfo.processInfo.environment["MECUM_SNAPSHOTS"] == "1"))
@MainActor
struct ComposerSnapshotTests {

    private var directory: URL {
        get throws {
            let environment = ProcessInfo.processInfo.environment
            let directory   = environment["MECUM_SNAPSHOT_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? URL.temporaryDirectory.appending(path: "MecumComposerSnapshots", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    @Test("Empty, three lines, grown and scrolled, during a turn, and with no model, in both themes")
    func snapshots() async throws {
        let states: [(name: String, set: @MainActor (ComposerHarness) -> Void)] = [
            ("empty", { _ in }),
            ("three-lines", { $0.draft = "Can you check this morning's build?\nTell me what failed,\nand rerun the capture suite." }),
            ("grown-scrolled", { $0.draft = (1...20).map { "Line \($0) of a long message that keeps going." }
                .joined(separator: "\n") }),
            ("turn-running", {
                $0.draft       = "Also look at the release notes when you are done."
                $0.isAnswering = true
            }),
            ("no-model", {
                $0.notice = "Milo has no model attached. What you write is saved and stays here, "
                    + "and nothing answers until a model is connected."
            }),
        ]
        for state in states {
            for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let harness = ComposerHarness(appearance: appearance)
                defer { harness.close() }
                state.set(harness)
                try await harness.settle()
                if let textView = harness.textView {
                    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
                    textView.scrollToEndOfDocument(nil)
                }
                try await harness.settle()
                let file = try directory.appending(path: "composer-\(state.name)-600-\(theme).png")
                try Self.png(of: try #require(harness.hosting)).write(to: file)
                print("snapshot: \(file.path)")
            }
        }
    }

    /// Draws the bar alone: the bottom of the hosting view, as tall as the bar asks.
    private static func png(of view: NSView) throws -> Data {
        let height = view.fittingSize.height
        let rect   = NSRect(x: 0, y: view.isFlipped ? view.bounds.height - height : 0,
                            width: view.bounds.width, height: height)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { throw SnapshotFailure.noBitmap }
        view.cacheDisplay(in: rect, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotFailure.noPNG }
        return data
    }

    private enum SnapshotFailure: Error { case noBitmap, noPNG }
}
