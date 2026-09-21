import XCTest
@testable import LocatorCore

final class SceneComposerTests: XCTestCase {
    private func el(_ id: String, _ label: String, kind: String = "text",
                    x: Double, y: Double, w: Double = 0.05, h: Double = 0.015) -> SceneElement {
        SceneElement(id: id, kind: kind, label: label, pos: [x, y, w, h])
    }

    func testSectionNamedFromHeaderAndElementsAssigned() {
        let elements = [
            el("h", "TRACKS", x: 0.01, y: 0.14),                       // header in the sidebar's top band
            el("t1", "Click 1", x: 0.02, y: 0.20),
            el("t2", "@DRUM", x: 0.02, y: 0.25),
            el("o", "Export", kind: "control", x: 0.70, y: 0.50),      // lives in the other section
        ]
        let (out, sections) = SceneComposer.compose(
            elements: elements,
            sectionRects: [[0.0, 0.13, 0.10, 0.80], [0.10, 0.13, 0.90, 0.80]])
        // Sections v2: a narrow left column earns its geometric ROLE as prefix, header kept as suffix —
        // the model reads "sidebar (TRACKS)" and both words match how a human would point at it.
        XCTAssertEqual(sections.first?.name, "sidebar (TRACKS)")
        XCTAssertEqual(out.first { $0.id == "t1" }?.section, "sidebar (TRACKS)")
        XCTAssertEqual(out.first { $0.id == "t2" }?.section, "sidebar (TRACKS)")
        XCTAssertNotEqual(out.first { $0.id == "o" }?.section, "sidebar (TRACKS)")
    }

    func testParagraphsCoalesceOnlyInContentSections() {
        // Geometry from the live Slack measurement: paragraph gaps 1.0–1.35×h; sidebar row gaps ~1.2×h
        // are IDENTICAL, so the section role is the only safe discriminator.
        func line(_ id: String, _ label: String, y: Double, section: String) -> SceneElement {
            var e = SceneElement(id: id, kind: "text", label: label, pos: [0.31, y, 0.3, 0.017])
            e.section = section
            return e
        }
        let els = [
            line("p1", "Domanda: il bounding box fornisce una confidence?", y: 0.40, section: "content (x)"),
            line("p2", "Non solo per OCR, anche per il resto", y: 0.434, section: "content (x)"),   // gap 1.0×h
            line("p3", "Come modulo intero", y: 0.468, section: "content (x)"),
            line("h1", "Michele 16:15", y: 0.502, section: "content (x)"),                          // header breaks
            line("p4", "Mi servirebbe", y: 0.536, section: "content (x)"),
            line("s1", "Andrea", y: 0.40, section: "sidebar (dm)"),                                 // same gaps,
            line("s2", "Eliomar", y: 0.434, section: "sidebar (dm)"),                               // NEVER merge
        ]
        let out = SceneComposer.coalesceParagraphs(els)
        let labels = Set(out.map(\.label))
        XCTAssertTrue(labels.contains("Domanda: il bounding box fornisce una confidence? Non solo per OCR, anche per il resto Come modulo intero"))
        XCTAssertTrue(labels.contains("Michele 16:15"))     // author header untouched
        XCTAssertTrue(labels.contains("Mi servirebbe"))     // single line after the header stays single
        XCTAssertTrue(labels.contains("Andrea"))            // sidebar rows never coalesce
        XCTAssertTrue(labels.contains("Eliomar"))
    }

    func testRoleNamesFromGeometry() {
        // The Slack fixture shapes, synthesized: rail sliver, sidebar column, top strip, content band,
        // bottom strip. Headerless → pure role names.
        let elements = [
            el("r", "…", x: 0.02, y: 0.5), el("s", "…", x: 0.15, y: 0.5), el("t", "…", x: 0.6, y: 0.02),
            el("c", "…", x: 0.6, y: 0.5), el("b", "…", x: 0.6, y: 0.93),
        ]
        let (_, sections) = SceneComposer.compose(
            elements: elements,
            sectionRects: [[0.0, 0.0, 0.06, 1.0], [0.06, 0.0, 0.20, 1.0], [0.26, 0.0, 0.74, 0.05],
                           [0.26, 0.05, 0.74, 0.83], [0.26, 0.88, 0.74, 0.12]])
        XCTAssertEqual(Set(sections.map(\.name)),
                       ["nav rail", "sidebar", "top bar", "content", "bottom bar"])
    }

    func testSmallestContainingSectionWins() {   // sections can nest — file under the innermost
        let elements = [el("x", "vol", kind: "control", x: 0.30, y: 0.30)]
        let (out, _) = SceneComposer.compose(
            elements: elements,
            sectionRects: [[0.0, 0.0, 1.0, 1.0], [0.25, 0.25, 0.2, 0.2]])
        XCTAssertEqual(out[0].section, "region 1")   // inner panel is the only role-less section (the full-window rect is role-named "content")
    }

