import CoreGraphics
import Foundation
import InteractionListener
@testable import InteractionObservation
import PerceptionCore
import Testing

@Suite @MainActor
struct InteractionObservationTests {
    private var window: InteractionWindow {
        .init(processID: 42, number: 7, title: "Files", layer: 0,
              frame: CGRect(x: 0, y: 0, width: 500, height: 200))
    }
    private func scene(_ labels: [String]) -> SceneSnapshot {
        SceneSnapshot(bundleID: "test", appName: "Test", windowTitle: "Files",
                      viewportPixelSize: .init(width: 500, height: 200),
                      elements: labels.enumerated().map {
            SceneElement(id: $0.element, kind: .text, label: $0.element,
                         bounds: .init(x: 0.1, y: Double($0.offset) * 0.2, width: 0.2, height: 0.1))
        })
    }
    private func sample(_ labels: [String], revision: UInt64 = 2, start: Double = 10) -> InteractionSample {
        .init(window: window, scene: scene(labels), revision: revision, startedAt: start, completedAt: start + 0.1)
    }

    @Test func eventJoinsMatchingAmbientCaptureInsteadOfReportingBusy() async throws {
        let coordinator = InteractionCaptureCoordinator()
        let gate = CaptureGate()
        let expected = scene(["Music"])
        let ambient = Task { try await coordinator.read(window: window, revision: 2, priority: .ambient,
                                                        isCurrent: { true }) {
            await gate.wait()
            return expected
        } }
        await gate.started()
        let requested = CaptureGate()
        let event = Task { try await coordinator.read(window: window, revision: 2, priority: .event,
                                                      isCurrent: { requested.signal(); return true }) {
            Issue.record("A matching acquisition must be shared")
            return expected
        } }
        await requested.started()
        gate.release()
        let result = try await event.value
        _ = try await ambient.value
        #expect(result?.scene.elements.first?.label == "Music")
    }

    @Test func eventWaitsForOldCaptureThenReadsItsOwnRevision() async throws {
        let coordinator = InteractionCaptureCoordinator()
        let old = CaptureGate(), requested = CaptureGate()
        var revision: UInt64 = 1
        var loads = 0
        let ambient = Task { try await coordinator.read(window: window, revision: 1, priority: .ambient,
                                                        isCurrent: { revision == 1 }) {
            loads += 1
            await old.wait()
            return scene(["Old"])
        } }
        await old.started()
        revision = 2
        let event = Task { try await coordinator.read(window: window, revision: 2, priority: .event,
                                                      isCurrent: { requested.signal(); return revision == 2 }) {
            loads += 1
            return scene(["New"])
        } }
        await requested.started()
        let skipped = try await coordinator.read(window: window, revision: 2, priority: .ambient,
                                                  isCurrent: { true }) {
            Issue.record("Ambient read must yield to the event")
            return scene([])
        }
        #expect(skipped == nil)
        old.release()
        #expect(try await ambient.value == nil)
        let result = try await event.value
        #expect(result?.revision == 2)
        #expect(result?.scene.elements.first?.label == "New")
        #expect(loads == 2)
    }

    @Test func newInputWhileWaitingDoesNotStartAnObsoleteEventCapture() async throws {
        let coordinator = InteractionCaptureCoordinator()
        let gate = CaptureGate(), requested = CaptureGate()
        var valid = true
        let ambient = Task { try await coordinator.read(window: window, revision: 1, priority: .ambient,
                                                        isCurrent: { true }) {
            await gate.wait()
            return scene([])
        } }
        await gate.started()
        let event = Task { try await coordinator.read(window: window, revision: 2, priority: .event,
                                                      isCurrent: { requested.signal(); return valid }) {
            Issue.record("Obsolete event must not start a capture")
            return scene([])
        } }
        await requested.started()
        valid = false
        gate.release()
        #expect(try await event.value == nil)
        _ = try await ambient.value
    }

    @Test func cancellationJoinsAcquisitionBeforeReturning() async throws {
        let coordinator = InteractionCaptureCoordinator()
        let gate = CaptureGate()
        let task = Task { try await coordinator.read(window: window, revision: 1, priority: .event,
                                                     isCurrent: { true }) {
            await gate.wait()
            return scene([])
        } }
        await gate.started()
        task.cancel()
        gate.release()
        do { _ = try await task.value; Issue.record("Cancellation must be propagated") }
        catch is CancellationError { }
        let next = try await coordinator.read(window: window, revision: 2, priority: .event,
                                              isCurrent: { true }) { scene(["Next"]) }
        #expect(next?.revision == 2)
    }

    @Test func editableSecureAndUnknownFieldsNeverSupplyDisplayValues() {
        #expect(!InteractionAXLabel.allowsDisplayValue(role: "AXTextField", subrole: nil, valueIsSettable: true))
        #expect(!InteractionAXLabel.allowsDisplayValue(role: "AXTextField", subrole: nil, valueIsSettable: nil))
        #expect(!InteractionAXLabel.allowsDisplayValue(role: "AXTextField", subrole: "AXSecureTextField", valueIsSettable: false))
        #expect(InteractionAXLabel.allowsDisplayValue(role: "AXTextField", subrole: nil, valueIsSettable: false))
    }

