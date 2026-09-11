//
//  PhysicalCursorRegionTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
@testable import SeatCore
import Testing

/// The invariant under test: the person keeps every pixel of their own displays
/// and never reaches the virtual one. Synthetic geometry only, no tap installed
/// and no cursor moved.
@Suite("Physical cursor region")
struct PhysicalCursorRegionTests {

    static let display = CGRect(x: 0, y: 0, width: 1823, height: 1049)
    static let second  = CGRect(x: -1600, y: 0, width: 1600, height: 900)

    static var region: PhysicalCursorRegion {
        guard let region = PhysicalCursorRegion(displayBounds: [display]) else {
            fatalError("a valid display must produce a region")
        }
        return region
    }

    static var dual: PhysicalCursorRegion {
        guard let region = PhysicalCursorRegion(displayBounds: [display, second]) else {
            fatalError("two valid displays must produce a region")
        }
        return region
    }

    @Test("the physical border stays reachable", arguments: [
        CGPoint(x: 0, y: 500), CGPoint(x: 1822.75, y: 500),
        CGPoint(x: 900, y: 0), CGPoint(x: 900, y: 1048.75)
    ])
    func borderReachable(_ point: CGPoint) {
        #expect(Self.region.nearestPoint(to: point) == point)
    }

    @Test("a point outside is confined", arguments: [
        CGPoint(x: 1823, y: 1048), CGPoint(x: 1824, y: 1048),
        CGPoint(x: 2500, y: 1500), CGPoint(x: -50, y: 200)
    ])
    func outsidePointConfined(_ point: CGPoint) {
        let region = Self.region
        #expect(!region.contains(point))
        #expect(region.contains(region.nearestPoint(to: point)))
    }

    @Test("crossing between physical displays leaves no dead band")
    func noDeadBandBetweenDisplays() {
        #expect(Self.dual.nearestPoint(to: CGPoint(x: -0.25, y: 500)) == CGPoint(x: -0.25, y: 500))
    }

    @Test("the gap between displays is excluded")
    func gapExcluded() {
        #expect(!Self.dual.contains(CGPoint(x: -400, y: 1000)))
    }

    @Test("invalid displays are refused")
    func invalidDisplaysRefused() {
        #expect(PhysicalCursorRegion(displayBounds: [.zero, .null, .infinite]) == nil)
    }

    @Test("non finite coordinates are confined")
    func nonFiniteConfined() {
        let region = Self.region
        #expect(region.contains(region.nearestPoint(to: CGPoint(x: CGFloat.nan, y: 0))))
    }

    @Test("an extended grid stays inside the physical union")
    func extendedGridStaysInside() {
        let dual = Self.dual
        for x in stride(from: -2000, through: 4000, by: 71) {
            for y in stride(from: -2000, through: 4000, by: 97) {
                #expect(dual.contains(dual.nearestPoint(to: CGPoint(x: x, y: y))))
            }
        }
    }
}
