//
//  SeatSceneProviderTests.swift
//  Mecum
//

import CoreGraphics
import CoreVideo
import EngineCore
import Foundation
import Perception
import PerceptionCore
import SeatCore
import SeatDriving
import SeatInput
@testable import SeatSession
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

    private struct CaptureAugmentation: SceneAugmenting {
        func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> [SceneElement] {
            [element(value: "geometry-only")]
        }

        func augmentation(
            for processID: pid_t, windowNumber: Int, windowFrame: CGRect
        ) async throws -> [SceneElement] {
            [element(value: "\(processID):\(windowNumber)")]
        }

        private func element(value: String) -> SceneElement {
            SceneElement(
                id: "native-field", kind: .control, label: "Probe Text",
                bounds: NormalizedRect(x: 0.2, y: 0.2, width: 0.2, height: 0.05),
                role: "AXTextField", value: value
            )
        }
    }

    @Test("the captured recipient reaches native augmentation despite another window sharing its frame")
    func capturedIdentityReachesNativeFacts() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let windows = Windows()
        let number = context.window.id
        let frame = context.window.reference.frame
        windows.rows = [
            WindowRow(layer: 0, frame: frame, title: "Other", number: number + 1),
            WindowRow(layer: 0, frame: frame, title: "Captured", number: number)
        ]
        let provider = SeatSceneProvider(
            target: context.target,
            pipeline: ScenePipeline(text: EmptyText(), augmentation: CaptureAugmentation()),
            windows: windows,
            identity: { _ in ApplicationIdentity(bundleID: "com.test", name: "Test") }
        )
        let scene = try await provider.currentScene(of: context.window.reference.processID)
        #expect(scene.scene.windowTitle == "Captured")
        #expect(scene.scene.elements.first?.value == "\(context.window.reference.processID):\(number)")
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

    // MARK: A scene answered again over the same pixels (ADR 0034)

    /// A recognizer that reads one new line on every run, so a scene the pipeline built again is
    /// never equal to the one before it, and a scene answered again without it always is.
    private final class CountingText: TextRecognizing, @unchecked Sendable {
        private let lock = NSLock()
        private var runs = 0
        var failsNext = false

        var count: Int { lock.withLock { runs } }

        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            let run = lock.withLock {
                runs += 1
                return runs
            }
            if lock.withLock({ failsNext }) {
                lock.withLock { failsNext = false }
                throw ObservationUnavailable.captureFailed(reason: "controlled recognizer failure")
            }
            return [RecognizedText(text: "Reading \(run)", pixelBox: CGRect(x: 20, y: 20, width: 120, height: 16))]
        }
    }

    private struct Reuse {
        let provider: SeatSceneProvider
        let text    : CountingText
        let source  : ControlledObservationSource
        let sensing : FakeSensing
        let seat    : AgentSeat
        let window  : AdoptedWindow
        let windows : Windows
    }

    private func reuse(marker: Int64) async throws -> Reuse {
        let sensing = FakeSensing()
        let context = try await ObservationAdmissionTests.composed(sensing: sensing, marker: marker)
        _ = try await observe(context.seat)
        let windows = Windows()
        windows.rows = [WindowRow(layer: 0, frame: context.window.reference.frame, title: "Doc", number: context.window.id)]
        let text = CountingText()
        let provider = SeatSceneProvider(
            target  : SeatTarget(borrowing: SeatHost(), seat: context.seat),
            pipeline: ScenePipeline(text: text),
            windows : windows,
            identity: { _ in ApplicationIdentity(bundleID: "com.test", name: "Test") }
        )
        return Reuse(
            provider: provider,
            text    : text,
            source  : context.source,
            sensing : sensing,
            seat    : context.seat,
            window  : context.window,
            windows : windows
        )
    }

    @Test("byte-identical pixels of the same window answer the last scene without the pipeline")
    func samePixelsReuseTheScene() async throws {
        let context = try await reuse(marker: 960)
        let processID = context.window.reference.processID

        let first = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 1, "with no previous frame the pipeline runs")
        let captures = context.source.requested.count
        let second = try await context.provider.currentScene(of: processID)

        #expect(context.source.requested.count == captures + 1, "every scene still takes a fresh observation")
        #expect(context.text.count == 1, "the pipeline did not run again")
        #expect(second == first)
        // The baseline path of AutomationTools: an equal scene is its unchanged sentence.
        #expect(SceneChanges.text(from: first.scene, to: second.scene, since: 1) == "Unchanged since revision 1.")
    }

    @Test("a change of one pixel byte runs the pipeline and never answers unchanged")
    func changedPixelsRunThePipeline() async throws {
        let context = try await reuse(marker: 961)
        let processID = context.window.reference.processID
        let first = try await context.provider.currentScene(of: processID)

        context.source.paint = { buffer in
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            CVPixelBufferGetBaseAddress(buffer)?.storeBytes(of: UInt8(1), toByteOffset: 4 * 33 + 2, as: UInt8.self)
        }
        let changed = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 2)
        #expect(SceneChanges.text(from: first.scene, to: changed.scene, since: 1) != "Unchanged since revision 1.")

        // The changed pixels are now the kept ones, and returning to the first pixels is a change too.
        let again = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 2)
        #expect(again == changed)
        context.source.paint = nil
        _ = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 3)
    }

    @Test("the same pixels of another window, or under another title, run the pipeline")
    func otherWindowRunsThePipeline() async throws {
        let context = try await reuse(marker: 962)
        let processID = context.window.reference.processID
        _ = try await context.provider.currentScene(of: processID)

        context.windows.rows = [WindowRow(layer: 0, frame: context.window.reference.frame, title: "Other",
                                          number: context.window.id)]
        _ = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 2, "the census title is part of what must match")

        let reference = ObservationAdmissionTests.reference(ObservationAdmissionTests.secondWindowNumber)
        context.sensing.additionalWindows[reference.windowNumber] = reference
        let other = try await context.seat.adopt(reference, platform: AppKitPlatform())
        #expect(context.seat.currentTarget?.id == other.id)
        context.windows.rows.append(WindowRow(layer: 0, frame: reference.frame, title: "Other", number: other.id))
        _ = try await context.provider.currentScene(of: processID)
        #expect(context.source.requested.last == reference.identity)
        #expect(context.text.count == 3)
    }

    @Test("a scene that failed is never kept, so the next identical pixels run the pipeline")
    func failedSceneIsNotKept() async throws {
        let context = try await reuse(marker: 963)
        let processID = context.window.reference.processID
        context.text.failsNext = true
        await #expect(throws: (any Error).self) { try await context.provider.currentScene(of: processID) }
        #expect(context.text.count == 1)

        _ = try await context.provider.currentScene(of: processID)
        #expect(context.text.count == 2)
    }
}