    @Test func repeatedNewElementIsReportedButAnOverlappingRenameIsNotAnAppearance() {
        let before = sample(["Music"], revision: 1, start: 8)
        let result = InteractionDifference.compare(before: before, after: sample(["Music", "New Path"]),
                                                   confirmation: sample(["Music", "New Path"], start: 11))
        #expect(result.appeared == ["New Path"])
        let renamed = InteractionDifference.compare(before: before, after: sample(["Muslc"]),
                                                    confirmation: sample(["Muslc"], start: 11))
        #expect(renamed.appeared.isEmpty)
        #expect(renamed.disappeared.isEmpty)
    }

    @Test func sameCaptureCannotConfirmItself() {
        let after = sample(["New Path"])
        let result = InteractionDifference.compare(before: sample([], revision: 1, start: 8),
                                                   after: after, confirmation: after)
        #expect(result.status == "not_comparable")
    }

    @Test func captureFailureIsReportedAndDoesNotBlockTheNextRead() async throws {
        enum Failure: Error { case capture }
        let coordinator = InteractionCaptureCoordinator()
        do {
            _ = try await coordinator.read(window: window, revision: 1, priority: .event,
                                           isCurrent: { true }) { throw Failure.capture }
            Issue.record("The capture error must reach the caller")
        } catch Failure.capture { }
        let result = try await coordinator.read(window: window, revision: 2, priority: .event,
                                                isCurrent: { true }) { scene(["Recovered"]) }
        #expect(result?.scene.elements.first?.label == "Recovered")
    }

    @Test func nativeStateChangeRequiresAgreementAndTheSameContainer() {
        func native(_ state: ControlState, _ container: String, _ revision: UInt64, _ start: Double) -> InteractionSample {
            var snapshot = scene(["Enable"])
            snapshot.elements[0].kind = .control
            snapshot.elements[0].role = "AXCheckBox"
            snapshot.elements[0].container = container
            snapshot.elements[0].state = state
            return .init(window: window, scene: snapshot, revision: revision, startedAt: start, completedAt: start + 0.1)
        }
        let before = native(.off, "Panel A", 1, 8)
        let after = native(.on, "Panel A", 2, 10)
        let confirmed = native(.on, "Panel A", 2, 11)
        #expect(InteractionDifference.compare(before: before, after: after, confirmation: confirmed).stateChanges.count == 1)
        let other = native(.on, "Panel B", 2, 11)
        #expect(InteractionDifference.compare(before: before, after: after, confirmation: other).stateChanges.isEmpty)
    }

    @Test func afterPointResolutionAlsoPrefersNativeControlOverCaption() {
        let bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        var snapshot = scene([])
        snapshot.elements = [SceneElement(id: "caption", kind: .text, label: "Create", bounds: bounds),
                             SceneElement(id: "button", kind: .control, label: "Create", bounds: bounds, role: "AXButton")]
        #expect(InteractionResolution.at(point: CGPoint(x: 0.2, y: 0.2), in: snapshot).element?.id == "button")
    }

    @Test func renamableFinderEntryUsesFilenameInsteadOfEditableValue() {
        let result = InteractionAXLabel.resolve(0, facts: { _ in
            .init(role: "AXTextField", title: "", description: nil, displayValue: nil, filename: "Font Book")
        }, children: { _ in [] })
        #expect(result?.label == "Font Book")
        #expect(result?.source == "filename")
    }

    @Test func emptyAXTitleFallsThroughToDescriptionOrDisplayValue() {
        let description = InteractionAXLabel.resolve(0, facts: { _ in
            .init(role: "AXTextField", title: "", description: "Music", displayValue: nil)
        }, children: { _ in [] })
        #expect(description?.label == "Music")
        let value = InteractionAXLabel.resolve(0, facts: { _ in
            .init(role: "AXStaticText", title: " ", description: nil, displayValue: "Applications")
        }, children: { _ in [] })
        #expect(value?.label == "Applications")
    }

    @Test func nativeCellCanUseOneNamedDescendantButNotArbitrarySiblingText() {
        let result = InteractionAXLabel.resolve(0, facts: { n in
            .init(role: n == 0 ? "AXCell" : "AXStaticText", displayValue: n == 0 ? nil : "Messages")
        }, children: { $0 == 0 ? [1] : [] })
        #expect(result?.label == "Messages")
        let ambiguous = InteractionAXLabel.resolve(0, facts: { n in
            .init(role: n == 0 ? "AXCell" : "AXStaticText", displayValue: n == 0 ? nil : "Column \(n)")
        }, children: { $0 == 0 ? [1, 2] : [] })
        #expect(ambiguous == nil)
    }

    @Test func transientOCRDoesNotBecomeAnAppearedElement() {
        let result = InteractionDifference.compare(before: sample(["Applications"], revision: 1, start: 8),
                                                   after: sample(["4 Applications"]),
                                                   confirmation: sample(["Applications"], start: 11))
        #expect(result.appeared.isEmpty)
    }

    @Test func changedInputInvalidatesDifferenceConfirmation() {
        let result = InteractionDifference.compare(before: sample([], revision: 1, start: 8),
                                                   after: sample(["New Path"]),
                                                   confirmation: sample(["New Path"], revision: 3, start: 11))
        #expect(result.status == "not_comparable")
        #expect(result.appeared.isEmpty)
    }
}

@MainActor
private final class CaptureGate {
    private var hasStarted = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            waiting = continuation
            signal()
        }
    }
    func started() async {
        if hasStarted { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func signal() { hasStarted = true; startWaiter?.resume(); startWaiter = nil }
    func release() { waiting?.resume(); waiting = nil }
}
