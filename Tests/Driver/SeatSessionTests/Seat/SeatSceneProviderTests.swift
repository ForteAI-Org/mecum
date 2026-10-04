//
//  SeatSceneProviderTests.swift
//  Mecum
//

import CoreGraphics
import EngineCore
import Perception
import PerceptionCore
import SeatCore
import SeatDriving
import SeatSession
import Testing

/// SeatSceneProviderTests keep adoption metadata separate from the title observed after capture.
@MainActor
@Suite("Seat scene window metadata")
struct SeatSceneProviderTests {

    private struct EmptyText: TextRecognizing {
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            []
        }
    }

    private final class Windows: WindowListing, @unchecked Sendable {
        var rows: [WindowRow] = []
        func windows(ownedBy processID: Int32) throws -> [WindowRow] { rows }
    }

    @Test("a document change updates the title of the exact captured window")
    func documentTitleChanges() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let windows = Windows()
        let provider = SeatSceneProvider(
            target  : context.target,
            pipeline: ScenePipeline(text: EmptyText()),
            windows : windows,
            identity: { _ in ApplicationIdentity(bundleID: "com.test", name: "Test") }
        )
        let number = context.window.id
        let frame = context.window.reference.frame
        windows.rows = [WindowRow(layer: 0, frame: frame, title: "Probe.png", number: number)]
        let original = try await provider.currentScene(of: context.window.reference.processID)
        #expect(original.scene.windowTitle == "Probe.png")

        windows.rows = [
            WindowRow(layer: 0, frame: frame, title: "Unrelated", number: number + 1),
            WindowRow(layer: 0, frame: frame, title: "Untitled-1", number: number)
        ]
        let changed = try await provider.currentScene(of: context.window.reference.processID)
        #expect(changed.scene.windowTitle == "Untitled-1")

        windows.rows = [WindowRow(layer: 0, frame: frame, title: "Probe.png", number: number + 1)]
        let missing = try await provider.currentScene(of: context.window.reference.processID)
        #expect(missing.scene.windowTitle.isEmpty)

        windows.rows = [
            WindowRow(layer: 0, frame: frame, title: "First", number: number),
            WindowRow(layer: 0, frame: frame, title: "Second", number: number)
        ]
        let ambiguous = try await provider.currentScene(of: context.window.reference.processID)
        #expect(ambiguous.scene.windowTitle.isEmpty)
    }
}
