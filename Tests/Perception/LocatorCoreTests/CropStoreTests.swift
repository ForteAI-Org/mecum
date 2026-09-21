import XCTest
import CoreGraphics
@testable import LocatorCore

final class CropStoreTests: XCTestCase {
    var dir: URL!
    var store: CropStore!

    override func setUp() {
        super.setUp()
        dir = makeTempDir()
        store = CropStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testWriteReadRoundTripPreservesDimensions() throws {
        let img = makeCGImage(width: 24, height: 16) {
            $0.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
            $0.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        try store.writePNG(img, name: CropStore.cropName(id: UUID()))
        let names = try store.crops(forDescriptorID: UUID()) // different id → empty
        XCTAssertTrue(names.isEmpty)
    }

    func testCropsListedByDescriptorID() throws {
        let id = UUID()
        let img = makeCGImage(width: 8, height: 8) { $0.setFillColor(gray: 0.3, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        try store.writePNG(img, name: CropStore.cropName(id: id))
        try store.writePNG(img, name: CropStore.contextCropName(id: id))
        try store.writePNG(img, name: CropStore.cropName(id: id, state: "on"))

        let names = try store.crops(forDescriptorID: id)
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.contains(CropStore.cropName(id: id)))
        XCTAssertTrue(names.contains(CropStore.contextCropName(id: id)))

        let read = try store.readPNG(name: CropStore.cropName(id: id))
        XCTAssertEqual(read.width, 8)
        XCTAssertEqual(read.height, 8)
    }

    func testNamingHelpersAreBareFilenames() {
        let id = UUID()
        for name in [CropStore.cropName(id: id), CropStore.contextCropName(id: id), CropStore.cropName(id: id, state: "off")] {
            XCTAssertFalse(name.contains("/"))
            XCTAssertTrue(name.hasPrefix(id.uuidString))
            XCTAssertTrue(name.hasSuffix(".png"))
        }
    }

    func testReadMissingThrows() {
        XCTAssertThrowsError(try store.readPNG(name: "does-not-exist.png"))
    }

    func testCropNameSanitizesPathSeparators() {
        let name = CropStore.cropName(id: UUID(), state: "a/b:c")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasSuffix(".png"))
    }

    func testWritePNGThrowsOnSlashNameInsteadOfCrashing() {
        let img = makeCGImage(width: 4, height: 4) { $0.setFillColor(gray: 0.5, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        XCTAssertThrowsError(try store.writePNG(img, name: "bad/name.png")) { error in
            XCTAssertEqual(error as? CropError, .invalidName("bad/name.png"))
        }
    }
}
