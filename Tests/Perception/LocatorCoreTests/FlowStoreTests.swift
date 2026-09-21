import XCTest
@testable import LocatorCore

final class FlowStoreTests: XCTestCase {
    var dir: URL!
    var store: FlowStore!

    override func setUp() { super.setUp(); dir = makeTempDir(); store = FlowStore(directory: dir) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    private func flow(_ name: String) -> Flow {
        Flow(name: name, bundleID: "com.avid.ProTools", stepIDs: [UUID(), UUID()],
             created: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testSaveLoadRoundTrip() throws {
        let f = flow("My Flow")
        try store.save(f)
        XCTAssertEqual(try store.load(name: "My Flow"), f)   // name preserved; filename sanitized
    }

    func testListAndDelete() throws {
        try store.save(flow("alpha"))
        try store.save(flow("beta"))
        XCTAssertEqual(Set(try store.list().map(\.name)), ["alpha", "beta"])

        try store.delete(name: "alpha")
        XCTAssertEqual(try store.list().map(\.name), ["beta"])
        XCTAssertThrowsError(try store.load(name: "alpha")) { XCTAssertEqual($0 as? FlowError, .notFound("alpha")) }
    }

    func testNameWithSpecialCharactersRoundTrips() throws {
        let f = flow("Mix: bus 1/2")
        try store.save(f)
        XCTAssertEqual(try store.load(name: "Mix: bus 1/2").name, "Mix: bus 1/2")
    }
}
