//
//  MarkerTableTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
@testable import CursorGuard
import Testing

/// The table that stands in for a `Dictionary` of anchors. The property under
/// test is behaviour, not speed: the benchmark proves it does not allocate,
/// these prove it answers exactly as a dictionary would.
@Suite("Marker table")
struct MarkerTableTests {

    @Test("a marker maps to its value, and an unknown one to nothing")
    func lookup() {
        var table = MarkerTable<CGPoint>()
        table.insert(CGPoint(x: 10, y: 20), for: 42)

        #expect(table.value(for: 42) == CGPoint(x: 10, y: 20))
        #expect(table.value(for: 7)  == nil)
        #expect(table.count == 1)
        #expect(!table.isEmpty)
    }

    @Test("inserting the same marker twice refreshes it instead of duplicating")
    func insertIsIdempotent() {
        var table = MarkerTable<CGPoint>()
        table.insert(CGPoint(x: 1, y: 1), for: 42)
        table.insert(CGPoint(x: 2, y: 2), for: 42)

        #expect(table.count == 1)
        #expect(table.value(for: 42) == CGPoint(x: 2, y: 2))
    }

    @Test("removing gives back the value, and removing again gives nothing")
    func remove() {
        var table = MarkerTable<CGPoint>()
        table.insert(CGPoint(x: 3, y: 4), for: 9)

        #expect(table.remove(9) == CGPoint(x: 3, y: 4))
        #expect(table.remove(9) == nil)
        #expect(table.isEmpty)
    }

    @Test("setAll rewrites every entry, which is what the anchors need")
    func setAll() {
        var table = MarkerTable<CGPoint>()
        table.insert(CGPoint(x: 1, y: 1), for: 1)
        table.insert(CGPoint(x: 2, y: 2), for: 2)
        table.setAll(CGPoint(x: 9, y: 9))

        #expect(table.value(for: 1) == CGPoint(x: 9, y: 9))
        #expect(table.value(for: 2) == CGPoint(x: 9, y: 9))
    }

    @Test("removeAll empties the table and keeps its buffer")
    func removeAll() {
        var table = MarkerTable<CGPoint>()
        table.insert(.zero, for: 1)
        table.removeAll()

        #expect(table.isEmpty)
        #expect(table.entries.capacity >= MarkerTable<CGPoint>.reservedCapacity)
    }
}
