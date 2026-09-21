import XCTest
import CoreGraphics
import LocatorCore
@testable import Relocation

final class SceneCacheTests: XCTestCase {
    private func marker(x: Int, width: Int = 640, height: Int = 640) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: x, y: 100, width: 3, height: 8))
        return ctx.makeImage()!
    }

    func testMovementInsideOneThumbnailCellInvalidatesScene() {
        // Both marks lie inside one 20x20 thumbnail cell. Averaging erases where the mark is.
        XCTAssertNotEqual(SceneBuilder.SceneCache.fingerprint(marker(x: 101)),
                          SceneBuilder.SceneCache.fingerprint(marker(x: 111)))
    }

    func testWindowIdentityAndTTLGuardReuse() {
        let cache = SceneBuilder.SceneCache()
        let now = Date(timeIntervalSince1970: 100)
        let fingerprint = SceneBuilder.SceneCache.fingerprint(marker(x: 101))
        let scene = SceneSnapshot(bundleID: "test", app: "Test", windowTitle: "A", viewportPx: [640, 640], elements: [], sections: [], commands: [])
        cache.store(bundle: "test", fingerprint: fingerprint, scene: scene, now: now)
        XCTAssertNotNil(cache.lookup(bundle: "test", windowTitle: "A", fingerprint: fingerprint, now: now))
        XCTAssertNil(cache.lookup(bundle: "test", windowTitle: "B", fingerprint: fingerprint, now: now))
        XCTAssertNil(cache.lookup(bundle: "test", windowTitle: "A", fingerprint: fingerprint, now: now.addingTimeInterval(3)))
        XCTAssertNil(cache.lookup(bundle: "test", windowTitle: "A", fingerprint: nil, now: now))
        cache.store(bundle: "test", fingerprint: nil, scene: scene, now: now)
        XCTAssertNil(cache.latest(bundle: "test", now: now, maxAge: 30))
    }

    func testDimensionsParticipateInFingerprint() {
        XCTAssertNotEqual(SceneBuilder.SceneCache.fingerprint(marker(x: 101, width: 640, height: 320)),
                          SceneBuilder.SceneCache.fingerprint(marker(x: 101, width: 320, height: 640)))
    }

    func testIdenticalFrameCanReusePerception() {
        XCTAssertEqual(SceneBuilder.SceneCache.fingerprint(marker(x: 101)),
                       SceneBuilder.SceneCache.fingerprint(marker(x: 101)))
    }
}
