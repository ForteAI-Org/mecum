//
//  AccessibilityHarvestTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import CoreGraphics
import Foundation
@testable import PerceptionCore
import Testing

/// The harvest beside the elements: where each label came from, where a collection ends, and what
/// the walk can say about its own completeness. Every rule is pinned on a fake tree.
@Suite("Accessibility harvest: label origin, collection path and capture quality")
struct AccessibilityHarvestTests {

    private let reader = FakeReader()
    private let window = CGRect(x: 100, y: 100, width: 1000, height: 800)

    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private func peopleTable(named name: String? = "People") -> FakeNode {
        let table = FakeNode("AXTable", title: name, frame: box(110, 190, 500, 400))
        for (index, person) in ["Alice", "Bruno"].enumerated() {
            let y = 200 + CGFloat(index) * 30
            table.adding(FakeNode("AXRow", value: person, frame: box(120, y, 480, 26)).adding(
                FakeNode("AXCell", frame: box(500, y, 90, 26)).adding(
                    FakeNode("AXGroup", title: "Ops", frame: box(500, y, 90, 26)).adding(
                        FakeNode("AXButton", title: "Reply", frame: box(505, y + 2, 80, 20))
                    )
                )
            ))
        }
        return table
    }

    @Test("every label says which attribute it came from, and a pixel element says none")
    func labelOrigins() {
        let root = FakeNode("AXWindow", frame: window).adding(
            FakeNode("AXButton", title: "Save", frame: box(700, 700, 100, 24)),
            FakeNode("AXCheckBox", descriptionText: "Track changes", numericValue: 1, frame: box(700, 650, 120, 20)),
            FakeNode("AXButton", value: "7", frame: box(700, 600, 40, 24)),
            FakeNode("AXTextField", value: "Mario", frame: box(700, 550, 200, 22)),
            FakeNode("AXTextField", descriptionText: "Name", value: "Mario", frame: box(700, 500, 200, 22)),
            peopleTable()
        )
        let out = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: reader)
        let origins = Dictionary(out.elements.map { ($0.label, $0.labelOrigin) }, uniquingKeysWith: { first, _ in first })
        #expect(origins["Save"] == .title)
        #expect(origins["Track changes"] == .description)
        #expect(origins["7"] == .value)
        #expect(origins["Mario"] == .value)
        #expect(origins["Name"] == .description)
        #expect(origins["Alice"] == .rowContent)
        #expect(origins["Reply"] == .title)
        #expect(out.elements.allSatisfy { $0.labelOrigin != nil })
        let pixel = SceneElement(id: "text|hello", kind: .text, label: "hello", bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.02))
        #expect(pixel.labelOrigin == nil)
    }

    @Test("a column header labels the cell's control with the column origin")
    func columnOrigin() {
        let table = FakeNode("AXTable", title: "Tracks", frame: box(110, 190, 500, 400)).adding(
            FakeNode("AXColumn", title: "Name"), FakeNode("AXColumn", title: "Mute"),
            FakeNode("AXRow", value: "Audio 1", frame: box(120, 200, 480, 26)).adding(
                FakeNode("AXCell", frame: box(120, 200, 300, 26)),
                FakeNode("AXCell", frame: box(420, 200, 60, 26)).adding(
                    FakeNode("AXCheckBox", numericValue: 0, frame: box(425, 202, 20, 20))
                )
            )
        )
        let root = FakeNode("AXWindow", frame: window).adding(table)
        let out = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: reader)
        let mute = out.elements.first { $0.role == "AXCheckBox" }
        #expect(mute?.label == "Mute")
        #expect(mute?.labelOrigin == .column)
        #expect(mute?.collectionPath == "Tracks")
    }

    @Test("a row and everything inside it carry the path up to the collection, while the container a model addresses keeps the row's name")
    func collectionPath() {
        let root = FakeNode("AXWindow", frame: window).adding(
            FakeNode("AXGroup", title: "Inbox", frame: box(105, 150, 600, 500)).adding(peopleTable()),
            FakeNode("AXButton", title: "Compose", frame: box(700, 700, 100, 24))
        )
        let out = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: reader)
        let alice = out.elements.first { $0.label == "Alice" }
        let reply = out.elements.first { $0.label == "Reply" }
        let compose = out.elements.first { $0.label == "Compose" }
        #expect(alice?.collectionPath == "Inbox / People")
        #expect(alice?.container == "Inbox / People")
        #expect(reply?.collectionPath == "Inbox / People", "a titled group inside the row does not extend the structural path")
        #expect(reply?.container == "Inbox / People / Alice / Ops")
        #expect(compose?.collectionPath == nil)
        #expect(compose?.container == nil)
        #expect(out.elements.filter { $0.label.hasPrefix("Reply") }.count == 2, "two reply buttons, addressed through two rows")
    }

    @Test("an untitled collection is named by its role in the structural path, never by a row")
    func untitledCollection() {
        let root = FakeNode("AXWindow", frame: window).adding(
            FakeNode("AXGroup", title: "Sidebar", frame: box(105, 150, 600, 500)).adding(peopleTable(named: nil))
        )
        let out = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: reader)
        #expect(Set(out.elements.compactMap(\.collectionPath)) == ["Sidebar / AXTable"])
        #expect(out.elements.first { $0.label == "Alice" }?.container == "Sidebar")
    }

    @Test("a finished walk is complete with its counts and the window's role and subrole; an empty harvest is still a measured walk")
    func completeWalk() {
        let root = FakeNode("AXWindow", subrole: "AXDialog", title: "Save?", frame: window).adding(
            FakeNode("AXButton", title: "Cancel", frame: box(500, 700, 100, 24)),
            FakeNode("AXButton", title: "Save", frame: box(700, 700, 100, 24))
        )
        let out = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: reader)
        #expect(out.quality.completeness == .complete)
        #expect(out.quality.walkCompleted == true)
        #expect(out.quality.stoppedBy == nil)
        #expect(out.quality.windowFound == true)
        #expect(out.quality.isGrantAvailable == nil, "the walk does not know the grant; the live augmenter does")
        #expect(out.quality.windowRole == "AXWindow")
        #expect(out.quality.windowSubrole == "AXDialog")
        #expect(out.quality.nodesVisited == 3)
        #expect(out.quality.elementsEmitted == 2)
        let empty = AccessibilityAugmentation.harvest(
            under: FakeNode("AXWindow", frame: window).adding(FakeNode("AXStaticText", value: "0", frame: box(200, 200, 50, 20))),
            windowFrame: window, reader: reader
        )
        #expect(empty.elements.isEmpty)
        #expect(empty.quality.completeness == .complete, "completeness is measured, never inferred from an empty list")
        #expect(empty.quality.elementsEmitted == 0)
        #expect(AccessibilityAugmentation.elements(under: root, windowFrame: window, reader: reader) == out.elements)
    }

    @Test("the deadline, the element budget, the table budget and the depth budget each leave the walk partial with their reason")
    func truncation() {
        let root = FakeNode("AXWindow", frame: window).adding(
            FakeNode("AXButton", title: "Compose", frame: box(700, 700, 100, 24)),
            peopleTable(),
            peopleTable(named: "Groups")
        )
        let asked = Counter()
        let deadline = AccessibilityAugmentation.harvest(
            under: root, windowFrame: window, reader: reader,
            limits: .init(isPastDeadline: { asked.increment() > 2 })
        )
        #expect(deadline.quality.completeness == .partial)
        #expect(deadline.quality.stoppedBy == .deadline)
        #expect(deadline.quality.walkCompleted == false)
        #expect(deadline.elements.count < 9)
        let elements = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: reader, limits: .init(maxElements: 3))
        #expect(elements.quality.stoppedBy == .elementLimit)
        #expect(elements.elements.count == 3)
        let tables = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: reader, limits: .init(maxTables: 1))
        #expect(tables.quality.stoppedBy == .tableLimit)
        #expect(tables.quality.completeness == .partial)
        let depth = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: reader, limits: .init(maxDepth: 2))
        #expect(depth.quality.stoppedBy == .depthLimit)
        #expect(depth.elements.map(\.label).contains("Compose"))
        let whole = AccessibilityAugmentation.harvest(under: root, windowFrame: window, reader: reader)
        #expect(whole.quality.completeness == .complete)
        #expect(whole.elements.count == 9, "a button, two tables of two rows, each row with its reply button")
    }

    @Test("a degenerate window frame reads nothing: not a complete read and not a denied grant")
    func degenerateFrame() {
        let root = FakeNode("AXWindow", subrole: "AXStandardWindow", frame: window).adding(
            FakeNode("AXButton", title: "OK", frame: box(700, 700, 100, 24))
        )
        let out = AccessibilityAugmentation.harvest(under: root, windowFrame: .zero, reader: reader)
        #expect(out.elements.isEmpty)
        #expect(out.quality.completeness == .failed)
        #expect(out.quality.windowFound == false)
        #expect(out.quality.isGrantAvailable == nil)
        #expect(out.quality.windowSubrole == "AXStandardWindow")
    }

    @Test("the merge keeps the harvest's facts: an upgrade takes label and origin, a matched row lends its collection path and no origin")
    func mergeKeepsFacts() {
        let pixelRow = SceneElement(id: "text|alice", kind: .text, label: "Alice", bounds: NormalizedRect(x: 0.02, y: 0.125, width: 0.3, height: 0.03))
        let pixelBox = SceneElement(id: "text|track", kind: .text, label: "Track", bounds: NormalizedRect(x: 0.6, y: 0.7, width: 0.1, height: 0.03))
        let row = SceneElement(id: "control|alice", kind: .control, label: "Alice", bounds: NormalizedRect(x: 0.02, y: 0.125, width: 0.3, height: 0.03),
                               role: "AXRow", container: "People", labelOrigin: .rowContent, collectionPath: "People")
        let checkbox = SceneElement(id: "control|track", kind: .control, label: "Track", bounds: NormalizedRect(x: 0.6, y: 0.7, width: 0.1, height: 0.03),
                                    role: "AXCheckBox", state: .on, labelOrigin: .title)
        let merged = AccessibilityAugmentation.merge(pixels: [pixelRow, pixelBox], accessibility: [row, checkbox])
        #expect(merged.count == 2)
        #expect(merged[0].labelOrigin == nil, "the pixel label stayed, so it has no accessibility origin")
        #expect(merged[0].collectionPath == "People")
        #expect(merged[0].role == nil)
        #expect(merged[1].labelOrigin == .title)
        #expect(merged[1].role == "AXCheckBox")
        #expect(merged[1].state == .on)
    }

    @Test("the two memory facts are not on the wire and not in equality: an element encodes, compares and hashes the same with and without them")
    func wireFormatUnchanged() throws {
        let bounds = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)
        let plain = SceneElement(id: "control|reply", kind: .control, label: "Reply", bounds: bounds, role: "AXButton", container: "People / Alice")
        let annotated = SceneElement(id: "control|reply", kind: .control, label: "Reply", bounds: bounds, role: "AXButton",
                                     container: "People / Alice", labelOrigin: .title, collectionPath: "People")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(plain) == encoder.encode(annotated))
        let decoded = try JSONDecoder().decode(SceneElement.self, from: encoder.encode(annotated))
        #expect(decoded == plain)
        #expect(decoded.labelOrigin == nil)
        #expect(annotated == plain, "the facts are about the read, not the scene: equality and hashing leave them out")
        #expect(annotated.hashValue == plain.hashValue)
        #expect(annotated.labelOrigin == .title && annotated.collectionPath == "People")
        #expect(SceneToken(bundleID: "x", windowTitle: "W", elements: [plain]) == SceneToken(bundleID: "x", windowTitle: "W", elements: [annotated]))
    }
}

/// A thread-safe counter for a deadline closure the walk asks before every node.
private final class Counter: @unchecked Sendable {

    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
