//
//  VirtualDisplayConfigurationTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import PrivateSymbols
import Testing
@testable import VirtualScreens

@Suite("What a Seat Host may ask a virtual display for")
struct VirtualDisplayConfigurationTests {

    @Test("the default is 2560 by 1440 at 60 Hz")
    func defaults() {
        let configuration = VirtualDisplayConfiguration()

        #expect(configuration.pixelSize == CGSize(width: 2560, height: 1440))
        #expect(configuration.refreshRate == .standard)
        #expect(configuration.refreshRate.rawValue == 60)
    }

    @Test("60 and 120 are the only refresh rates that exist")
    func refreshRates() {
        // The spec admits exactly these two, so the type admits exactly these
        // two: a runtime rejection of 75 would say the same thing later, in a
        // place the caller cannot see from the signature.
        #expect(RefreshRate.allCases.map(\.rawValue) == [60, 120])
        #expect(RefreshRate(rawValue: 75) == nil)
    }

    @Test("the identity triple is fixed, so macOS remembers one monitor and not many")
    func stableIdentity() {
        #expect(VirtualDisplayConfiguration.vendorID  == 0xF0A7)
        #expect(VirtualDisplayConfiguration.productID == 0xA617)
        #expect(VirtualDisplayConfiguration.serial    == 0xA617_0001)
    }

    @Test("the surface needs the four private classes, their three selectors and objc_msgSend")
    func surfacePrimitives() {
        #expect(VirtualDisplay.surfacePrimitives.count == 8)
        // Every one of them is also a requirement of the whole Facility, so a
        // surface that resolves cannot be built on a primitive the gate never
        // heard of.
        #expect(VirtualDisplay.surfacePrimitives.allSatisfy(Facility.display.requirements.contains))
        // Accessibility belongs to the relocator, not to the surface: creating
        // a display must not report the wrong missing thing.
        #expect(!VirtualDisplay.surfacePrimitives.contains(.symbol(.axUIElementGetWindow)))
    }
}
