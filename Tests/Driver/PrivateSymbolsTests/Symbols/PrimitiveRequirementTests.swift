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
        #expect(PrivateSymbol.getWindowBounds.rawValue == "SLSGetWindowBounds")
        #expect(Facility.focusRecovery.requirements.contains(.symbol(.getFrontProcess)))
        #expect(!Facility.input.requirements.contains(.symbol(.getFrontProcess)))
        #expect(PrivateSymbol.copySpacesForWindows.rawValue == "SLSCopySpacesForWindows")
        #expect(PrivateSymbol.copyManagedDisplaySpaces.rawValue == "SLSCopyManagedDisplaySpaces")
        #expect(PrivateSymbol.allCases.count == 14)
    }

    /// The unlisted-window reading is its own Facility. Folding its unpromoted
    /// primitive into the identity Facility would turn every ordinary identity
    /// reading unvalidated over a symbol those readings never call.
    @Test("the unlisted window geometry keeps its primitive out of the other facilities")
    func remoteWindowGeometryIsSeparate() {
        #expect(
            Facility.remoteWindowGeometry.requirements.contains(.symbol(.getWindowBounds))
        )
        #expect(!Facility.windowIdentity.requirements.contains(.symbol(.getWindowBounds)))
        #expect(!Facility.input.requirements.contains(.symbol(.getWindowBounds)))
        #expect(!Facility.display.requirements.contains(.symbol(.getWindowBounds)))
        #expect(!Facility.all.contains(Facility.remoteWindowGeometry))

        // It still needs the whole identity chain: a rectangle without an
        // attested owner is not geometry anybody may act on.
        for requirement in Facility.windowIdentity.requirements {
            #expect(Facility.remoteWindowGeometry.requirements.contains(requirement))
        }
    }

    /// The two desktop readings are read-only and unpromoted, so they are their
    /// own Facility: a missing reading leaves a return unverified on that axis
    /// and blocks nothing else.
    @Test("the desktop readings keep their primitives out of the baseline facilities")
    func windowSpacesIsSeparate() {
        let spaces = Facility.windowSpaces
        #expect(spaces.requirements.contains(.symbol(.copySpacesForWindows)))
        #expect(spaces.requirements.contains(.symbol(.copyManagedDisplaySpaces)))
        #expect(spaces.permissions.isEmpty)
        for facility in [Facility.display, .input, .windowIdentity, .remoteWindowGeometry, .focusRecovery] {
            #expect(!facility.requirements.contains(.symbol(.copySpacesForWindows)))
            #expect(!facility.requirements.contains(.symbol(.copyManagedDisplaySpaces)))
        }
        #expect(!Facility.all.contains(spaces))
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
