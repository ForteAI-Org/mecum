import XCTest
import CoreGraphics
import Foundation
import LocatorCore
@testable import Relocation

final class ImageContentIntegrationTests: XCTestCase {
    func testPhotoOverlayRemainsUnknownAndNeverBecomesASwitch() {
        let w = 900, h = 600
        var bytes = [UInt8](repeating: 30, count: w * h * 4)
        var seed: UInt64 = 88172645463325252
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            if x >= 250, x < 850, y >= 100, y < 450 {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                bytes[i] = UInt8(40 + (x + y + Int(seed & 63)) % 170)
                bytes[i + 1] = UInt8(30 + (2 * x + Int(seed & 127)) % 190)
                bytes[i + 2] = UInt8(20 + (3 * y + Int(seed & 63)) % 200)
            }
            if x >= 650, x < 790, y >= 220, y < 380 {
                let chevron = y >= 260 && y <= 320 && abs(x - (725 - abs(y - 290))) < 5
                let v: UInt8 = chevron ? 240 : 30
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
            }
            bytes[i + 3] = 255
        } }
        let image = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let builder = SceneBuilder(icons: IconStore(directory: empty), knowledge: KnowledgeStore(directory: empty))
        let layers = builder.detectLayers(in: image, appIcons: nil)
        XCTAssertEqual(layers.elements.filter { $0.kind == "image" }.count, 1)
        XCTAssertLessThan(layers.uiSegments.count, layers.rawSegments.count)
        let overlays = layers.elements.filter { $0.kind == "overlay-candidate" }
        XCTAssertFalse(overlays.isEmpty, "the real chevron must remain available to the decision layer")
        XCTAssertTrue(overlays.allSatisfy { $0.unlabeled && $0.label.isEmpty && $0.state == nil })
        XCTAssertFalse(layers.elements.contains { $0.state != nil }, "photo details must not acquire toggle states")
    }
}
