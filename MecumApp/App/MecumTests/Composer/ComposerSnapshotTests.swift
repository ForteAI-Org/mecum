//
//  ComposerSnapshotTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Mecum

/// Draws the composer floating over a stand-in transcript into PNGs, for a
/// person to look at, the way the transcript snapshots do: `cacheDisplay` into
/// a bitmap, no window on screen and no Screen Recording grant. Each state is
/// drawn on the material and on the solid surface Reduce Transparency uses.
///
/// Gated by MECUM_SNAPSHOTS=1; the files go to MECUM_SNAPSHOT_DIR, or to a
/// folder under the temporary directory.
@Suite("Composer snapshots", .enabled(if: ProcessInfo.processInfo.environment["MECUM_SNAPSHOTS"] == "1"))
@MainActor
struct ComposerSnapshotTests {

    static var directory: URL {
        get throws {
            let environment = ProcessInfo.processInfo.environment
            let directory   = environment["MECUM_SNAPSHOT_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? URL.temporaryDirectory.appending(path: "MecumComposerSnapshots", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    static let states: [(name: String, set: @MainActor (ComposerHarness) -> Void)] = [
        ("empty", { _ in }),
        ("code", { $0.draft = "func greet(_ name: String) {\n    print(\"Hello, \\(name)\")\n}" }),
        ("grown", { $0.draft = (1...20).map { "Line \($0) of a long message that keeps going." }
            .joined(separator: "\n") }),
        ("turn-running", {
            $0.draft       = "Also look at the release notes when you are done."
            $0.isAnswering = true
        }),
        ("no-model", { $0.canAnswer = false }),
        ("release", {
            $0.draft         = "Open the capture log."
            $0.holdsComputer = true
        }),
    ]

    @Test("Empty, code, grown, during a turn, with no model and with Release, at two widths, in both themes")
    func snapshots() async throws {
        let surfaces: [(name: String, kind: ComposerSurface.Kind?)] = [("material", .material), ("solid", .solid)]
        for state in Self.states {
            for width in [600, 900] as [CGFloat] {
                for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    for surface in surfaces {
                        let harness = ComposerHarness(width: width, height: 320, appearance: appearance,
                                                      surface: surface.kind)
                        defer { harness.close() }
                        state.set(harness)
                        try await harness.settle()
                        if let textView = harness.textView {
                            let end = (textView.string as NSString).length
                            textView.setSelectedRange(NSRange(location: end, length: 0))
                            textView.scrollToEndOfDocument(nil)
                        }
                        // Long enough for the release button's entrance to finish before the drawing.
                        for _ in 0..<8 { try await harness.settle() }
                        let name = "composer-\(state.name)-\(Int(width))-\(theme)-\(surface.name).png"
                        let file = try Self.directory.appending(path: name)
                        try Self.png(of: try #require(harness.hosting)).write(to: file)
                        print("snapshot: \(file.path)")
                    }
                }
            }
        }
    }

    private static func png(of view: NSView) throws -> Data {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SnapshotFailure.noBitmap
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotFailure.noPNG }
        return data
    }

    private enum SnapshotFailure: Error { case noBitmap, noPNG }
}
