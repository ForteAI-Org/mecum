//
//  SceneComposerTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
@testable import PerceptionCore
import Testing

/// Composition is pure geometry and text rules, so every rule is pinned on synthetic scenes shaped
/// like the real windows that motivated it.
@Suite("Scene composition")
struct SceneComposerTests {

    private func element(_ id: String, _ label: String, kind: ElementKind = .text,
                         x: Double, y: Double, w: Double = 0.05, h: Double = 0.015) -> SceneElement {
        SceneElement(id: id, kind: kind, label: label, bounds: NormalizedRect(x: x, y: y, width: w, height: h))
    }

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: w, height: h)
    }

    @Test("a section is named from its header and its role, and its elements are assigned")
    func namedFromHeaderAndAssigned() {
        let elements = [
            element("h", "TRACKS", x: 0.01, y: 0.14),
            element("t1", "Click 1", x: 0.02, y: 0.20),
            element("t2", "@DRUM", x: 0.02, y: 0.25),
            element("o", "Export", kind: .control, x: 0.70, y: 0.50),
        ]
        let (out, sections) = SceneComposer.compose(
            elements    : elements,
            sectionRects: [rect(0.0, 0.13, 0.10, 0.80), rect(0.10, 0.13, 0.90, 0.80)]
        )
        #expect(sections.first?.name == "sidebar (TRACKS)")
        #expect(out.first { $0.id == "t1" }?.section == "sidebar (TRACKS)")
        #expect(out.first { $0.id == "t2" }?.section == "sidebar (TRACKS)")
        #expect(out.first { $0.id == "o" }?.section != "sidebar (TRACKS)")
    }

    @Test("paragraphs coalesce only inside content sections")
    func paragraphsCoalesceInContentOnly() {
        func line(_ id: String, _ label: String, y: Double, section: String) -> SceneElement {
            SceneElement(id: id, kind: .text, label: label, bounds: rect(0.31, y, 0.3, 0.017), section: section)
        }
        let elements = [
            line("p1", "Domanda: il bounding box fornisce una confidence?", y: 0.40, section: "content (x)"),
            line("p2", "Non solo per OCR, anche per il resto", y: 0.434, section: "content (x)"),
            line("p3", "Come modulo intero", y: 0.468, section: "content (x)"),
            line("h1", "Michele 16:15", y: 0.502, section: "content (x)"),
            line("p4", "Mi servirebbe", y: 0.536, section: "content (x)"),
            line("s1", "Andrea", y: 0.40, section: "sidebar (dm)"),
            line("s2", "Eliomar", y: 0.434, section: "sidebar (dm)"),
        ]
        let labels = Set(SceneComposer.coalesceParagraphs(elements).map(\.label))
        #expect(labels.contains("Domanda: il bounding box fornisce una confidence? Non solo per OCR, anche per il resto Come modulo intero"))
        #expect(labels.contains("Michele 16:15"))
        #expect(labels.contains("Mi servirebbe"))
        #expect(labels.contains("Andrea"))
        #expect(labels.contains("Eliomar"))
    }

    @Test("author headers are recognized by shape")
    func authorHeaders() {
        #expect(SceneComposer.isAuthorHeader("Michele 16:15"))
        #expect(SceneComposer.isAuthorHeader("Ron 9.05"))
        #expect(!SceneComposer.isAuthorHeader("Mi servirebbe"))
        #expect(!SceneComposer.isAuthorHeader("Michele 16:15 today"))
        #expect(!SceneComposer.isAuthorHeader("16:15"))
    }

    @Test("role names come from geometry")
    func roleNamesFromGeometry() {
        let elements = [
            element("r", "…", x: 0.02, y: 0.5), element("s", "…", x: 0.15, y: 0.5), element("t", "…", x: 0.6, y: 0.02),
            element("c", "…", x: 0.6, y: 0.5), element("b", "…", x: 0.6, y: 0.93),
        ]
        let (_, sections) = SceneComposer.compose(
            elements    : elements,
            sectionRects: [rect(0.0, 0.0, 0.06, 1.0), rect(0.06, 0.0, 0.20, 1.0), rect(0.26, 0.0, 0.74, 0.05),
                           rect(0.26, 0.05, 0.74, 0.83), rect(0.26, 0.88, 0.74, 0.12)]
        )
        #expect(Set(sections.map(\.name)) == ["nav rail", "sidebar", "top bar", "content", "bottom bar"])
    }

    @Test("the smallest containing section wins")
    func smallestContainingSectionWins() {
        let (out, _) = SceneComposer.compose(
            elements    : [element("x", "vol", kind: .control, x: 0.30, y: 0.30)],
            sectionRects: [rect(0.0, 0.0, 1.0, 1.0), rect(0.25, 0.25, 0.2, 0.2)]
        )
        #expect(out[0].section == "region 1")
    }

    @Test("headerless sections are never named by a coordinate")
    func headerlessSectionsAreNotCoordinates() {
        let (_, sections) = SceneComposer.compose(
            elements    : [element("a", "hi", x: 0.1, y: 0.6), element("b", "yo", x: 0.6, y: 0.6)],
            sectionRects: [rect(0.0, 0.0, 0.5, 1.0), rect(0.5, 0.0, 0.5, 1.0)]
        )
        #expect(Set(sections.map(\.name)) == ["content", "content #2"])
        #expect(!sections.contains { $0.name.contains("@") || $0.name.contains("0.") })
    }

    @Test("empty sections are dropped")
    func emptySectionsAreDropped() {
        let (_, sections) = SceneComposer.compose(
            elements    : [element("a", "Hello", x: 0.1, y: 0.1)],
            sectionRects: [rect(0.0, 0.0, 0.5, 1.0), rect(0.5, 0.0, 0.5, 1.0)]
        )
        #expect(sections.count == 1)
    }

    @Test("duplicate names get ordinals")
    func duplicateNamesGetOrdinals() {
        let elements = [
            element("h1", "INSERTS", x: 0.05, y: 0.02), element("a", "plug 1", x: 0.05, y: 0.3),
            element("h2", "INSERTS", x: 0.55, y: 0.02), element("b", "plug 2", x: 0.55, y: 0.3),
        ]
        let (_, sections) = SceneComposer.compose(
            elements    : elements,
            sectionRects: [rect(0.0, 0.0, 0.5, 1.0), rect(0.5, 0.0, 0.5, 1.0)]
        )
        #expect(Set(sections.map(\.name)) == ["content (INSERTS)", "content (INSERTS) #2"])
    }

    @Test("the text rendering nests elements under their panel")
    func nestedTextRendering() {
        let elements = [element("h", "CLIPS", x: 0.86, y: 0.14), element("c1", "01_Kick.1", x: 0.87, y: 0.20)]
        let (out, sections) = SceneComposer.compose(elements: elements, sectionRects: [rect(0.85, 0.13, 0.15, 0.8)])
        let scene = SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: "W",
            viewportPixelSize: ViewportPixelSize(width: 100, height: 100),
            elements: out, sections: sections
        )
        let text = scene.text()
        #expect(text.contains("## CLIPS @"))
        #expect(text.contains("\n01_Kick.1 @87,20\n"))
    }

    @Test("the map shows a stateful unlabeled icon with a targetable id")
    func mapShowsStatefulUnlabeledIcon() {
        let elements = [
            element("h", "Destinations", x: 0.01, y: 0.02),
            SceneElement(id: "x|@8,3", kind: .icon, label: "(unlabeled)", bounds: rect(0.8, 0.3, 0.03, 0.02),
                         state: .off, isUnlabeled: true),
            SceneElement(id: "fb", kind: .control, label: "Facebook", bounds: rect(0.8, 0.2, 0.06, 0.02), state: .on),
        ]
        let (out, sections) = SceneComposer.compose(elements: elements, sectionRects: [rect(0.0, 0.0, 1.0, 1.0)])
        let scene = SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: "W",
            viewportPixelSize: ViewportPixelSize(width: 100, height: 100),
            elements: out, sections: sections
        )
        let map = scene.mapText()
        #expect(map.contains("Facebook [on]"))
        #expect(map.contains("target id 'x|@8,3'"))
        #expect(map.contains("[off]"))
    }

    @Test("no sections falls back to the flat rendering")
    func noSectionsFallsBackToFlat() {
        let scene = SceneSnapshot(
            bundleID: "com.x", appName: "X", windowTitle: "W",
            viewportPixelSize: ViewportPixelSize(width: 100, height: 100),
            elements: [element("a", "Hello", x: 0.1, y: 0.1)]
        )
        #expect(scene.text().contains("1 elements\nHello @10,10\n"))
        #expect(!scene.text().contains("▣"))
    }
}
