import XCTest
@testable import LocatorCore

final class DescriptorRoundTripTests: XCTestCase {
    func testFullyPopulatedRoundTrip() throws {
        let original = sampleDescriptor()
        let data = try DescriptorStore.makeEncoder().encode(original)
        let decoded = try DescriptorStore.makeDecoder().decode(Descriptor.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEncodingIsDeterministic() throws {
        let d = sampleDescriptor()
        let enc = DescriptorStore.makeEncoder()
        XCTAssertEqual(try enc.encode(d), try enc.encode(d), "sortedKeys must make encoding byte-stable")
    }

    func testSchemaVersionDefaultsWhenAbsent() throws {
        // Re-encode without the schemaVersion key by round-tripping through a dictionary.
        var obj = try JSONSerialization.jsonObject(with: try DescriptorStore.makeEncoder().encode(sampleDescriptor())) as! [String: Any]
        obj.removeValue(forKey: "schemaVersion")
        let data = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try DescriptorStore.makeDecoder().decode(Descriptor.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, Descriptor.currentSchemaVersion)
    }

    func testThresholdsDefaultWhenAbsentAtDescriptorLevel() throws {
        var obj = try JSONSerialization.jsonObject(with: try DescriptorStore.makeEncoder().encode(sampleDescriptor())) as! [String: Any]
        obj.removeValue(forKey: "thresholds")
        let data = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try DescriptorStore.makeDecoder().decode(Descriptor.self, from: data)
        XCTAssertEqual(decoded.thresholds, .defaults)
    }

    func testCropRefsAreBareFilenames() {
        let d = sampleDescriptor()
        let refs = [d.visual.cropRef, d.visual.contextCropRef] + d.visual.stateVariants.map(\.cropRef)
        for ref in refs {
            XCTAssertFalse(ref.contains("/"), "cropRef must be a bare filename, got \(ref)")
            XCTAssertTrue(ref.hasSuffix(".png"))
        }
    }
}
