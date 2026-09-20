import AutomationRuntime
import CoreGraphics
import Perception
import PerceptionCore
import Testing

@Suite("Production visual icons")
struct ProductionIconPerceptionTests {
    @Test("an unlabeled toolbar glyph is visible without accessibility or OCR text")
    func visualIconWithoutNativeFacts() async throws {
        let context = try #require(CGContext(
            data: nil,
            width: 600,
            height: 400,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.move(to: CGPoint(x: 60, y: 300))
        context.addLine(to: CGPoint(x: 60, y: 326))
        context.addLine(to: CGPoint(x: 84, y: 313))
        context.closePath()
        context.fillPath()
        let image = try #require(context.makeImage())
        let scene = try await ProductionPerception.pipeline().perceive(
            image,
            of: .init(bundleID: "test.icons", appName: "Icons", title: "Toolbar")
        )
        let glyph = scene.elements.filter {
            $0.kind == .icon && $0.bounds.cgRect.contains(CGPoint(x: 72.0 / 600, y: 87.0 / 400))
        }
        #expect(glyph.count == 1, "The production pipeline must detect the visible glyph from pixels.")
        #expect(glyph.first?.isUnlabeled == true)
        #expect(glyph.first?.state == nil)
    }
}
