//
//  TranscriptSnapshotTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Foundation
import Testing
@testable import Transcript
import Workspace

/// Draws the transcript offscreen into PNGs, for a person to look at. It
/// needs no window on screen and no Screen Recording grant: the view draws
/// into a bitmap with `cacheDisplay`. Gated by MECUM_SNAPSHOTS=1; the files go
/// to MECUM_SNAPSHOT_DIR, or to a folder under the temporary directory.
///
/// The controller renders the mascot itself through `MascotImages`, the same
/// renderer the app's sidebar and transcript use, so a PNG is what the app shows.
@Suite("Transcript snapshots", .enabled(if: ProcessInfo.processInfo.environment["MECUM_SNAPSHOTS"] == "1"))
@MainActor
struct TranscriptSnapshotTests {

    private var directory: URL {
        get throws {
            let environment = ProcessInfo.processInfo.environment
            let directory   = environment["MECUM_SNAPSHOT_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? URL.temporaryDirectory.appending(path: "MecumTranscriptSnapshots", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
    }

    @Test("Short and long messages, a tool burst, an interrupted answer and dividers, at two widths and both themes")
    func snapshots() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await conversation(fixture)

        for width in [480.0, 900.0] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try await write(fixture, width: width, appearance: appearance,
                                to: try directory.appending(path: "transcript-\(Int(width))-\(name).png"))
            }
        }
    }

    @Test("A rich reply: headings, nested lists, a long code block, inline code, a quote, a table and a link")
    func richSnapshots() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("Where are we with the release?", at: 0)
        try await fixture.say(TranscriptFixture.richReply, at: 10, byWorker: true)

        for width in [480.0, 900.0] {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                try await write(fixture, width: width, appearance: appearance,
                                to: try directory.appending(path: "transcript-rich-\(Int(width))-\(name).png"))
            }
        }
    }

    @Test("An interrupted turn and a failed turn, so both delivery badges show")
    func badges() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        let stopped = UUID(), failed = UUID()
        try await fixture.say("Rename the release branch.", at: 0, delivery: .interrupted)
        try await fixture.record(.executionStarted, subject: stopped, at: 1)
        try await fixture.record(.toolActivity, subject: stopped, at: 2, text: "→ list_branches {}")
        try await fixture.say("Looking at the branches, the release one is", at: 3, byWorker: true)
        try await fixture.record(.executionCancelled, subject: stopped, at: 4,
                                 text: "Interrupted. Inspect the current app state before continuing.")
        try await fixture.say("Try again, and push it this time.", at: 400, delivery: .interrupted)
        try await fixture.record(.executionStarted, subject: failed, at: 401)
        try await fixture.record(.toolActivity, subject: failed, at: 402, text: "→ push {\"branch\":\"release\"}")
        try await fixture.record(.toolActivity, subject: failed, at: 403, text: "← push error: remote refused")
        try await fixture.record(.executionFailed, subject: failed, at: 404,
                                 text: "The provider stopped with exit status 1.")
        try await fixture.say("Leave it for now.", at: 800, delivery: .savedLocally)

        try await write(fixture, width: 600, appearance: .aqua,
                        to: try directory.appending(path: "transcript-badges-600-light.png"))
    }

    // MARK: Drawing

    /// Measures at an ordinary height, then draws tall enough that every row is
    /// on screen, so the recycled view has made a cell for each.
    private func write(
        _ fixture : TranscriptFixture,
        width     : CGFloat,
        appearance: NSAppearance.Name,
        to file   : URL
    ) async throws {
        let measuring = try await render(fixture, width: width, height: 600, appearance: appearance)
        let backdrop  = try await render(fixture, width: width, height: measuring.contentHeight,
                                         appearance: appearance).backdrop
        try Self.png(of: backdrop).write(to: file)
        print("snapshot: \(file.path)")
    }

    private func render(
        _ fixture : TranscriptFixture,
        width     : CGFloat,
        height    : CGFloat,
        appearance: NSAppearance.Name
    ) async throws -> (backdrop: NSView, contentHeight: CGFloat) {
        let controller = TranscriptController(source: fixture.store)
        let backdrop   = Backdrop(frame: NSRect(x: 0, y: 0, width: width, height: height))
        backdrop.appearance = NSAppearance(named: appearance)
        controller.view.frame = backdrop.bounds
        backdrop.addSubview(controller.view)
        backdrop.layoutSubtreeIfNeeded()
        controller.open(fixture.conversation, workerName: "Atlas", appearance: TranscriptFixture.appearance,
                        readingAnchor: nil, readingOffset: 0)
        await controller.settle()
        backdrop.layoutSubtreeIfNeeded()
        return (backdrop, controller.contentHeight)
    }

    /// The synthetic conversation the four width and theme snapshots draw.
    private func conversation(_ fixture: TranscriptFixture) async throws {
        let first = UUID(), second = UUID()
        try await fixture.say("Can you check this morning's build?", at: 0)
        try await fixture.say("And tell me if anything failed.", at: 10)
        try await fixture.record(.executionStarted, subject: first, at: 12)
        for step in 0..<8 {
            try await fixture.record(.toolActivity, subject: first, at: 13 + Double(step),
                                     text: "→ read_log {\"step\":\(step)}")
            try await fixture.record(.toolActivity, subject: first, at: 13.5 + Double(step),
                                     text: step == 5 ? "← read_log error: file is locked" : "← read_log {\"ok\":true}")
        }
        try await fixture.say("Done.", at: 30, byWorker: true)
        try await fixture.say("""
            The build finished at 07:42 and every target compiled. Two test bundles reported failures: \
            the capture suite timed out once on the virtual display, which matches the flake we saw last \
            week, and the layout suite failed on a width assertion that started after yesterday's change \
            to the sidebar.

            I would rerun the capture suite before looking deeper, and open the layout failure first, \
            since it is new and it points at one commit.
            """, at: 32, byWorker: true)
        try await fixture.record(.executionCompleted, subject: first, at: 34)
        try await fixture.say("Open the layout failure and fix it.", at: 400, delivery: .interrupted)
        try await fixture.record(.executionStarted, subject: second, at: 401)
        try await fixture.say("Opening the failing assertion in", at: 403, byWorker: true)
        try await fixture.record(.executionCancelled, subject: second, at: 404,
                                 text: "Interrupted. Inspect the current app state before continuing.")
        try await fixture.say("Sorry, stop there. Next time ask first.", at: 460, delivery: .savedLocally)
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

/// The window background behind the transcript, so a PNG reads as the app would.
private final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
