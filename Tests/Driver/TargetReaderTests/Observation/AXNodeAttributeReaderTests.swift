//
//  AXNodeAttributeReaderTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import ApplicationServices
import Foundation
import Testing

@testable import TargetReader

/// The reader's whole job is telling a provider's quirk apart from a lost
/// subtree, so every case here injects an error instead of reading a real
/// window: no application is launched and no accessibility grant is needed.
///
/// The policy comes from a real provider: a standard text editor answers
/// `AXError.failure` for `AXDescription` on nodes whose role, children and value
/// read perfectly well.
@Suite("The aggregated accessibility read")
struct AXNodeAttributeReaderTests {

    private static let names = [
        kAXRoleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute, kAXValueAttribute,
    ]

    private static func encoded(_ error: AXError) -> AnyObject {
        var error = error
        // A nil here would mean AXValueCreate itself failed, which is not the
        // case this fixture is about.
        return AXValueCreate(.axError, &error) ?? NSNull()
    }

    private static var values: [AnyObject] {
        [
            "AXTextArea" as NSString,
            encoded(.failure),
            [] as NSArray,
            "TextEdit draft" as NSString,
        ]
    }

    @Test("optional metadata that answers an error is a warning, not a lost node")
    func optionalMetadataIsAWarning() {
        var reads: [String] = []
        let absent = AXNodeAttributeReader.read(
            names     : Self.names,
            bulkError : .success,
            bulkValues: Self.values
        ) { name in
            reads.append(name)
            return (.failure, nil)
        }

        #expect(absent.failure == nil)
        #expect(absent.warnings.count == 1)
        #expect(absent.values[kAXDescriptionAttribute] == nil)
        #expect(absent.values[kAXRoleAttribute] as? String == "AXTextArea")
        #expect((absent.values[kAXChildrenAttribute] as? NSArray)?.count == 0)
        #expect(absent.values[kAXValueAttribute] as? String == "TextEdit draft")
        // Only the attribute that failed is asked again: a retry of the whole
        // node would double the cost of every node in a large tree.
        #expect(reads == [kAXDescriptionAttribute])
    }

    @Test("a single attribute retry recovers what the bulk read lost")
    func retryRecoversTheValue() {
        let recovered = AXNodeAttributeReader.read(
            names     : Self.names,
            bulkError : .success,
            bulkValues: Self.values
        ) { _ in (.success, "Document" as NSString) }

        #expect(recovered.failure == nil)
        #expect(recovered.warnings.isEmpty)
        #expect(recovered.values[kAXDescriptionAttribute] as? String == "Document")
    }

    @Test("children that cannot be read are still blocking")
    func unreadableChildrenBlock() {
        var lostChildren = Self.values
        lostChildren[2] = Self.encoded(.failure)
        let incomplete = AXNodeAttributeReader.read(
            names     : Self.names,
            bulkError : .success,
            bulkValues: lostChildren
        ) { _ in (.failure, nil) }

        #expect(incomplete.failure?.contains("AXChildren") == true)
    }

    @Test("a value that cannot be read does not become a valid empty field")
    func unreadableValueBlocks() {
        var lostValue = Self.values
        lostValue[3] = Self.encoded(.failure)
        let unreadable = AXNodeAttributeReader.read(
            names     : Self.names,
            bulkError : .success,
            bulkValues: lostValue
        ) { _ in (.failure, nil) }

        #expect(unreadable.failure?.contains("AXValue") == true)
    }

    @Test("an invalid element stays an error and is never read again")
    func invalidElementIsNotRetried() {
        let dead = AXNodeAttributeReader.read(
            names     : Self.names,
            bulkError : .invalidUIElement,
            bulkValues: nil
        ) { _ in
            Issue.record("an invalid element must not be read attribute by attribute")
            return (.failure, nil)
        }

        #expect(dead.failure != nil)
    }

    @Test("an unsupported attribute is absent without failing the node")
    func unsupportedAttributeIsAbsent() {
        var unsupported = Self.values
        unsupported[1] = Self.encoded(.attributeUnsupported)
        let optional = AXNodeAttributeReader.read(
            names     : Self.names,
            bulkError : .success,
            bulkValues: unsupported
        ) { _ in
            Issue.record("an unsupported attribute needs no retry")
            return (.failure, nil)
        }

        #expect(optional.failure == nil)
        #expect(optional.warnings.isEmpty)
    }

    @Test("a provider with no bulk read gets exactly the same treatment")
    func providerWithoutBulkRead() {
        let values = Self.values
        let scalar = AXNodeAttributeReader.read(
            names     : Self.names,
            bulkError : .notImplemented,
            bulkValues: nil
        ) { name in
            guard name != kAXDescriptionAttribute else { return (.failure, nil) }
            guard let index = Self.names.firstIndex(of: name) else { return (.noValue, nil) }
            return (.success, values[index])
        }

        #expect(scalar.failure == nil)
        #expect(scalar.warnings.count == 1)
    }

    @Test("a node with no role is the one thing that really invalidates it")
    func missingRoleInvalidatesTheNode() {
        let roleless = AXNodeAttributeReader.read(
            names     : Self.names,
            bulkError : .success,
            bulkValues: [
                Self.encoded(.noValue),
                "a description" as NSString,
                [] as NSArray,
                "" as NSString,
            ]
        ) { _ in (.noValue, nil) }

        #expect(roleless.failure == "accessibility role unavailable")
    }
}
