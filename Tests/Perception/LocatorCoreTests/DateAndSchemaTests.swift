import XCTest
@testable import LocatorCore

/// Locks the timestamp + schema-version contracts that the original integer-second fixtures masked.
final class DateAndSchemaTests: XCTestCase {
    func testQuantizedFractionalTimestampsRoundTripExactly() throws {
        var d = sampleDescriptor()
        // A sub-second timestamp that would be truncated by the stock .iso8601 strategy.
        d.created = LocatorTime.quantized(Date(timeIntervalSince1970: 1_700_000_000.123456))
        d.lastVerified = LocatorTime.now()

        let data = try DescriptorStore.makeEncoder().encode(d)
        let decoded = try DescriptorStore.makeDecoder().decode(Descriptor.self, from: data)

        XCTAssertEqual(decoded, d)
        XCTAssertEqual(decoded.created, d.created)
        XCTAssertEqual(decoded.lastVerified, d.lastVerified)
    }

    func testLocatorTimeQuantizesToMillisecond() {
        let q = LocatorTime.quantized(Date(timeIntervalSince1970: 1_700_000_000.123456))
        // Quantized value is on a whole-millisecond grid.
        XCTAssertEqual(q.timeIntervalSince1970, 1_700_000_000.123, accuracy: 1e-9)
    }

    func testFutureSchemaVersionIsRejected() throws {
        var obj = try JSONSerialization.jsonObject(with: try DescriptorStore.makeEncoder().encode(sampleDescriptor())) as! [String: Any]
        obj["schemaVersion"] = Descriptor.currentSchemaVersion + 1
        let data = try JSONSerialization.data(withJSONObject: obj)
        XCTAssertThrowsError(try DescriptorStore.makeDecoder().decode(Descriptor.self, from: data)) { error in
            XCTAssertEqual(
                error as? StoreError,
                .unsupportedSchemaVersion(found: Descriptor.currentSchemaVersion + 1, supported: Descriptor.currentSchemaVersion)
            )
        }
    }
}
