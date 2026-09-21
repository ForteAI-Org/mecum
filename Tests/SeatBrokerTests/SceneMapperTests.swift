import CoreGraphics
import CVBackend
import LocatorCore
import Relocation
import Testing
@testable import SeatBroker

private func blankImage() -> CGImage {
    let ctx = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

@Test func mapsSceneElementsToIndexedObservation() {
    let snapshot = SceneSnapshot(bundleID: "b", app: "App", windowTitle: "T", viewportPx: [100, 50], elements: [
        SceneElement(id: "control|send", kind: "control", label: "Send", pos: [0.5, 0.5, 0.2, 0.1],
                     role: "AXButton", state: "off"),
        SceneElement(id: "text|hi", kind: "text", label: "hi", pos: [0, 0, 0.1, 0.1]),
    ], commands: [])
    let scene = PerceivedScene(snapshot: snapshot, ocrFrame: OCRFrame(grid: .empty(width: 100, height: 50), runs: []))
    let observation = LocatorSceneMapper.observation(from: scene, image: blankImage())

    #expect(observation.elements.map(\.index) == [1, 2])
    #expect(observation.elements[0].label == "Send")
    let center = observation.elements[0].center(in: observation.pixelSize)
    #expect(abs(center.x - 60) < 1e-9)
    #expect(abs(center.y - 27.5) < 1e-9)
    #expect(observation.text.contains("[1] control/AXButton · Send [off]"))
    #expect(observation.token == snapshot.token)
}