    func testHeaderlessSectionsAreRegionNNotCoordinates() {
        // Regression: a coordinate-looking name ("section@0.50,0.20") leaked to the LLM which then
        // tried to reach() it — confusing miss. Headerless sections must read as plain "region N".
        // elements BELOW the top band → the sections have no header → "region N"
        let elements = [el("a", "hi", x: 0.1, y: 0.6), el("b", "yo", x: 0.6, y: 0.6)]
        let (_, sections) = SceneComposer.compose(
            elements: elements,
            sectionRects: [[0.0, 0.0, 0.5, 1.0], [0.5, 0.0, 0.5, 1.0]])
        // Half-window columns legitimately earn the "content" role now; the regression under guard is
        // COORDINATE-LOOKING names, whatever the naming scheme.
        XCTAssertEqual(Set(sections.map(\.name)), ["content", "content #2"])
        XCTAssertFalse(sections.contains { $0.name.contains("@") || $0.name.contains("0.") })
    }

    func testEmptySectionsAreDropped() {
        let (_, sections) = SceneComposer.compose(
            elements: [el("a", "Hello", x: 0.1, y: 0.1)],
            sectionRects: [[0.0, 0.0, 0.5, 1.0], [0.5, 0.0, 0.5, 1.0]])   // right half holds nothing
        XCTAssertEqual(sections.count, 1)
    }

    func testDuplicateNamesGetOrdinals() {
        let elements = [
            el("h1", "INSERTS", x: 0.05, y: 0.02), el("a", "plug 1", x: 0.05, y: 0.3),
            el("h2", "INSERTS", x: 0.55, y: 0.02), el("b", "plug 2", x: 0.55, y: 0.3),
        ]
        let (_, sections) = SceneComposer.compose(
            elements: elements,
            sectionRects: [[0.0, 0.0, 0.5, 1.0], [0.5, 0.0, 0.5, 1.0]])
        XCTAssertEqual(Set(sections.map(\.name)), ["content (INSERTS)", "content (INSERTS) #2"])
    }

    func testNestedTextRendering() {
        let elements = [el("h", "CLIPS", x: 0.86, y: 0.14),
                        el("c1", "01_Kick.1", x: 0.87, y: 0.20)]
        let (out, sections) = SceneComposer.compose(elements: elements, sectionRects: [[0.85, 0.13, 0.15, 0.8]])
        let scene = SceneSnapshot(bundleID: "com.x", app: "X", windowTitle: "W", viewportPx: [100, 100],
                                  elements: out, sections: sections, commands: [])
        let t = scene.text()
        XCTAssertTrue(t.contains("▣ CLIPS"))
        XCTAssertTrue(t.contains("    [text] 01_Kick.1"))     // nested under the panel, indented
        XCTAssertTrue(t.contains("in 1 sections"))
    }

    func testMapShowsStatefulUnlabeledIconWithTargetableId() {
        // An unlabeled icon that carries STATE (a logo-only toggle like Premiere's "X" export row) must
        // appear in the map — with its id — not be hidden by the unlabeled filter.
        let elements = [
            el("h", "Destinations", x: 0.01, y: 0.02),
            SceneElement(id: "x|@8,3", kind: "icon", label: "(unlabeled)", pos: [0.8, 0.3, 0.03, 0.02], state: "off", unlabeled: true),
            SceneElement(id: "fb", kind: "control", label: "Facebook", pos: [0.8, 0.2, 0.06, 0.02], state: "on"),
        ]
        let (out, sections) = SceneComposer.compose(elements: elements, sectionRects: [[0.0, 0.0, 1.0, 1.0]])
        let scene = SceneSnapshot(bundleID: "com.x", app: "X", windowTitle: "W", viewportPx: [100, 100],
                                  elements: out, sections: sections, commands: [])
        let m = scene.mapText()
        XCTAssertTrue(m.contains("Facebook [on]"))
        XCTAssertTrue(m.contains("target id 'x|@8,3'"))   // the stateful unlabeled toggle is surfaced + targetable
        XCTAssertTrue(m.contains("[off]"))
    }

    func testNoSectionsFallsBackToFlatRendering() {
        let scene = SceneSnapshot(bundleID: "com.x", app: "X", windowTitle: "W", viewportPx: [100, 100],
                                  elements: [el("a", "Hello", x: 0.1, y: 0.1)], commands: [])
        XCTAssertTrue(scene.text().contains("elements (1):"))
        XCTAssertFalse(scene.text().contains("▣"))
    }
}
