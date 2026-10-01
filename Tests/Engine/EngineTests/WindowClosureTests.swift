import CoreGraphics
@testable import Engine
import EngineCore
import PerceptionCore
import Testing

@Suite("Window closure requires a complete, stable lifecycle reading")
struct WindowClosureTests {
    let origin = WindowRow(layer: 8, frame: CGRect(x: 20, y: 30, width: 600, height: 400), title: "I/O Setup", number: 10)
    let parent = WindowRow(layer: 0, frame: CGRect(x: 0, y: 0, width: 900, height: 700), title: "Edit", number: 11)

    private func closed(before: [WindowRow]?, first: [WindowRow]?, second: [WindowRow]?, visible: [WindowRow]? = nil) -> String? {
        let scene = SceneSnapshot(bundleID: "test.mixer", appName: "Mixer", windowTitle: "I/O Setup",
                                  viewportPixelSize: .init(width: 600, height: 400), elements: [])
        return WindowClosure.title(of: PerceivedWindow(scene: scene, frame: origin.frame),
                                   visible: visible ?? [origin, parent], before: before, first: first, second: second)
    }

    @Test func oneDestroyedWindow() {
        #expect(closed(before: [origin, parent], first: [parent], second: [parent]) == "I/O Setup")
    }

    @Test func hiddenIsNotDestroyed() {
        #expect(closed(before: [origin, parent], first: [origin, parent], second: [origin, parent]) == nil)
    }

    @Test func incompleteReadings() {
        #expect(closed(before: nil, first: [parent], second: [parent]) == nil)
        #expect(closed(before: [origin, parent], first: nil, second: [parent]) == nil)
        #expect(closed(before: [origin, parent], first: [parent], second: nil) == nil)
        #expect(closed(before: [parent], first: [parent], second: [parent]) == nil)
        #expect(closed(before: [origin, parent], first: [parent], second: [parent], visible: []) == nil)
    }

    @Test func unstableOrCollateralChanges() {
        let replacement = WindowRow(layer: 8, frame: origin.frame, title: origin.title, number: 12)
        #expect(closed(before: [origin, parent], first: [parent], second: [replacement, parent]) == nil)
        #expect(closed(before: [origin, parent], first: [origin, parent], second: [parent]) == nil)
        #expect(closed(before: [origin, parent], first: [], second: []) == nil)
        #expect(closed(before: [origin, parent, replacement], first: [parent], second: [parent]) == nil)
        #expect(closed(before: [origin, parent, replacement], first: [parent, replacement], second: [parent, replacement]) == nil)
    }

    @Test func titleAloneCannotIdentifyTheSource() {
        let duplicate = WindowRow(layer: origin.layer, frame: origin.frame, title: origin.title, number: 12)
        let moved = WindowRow(layer: origin.layer, frame: origin.frame.offsetBy(dx: 2, dy: 0), title: origin.title, number: 10)
        #expect(closed(before: [duplicate, origin, parent], first: [parent], second: [parent]) == nil)
        #expect(closed(before: [moved, parent], first: [parent], second: [parent]) == nil)
    }
}
