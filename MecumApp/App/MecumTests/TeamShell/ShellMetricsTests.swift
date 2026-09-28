//
//  ShellMetricsTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Testing
@testable import Mecum

@Suite("The team window's widths and how space is divided")
struct ShellMetricsTests {

    private typealias Division = ShellMetrics.Division

    private static let full    = Division(isInspectorShown: true, isSidebarCompact: false)
    private static let compact = Division(isInspectorShown: true, isSidebarCompact: true)
    private static let closed  = Division.withoutInspector

    @Test("Each column starts inside its own range, and the ranges are the spec's tokens")
    func theColumnTokensAreConsistent() {
        for column in [ShellMetrics.sidebar, ShellMetrics.inspector] {
            #expect(column.minimum <= column.ideal && column.ideal <= column.maximum)
        }
        #expect(ShellMetrics.sidebar   == ColumnWidth(ideal: 280, minimum: 200, maximum: 340))
        #expect(ShellMetrics.inspector == ColumnWidth(ideal: 360, minimum: 320, maximum: 440))
        #expect(ShellMetrics.compactSidebar == 140)
        #expect(ShellMetrics.compactSidebar < ShellMetrics.sidebar.minimum)
    }

    @Test("A sidebar narrower than the full rows read shows the compact tiles")
    func aNarrowSidebarShowsTiles() {
        #expect(ShellMetrics.showsCompactTiles(sidebarWidth: ShellMetrics.compactSidebar))
        #expect(ShellMetrics.showsCompactTiles(sidebarWidth: 199))
        #expect(!ShellMetrics.showsCompactTiles(sidebarWidth: 200))
        #expect(!ShellMetrics.showsCompactTiles(sidebarWidth: ShellMetrics.sidebar.ideal))
    }

    @Test("When the three areas do not fit, the sidebar turns compact before the inspector closes")
    func theSidebarGivesWayFirst() {
        // 1100 = 280 + 360 + 460: all three fit exactly; one point less needs the compact sidebar.
        #expect(ShellMetrics.division(window: 1100, previous: nil) == Self.full)
        #expect(ShellMetrics.division(window: 1099, previous: nil) == Self.compact)
        // 960 = 140 + 360 + 460: the inspector still fits beside the compact sidebar; one point less does not.
        #expect(ShellMetrics.division(window: 960, previous: nil) == Self.compact)
        #expect(ShellMetrics.division(window: 959, previous: nil) == Self.closed)
    }

    @Test("A resize across either line changes the division once and restores it only with room to spare")
    func aResizeAcrossALineDoesNotFlipTwice() {
        let divide = ShellMetrics.division
        // Full: stays down to the line, turns compact below it.
        #expect(divide(1100, Self.full) == Self.full)
        #expect(divide(1099, Self.full) == Self.compact)
        // Compact: a few points past the line are not enough to bring the full sidebar back.
        #expect(divide(1101, Self.compact) == Self.compact)
        #expect(divide(1123, Self.compact) == Self.compact)
        #expect(divide(1124, Self.compact) == Self.full)
        // Closed below the compact line: it opens again only with room to spare.
        #expect(divide(959, Self.compact) == Self.closed)
        #expect(divide(961, Self.closed) == Self.closed)
        #expect(divide(984, Self.closed) == Self.compact)
        // Walk a jittering resize across the full line and count the flips: one each way.
        var division = Self.full
        var flips    = 0
        for width in [1110.0, 1099, 1101, 1098, 1105, 1110, 1130, 1120, 1101] {
            let next = divide(width, division)
            if next != division { flips += 1 }
            division = next
        }
        #expect(flips == 2)
        #expect(division == Self.full)
    }

    @Test("The window's minimum lets the inspector open beside the compact sidebar")
    func theWindowMinimumAlwaysAdmitsTheInspector() {
        #expect(ShellMetrics.windowMinimum == 960)
        #expect(ShellMetrics.division(window: ShellMetrics.windowMinimum, previous: nil) == Self.compact)
        #expect(ShellMetrics.windowMinimum - ShellMetrics.sidebar.ideal >= ShellMetrics.conversationMinimum)
    }
}
