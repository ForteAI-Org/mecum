import XCTest
@testable import LocatorCore

final class DescriptorStoreTests: XCTestCase {
    var dir: URL!
    var store: DescriptorStore!

    override func setUp() {
        super.setUp()
        dir = makeTempDir()
        store = DescriptorStore(directory: dir, maxVersions: 5)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testSaveLoadRoundTrip() throws {
        let d = sampleDescriptor()
        try store.save(d)
        XCTAssertEqual(try store.load(id: d.id), d)
    }

    func testListAndDelete() throws {
        let a = sampleDescriptor(), b = sampleDescriptor()
        try store.save(a)
        try store.save(b)
        XCTAssertEqual(Set(try store.list()), Set([a.id, b.id]))

        try store.delete(id: a.id)
        XCTAssertEqual(try store.list(), [b.id])
        XCTAssertThrowsError(try store.load(id: a.id)) { error in
            XCTAssertEqual(error as? StoreError, .notFound(a.id))
        }
    }

    func testListIgnoresNonDescriptorFiles() throws {
        let d = sampleDescriptor()
        try store.save(d)
        // An interrupted/partial write and an unrelated file must both be ignored.
        try Data("partial".utf8).write(to: dir.appendingPathComponent("\(d.id.uuidString).json.tmp"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("not-a-uuid.json"))
        XCTAssertEqual(try store.list(), [d.id])
    }

    func testDeleteRemovesCrops() throws {
        let d = sampleDescriptor()
        try store.save(d)
        let crops = CropStore(directory: dir)
        let img = makeCGImage(width: 8, height: 8) { $0.setFillColor(gray: 0.5, alpha: 1); $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        try crops.writePNG(img, name: CropStore.cropName(id: d.id))
        try crops.writePNG(img, name: CropStore.contextCropName(id: d.id))
        XCTAssertEqual(try crops.crops(forDescriptorID: d.id).count, 2)

        try store.delete(id: d.id)
        XCTAssertEqual(try crops.crops(forDescriptorID: d.id), [])
    }

    func testVersionArchiveAndRollback() throws {
        let id = UUID()
        try store.save(sampleDescriptor(id: id, version: 1))
        try store.save(sampleDescriptor(id: id, version: 2))
        try store.save(sampleDescriptor(id: id, version: 3))

        XCTAssertEqual(try store.load(id: id).version, 3)
        // Archives hold the two prior canonical versions, newest first.
        XCTAssertEqual(try store.archivedVersions(id: id).map(\.version), [2, 1])

        XCTAssertEqual(try store.rollback(id: id).version, 2)
        XCTAssertEqual(try store.load(id: id).version, 2)
        XCTAssertEqual(try store.rollback(id: id).version, 1)
        XCTAssertEqual(try store.load(id: id).version, 1)
        XCTAssertThrowsError(try store.rollback(id: id)) { error in
            XCTAssertEqual(error as? StoreError, .noPriorVersion(id))
        }
    }

    func testRollbackSkipsCorruptArchive() throws {
        let id = UUID()
        try store.save(sampleDescriptor(id: id, version: 1))
        try store.save(sampleDescriptor(id: id, version: 2))   // archives v1 at index 1
        try store.save(sampleDescriptor(id: id, version: 3))   // archives v2 at index 2

        // Corrupt the newest archive (index 2 == version 2).
        let corrupt = dir.appendingPathComponent("versions/\(id.uuidString)/2.json")
        try Data("not valid json".utf8).write(to: corrupt)

        // Rollback walks past the corrupt v2 and restores the older, valid v1 instead of throwing.
        XCTAssertEqual(try store.rollback(id: id).version, 1)
        XCTAssertEqual(try store.load(id: id).version, 1)
    }

    func testVersionHistoryIsPruned() throws {
        let smallStore = DescriptorStore(directory: dir, maxVersions: 2)
        let id = UUID()
        for v in 1...5 { try smallStore.save(sampleDescriptor(id: id, version: v)) }
        let archived = try smallStore.archivedVersions(id: id)
        XCTAssertEqual(archived.count, 2)
        XCTAssertEqual(archived.map(\.version), [4, 3])  // newest retained, older pruned
    }
}
