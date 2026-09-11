//
//  PrimitiveRequirementTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

@testable import PrivateSymbols
@testable import SeatCore
import Testing

/// The spelling of a primitive is its identity, so these are the tests that
/// keep the spelling from drifting silently: on 26A5425a both
/// `SLPSSetFrontProcessWithOptions` and `_SLPSSetFrontProcessWithOptions`
/// exist as different exports, and a Ledger row that names the concept instead
/// of the export says nothing.
@Suite("Primitive names and requirements")
struct PrimitiveRequirementTests {

    @Test("every symbol carries its exact spelling")
    func exactSpellings() {
        #expect(PrivateSymbol.mainConnectionID.rawValue     == "SLSMainConnectionID")
        #expect(PrivateSymbol.getWindowOwner.rawValue       == "SLSGetWindowOwner")
        #expect(PrivateSymbol.getConnectionPSN.rawValue     == "SLSGetConnectionPSN")
        #expect(PrivateSymbol.eventRecordPointer.rawValue   == "SLEventRecordPointer")
        #expect(PrivateSymbol.postEventRecordTo.rawValue    == "SLPSPostEventRecordTo")
        #expect(PrivateSymbol.setWindowLocation.rawValue    == "CGEventSetWindowLocation")
        #expect(PrivateSymbol.setIntegerValueField.rawValue == "SLEventSetIntegerValueField")
        #expect(PrivateSymbol.messageSend.rawValue          == "objc_msgSend")
        #expect(PrivateSymbol.axUIElementGetWindow.rawValue == "_AXUIElementGetWindow")
        #expect(PrivateSymbol.setFrontProcess.rawValue == "_SLPSSetFrontProcessWithOptions")
        #expect(PrivateSymbol.getFrontProcess.rawValue == "_SLPSGetFrontProcess")
        #expect(Facility.focusRecovery.requirements.contains(.symbol(.getFrontProcess)))
        #expect(!Facility.input.requirements.contains(.symbol(.getFrontProcess)))
        #expect(PrivateSymbol.allCases.count == 11)
    }

    @Test("a selector's Ledger key is its class and its spelling")
    func selectorKeys() {
        #expect(PrivateSelector.initWithDescriptor.ledgerKey == "CGVirtualDisplay.initWithDescriptor:")
        #expect(PrivateSelector.applySettings.ledgerKey      == "CGVirtualDisplay.applySettings:")
        #expect(
            PrivateSelector.initWithMode.ledgerKey
                == "CGVirtualDisplayMode.initWithWidth:height:refreshRate:"
        )
    }

    @Test("a requirement's key and kind are one statement")
    func requirementKeysAndKinds() {
        let cases: [(PrimitiveRequirement, String, PrimitiveKind)] = [
            (.symbol(.eventRecordPointer),      "SLEventRecordPointer",                 .symbol),
            (.objcClass(.virtualDisplay),       "CGVirtualDisplay",                     .objcClass),
            (.selector(.applySettings),         "CGVirtualDisplay.applySettings:",      .selector),
            (.field("CGEvent.integerValueField.51"), "CGEvent.integerValueField.51",    .field),
            (.record("SLPSPostEventRecordTo.keyWindowRecord"),
             "SLPSPostEventRecordTo.keyWindowRecord",                                   .record),
            (.behavior("CGVirtualDisplay.releaseRemovesDisplay"),
             "CGVirtualDisplay.releaseRemovesDisplay",                                  .behavior),
        ]
        for (requirement, key, kind) in cases {
            #expect(requirement.ledgerKey == key)
            #expect(requirement.kind      == kind)
        }
    }

    @Test("the class kind is spelled class in the file, not objcClass")
    func classKindRawValue() {
        #expect(PrimitiveKind.objcClass.rawValue == "class")
    }

    @Test("each Facility asks for the grants it cannot work without")
    func facilityPermissions() {
        #expect(Facility.display.permissions == [.accessibility])
        #expect(Facility.input.permissions   == [.postEvent])
        #expect(Facility.windowIdentity.permissions.isEmpty)
        #expect(Facility.fence.permissions   == [.accessibility])
        #expect(Facility.capture.permissions == [.screenRecording])
        #expect(Facility.all.map(\.name) == ["display", "input", "fence", "capture"])
    }

    @Test("window identity uses only the three promoted read primitives")
    func windowIdentityRequirements() {
        #expect(Facility.windowIdentity.requirements == [
            .symbol(.mainConnectionID),
            .symbol(.getWindowOwner),
            .symbol(.getConnectionPSN),
        ])
    }

    @Test("only the Facilities that touch the record run the record self check")
    func recordSelfCheckScope() {
        #expect(Facility.input.requirements.contains(.symbol(.eventRecordPointer)))
        for facility in [Facility.display, .fence, .capture] {
            #expect(!facility.requirements.contains(.symbol(.eventRecordPointer)))
        }
    }
}
