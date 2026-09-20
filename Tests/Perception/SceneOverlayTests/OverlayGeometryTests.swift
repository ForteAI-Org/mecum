import CoreGraphics
import SceneOverlay
import Testing

@Suite("Overlay geometry")
struct OverlayGeometryTests {
    @Test func transparentSystemCanvasesDoNotHideEveryBox() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(!OverlayGeometry.canOcclude(frame: screen, layer: 20, ownerBundleID: "com.apple.dock", displays: [screen]))
        #expect(!OverlayGeometry.canOcclude(frame: screen, layer: 2997, ownerBundleID: nil, displays: [screen]))
        #expect(OverlayGeometry.canOcclude(frame: screen, layer: 0, ownerBundleID: "app", displays: [screen]))
        #expect(OverlayGeometry.canOcclude(frame: CGRect(x: 0, y: 900, width: 500, height: 82),
                                         layer: 20, ownerBundleID: "com.apple.dock", displays: [screen]))
    }

    @Test func mapsDisplaysLeftAndAbovePrimaryWithoutUsingRetinaPixels() {
        let frame = CGRect(x: -800, y: -600, width: 500, height: 400)
        let appKit = OverlayGeometry.appKitFrame(frame, primaryHeight: 900)
        #expect(appKit == CGRect(x: -800, y: 1100, width: 500, height: 400))
        #expect(OverlayGeometry.appKitFrame(appKit, primaryHeight: 900) == frame)
    }

    @Test func occlusionLeavesDisjointVisibleAreas() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let cover = CGRect(x: 25, y: 25, width: 50, height: 50)
        let parts = OverlayGeometry.visibleParts(of: frame, occludedBy: [cover])
        #expect(parts.reduce(0) { $0 + $1.width * $1.height } == 7500)
        #expect(parts.allSatisfy { $0.intersection(cover).isEmpty || $0.intersection(cover).isNull })
        for index in parts.indices {
            for other in parts.indices where other > index {
                let overlap = parts[index].intersection(parts[other])
                #expect(overlap.isNull || overlap.isEmpty)
            }
        }
    }

    @Test func fullCoverAndExternalCover() {
        let frame = CGRect(x: 20, y: 40, width: 100, height: 80)
        #expect(OverlayGeometry.visibleParts(of: frame, occludedBy: [frame]).isEmpty)
        #expect(OverlayGeometry.visibleParts(of: frame, occludedBy: [CGRect(x: 500, y: 0, width: 10, height: 10)]) == [frame])
    }
}
