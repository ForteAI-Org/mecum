import CoreGraphics
import Foundation
import InteractionListener
import InteractionObservation
import PerceptionCore
import Testing

@Suite
struct InteractionResolutionTests {
    private let window = InteractionWindow(processID: 42, number: 7, title: "New Paths", layer: 0,
                                           frame: CGRect(x: 100, y: 200, width: 500, height: 200))

    private func event(revision: UInt64 = 1, point: CGPoint = CGPoint(x: 350, y: 300)) -> InteractionEvent {
        InteractionEvent(kind: .click, timestamp: Date(timeIntervalSince1970: 0), startedAt: 10, endedAt: 10,
                         precedingRevision: revision, revision: revision + 1, point: point, window: window, processID: 42)
    }

    private func sample(elements: [SceneElement], revision: UInt64 = 1, completed: Double = 9.5) -> InteractionSample {
        let scene = SceneSnapshot(bundleID: "test.app", appName: "Test", windowTitle: "New Paths",
                                  viewportPixelSize: .init(width: 1000, height: 400), elements: elements)
        return InteractionSample(window: window, scene: scene, revision: revision, startedAt: 9, completedAt: completed)
    }

    @Test func nativeButtonWinsItsTextCaptionAndNameResolverAgrees() {
        let button = SceneElement(id: "button", kind: .control, label: "Create",
                                  bounds: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.2), role: "AXButton")
        let text = SceneElement(id: "caption", kind: .text, label: "Create",
                                bounds: .init(x: 0.45, y: 0.45, width: 0.1, height: 0.1))
        let hit = InteractionResolution.resolve(event: event(), sample: sample(elements: [text, button]))
        #expect(hit.element?.id == "button")
        #expect(hit.nameResolution == "same_element")
    }

    @Test func rejectsScenesCapturedAcrossOrAfterTheClick() {
        #expect(InteractionResolution.resolve(event: event(), sample: sample(elements: [], completed: 10.1)).status == "stale_before_scene")
        #expect(InteractionResolution.resolve(event: event(), sample: sample(elements: [], revision: 0)).status == "intervening_input")
        #expect(InteractionResolution.resolve(event: event(), sample: nil).status == "no_before_scene")
    }

    @Test func sameProcessDifferentWindowCannotSupplyAHit() {
        let other = InteractionWindow(processID: 42, number: 8, title: "Menu", layer: 101, frame: window.frame)
        let original = sample(elements: [])
        let wrong = InteractionSample(window: other, scene: original.scene, revision: 1, startedAt: 9, completedAt: 9.5)
        #expect(InteractionResolution.resolve(event: event(), sample: wrong).status == "different_window")
    }

    @Test func equalOverlappingControlsRemainAmbiguous() {
        let bounds = NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let elements = ["A", "B"].map { SceneElement(id: $0, kind: .control, label: $0, bounds: bounds, role: "AXButton") }
        let hit = InteractionResolution.resolve(event: event(), sample: sample(elements: elements))
        #expect(hit.status == "ambiguous")
        #expect(hit.element == nil)
    }

    @Test func windowAtPointIncludesPopupLayersAndNegativeCoordinates() {
        let popup = InteractionWindow(processID: 42, number: 8, title: nil, layer: 101,
                                      frame: CGRect(x: -100, y: 0, width: 100, height: 100))
        #expect(InteractionWindowReader.window(at: CGPoint(x: -50, y: 50), in: [popup, window], recipientWindowNumber: popup.number, targetProcessID: popup.processID) == popup)
        #expect(InteractionWindowReader.window(at: CGPoint(x: -500, y: 50), in: [popup, window]) == nil)
    }
}
