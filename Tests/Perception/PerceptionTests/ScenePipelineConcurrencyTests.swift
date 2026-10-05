import CoreGraphics
import Dispatch
import Foundation
import Perception
import PerceptionCore
import Synchronization
import Testing

@Suite("Perception scheduling")
struct ScenePipelineConcurrencyTests {
    private final class OverlapProbe: Sendable {
        let nativeStarted = DispatchSemaphore(value: 0)
        let overlapped = Mutex(false)
    }

    private struct WaitingText: TextRecognizing {
        let probe: OverlapProbe
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] {
            let result = probe.nativeStarted.wait(timeout: .now() + 2) == .success
            probe.overlapped.withLock { $0 = result }
            return []
        }
    }

    private struct SignalingNative: SceneAugmenting {
        let probe: OverlapProbe
        func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> AccessibilityHarvest {
            probe.nativeStarted.signal()
            return .none
        }
    }

    private struct ThreadCheckingSections: SectionDetecting {
        func sections(in image: CGImage, protecting text: [CGRect]) throws -> [CGRect] {
            #expect(!Thread.isMainThread, "pixel scans must not freeze the overlay/input run loop")
            return []
        }
    }

    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    @Test func nativeReadStartsWhileOCRIsStillRunning() async throws {
        let probe = OverlapProbe()
        let pipeline = ScenePipeline(text: WaitingText(probe: probe), augmentation: SignalingNative(probe: probe))
        _ = try await pipeline.perceive(image(), of: .init(bundleID: "test", appName: "Test", title: "",
            processID: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(probe.overlapped.withLock { $0 })
    }

    @Test @MainActor func mainActorCallerDoesNotRunPixelAnalysisOnMainThread() async throws {
        let pipeline = ScenePipeline(text: ScenePipelineTests.FixedText(runs: []), sections: ThreadCheckingSections())
        _ = try await pipeline.perceive(image(), of: .init(bundleID: "test", appName: "Test", title: ""))
    }

    @Test func cancelledObservationDoesNotStartRecognition() async throws {
        let capture = try image()
        let pipeline = ScenePipeline(text: ScenePipelineTests.FixedText(runs: [], failure: ScenePipelineTests.Unavailable()))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pipeline.perceive(capture, of: .init(bundleID: "test", appName: "Test", title: ""))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
