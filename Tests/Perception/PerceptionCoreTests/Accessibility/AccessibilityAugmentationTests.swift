//
//  AccessibilityAugmentationTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
@testable import PerceptionCore
import Testing

/// The augmentation is where accessibility meets pixels, and where a stale frame poisoned a click.
/// Every rule is pinned on a fake tree shaped like the window that taught it.
@Suite("Accessibility augmentation")
struct AccessibilityAugmentationTests {

    private let reader = FakeReader()
    private let window = CGRect(x: 100, y: 100, width: 1000, height: 800)

    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Trust

    @Test("a frame is trusted only inside the window the window server reports")
    func frameTrust() {
        // Measured 2026-09-12: the dialog at 1096,452 while its combo box still reported 2725,1661.
        let dialog = box(1096, 452, 367, 530)
        #expect(!AccessibilityFrameTrust.isTrustworthy(box(2725, 1661, 220, 24), in: dialog))
        #expect(AccessibilityFrameTrust.isTrustworthy(box(1213, 676, 220, 24), in: dialog))
        #expect(!AccessibilityFrameTrust.isTrustworthy(box(1213, 676, 0, 24), in: dialog))
        #expect(AccessibilityFrameTrust.normalized(box(2725, 1661, 220, 24), in: dialog) == nil)
        let inside = AccessibilityFrameTrust.normalized(box(600, 500, 100, 80), in: window)
        #expect(inside == NormalizedRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1))
    }

    // MARK: Harvest

    @Test("table rows are named by their deepest name, cleaned, and normalized")
    func tableRows() {
        let row1 = FakeNode("AXRow", frame: box(120, 200, 300, 24))
            .adding(FakeNode("AXCell").adding(FakeNode("AXButton", value: "Audio 13 - Audio Track ", frame: box(130, 202, 120, 20))))
        let row2 = FakeNode("AXRow", frame: box(120, 230, 300, 24))
            .adding(FakeNode("AXCell", value: "Shown. Audio 14", frame: box(130, 232, 120, 20)))
        let table = FakeNode("AXTable", frame: box(110, 190, 320, 400)).adding(row1, row2)
        let root = FakeNode("AXWindow", frame: window).adding(table)

        let out = AccessibilityAugmentation.elements(under: root, windowFrame: window, reader: reader)

        #expect(out.map(\.label) == ["Audio 13", "Audio 14"])
        #expect(out.allSatisfy { $0.kind == .control && $0.role == "AXRow" })
        #expect(out.first?.bounds == NormalizedRect(x: 0.03, y: 0.1275, width: 0.12, height: 0.025))
        #expect(out.first?.id == "control|audio13")
    }

    @Test("a row scrolled out of its container is a phantom and is not emitted")
    func offViewRowsArePhantoms() {
        let visible = FakeNode("AXRow", frame: box(120, 200, 300, 24))
            .adding(FakeNode("AXCell", value: "YouTube 1080p", frame: box(130, 202, 120, 20)))
        let phantom = FakeNode("AXRow", frame: box(120, 900, 300, 24))
            .adding(FakeNode("AXCell", value: "TikTok 1080p", frame: box(130, 902, 120, 20)))
        let list = FakeNode("AXList", frame: box(110, 190, 320, 200)).adding(visible, phantom)
        let root = FakeNode("AXWindow", frame: window).adding(FakeNode("AXScrollArea", frame: box(110, 190, 320, 200)).adding(list))

        let out = AccessibilityAugmentation.elements(under: root, windowFrame: window, reader: reader)

        #expect(out.map(\.label) == ["YouTube 1080p"])
    }

    @Test("a stale row frame outside the window is dropped, even inside its container's clip")
    func staleFramesAreDropped() {
        let row = FakeNode("AXRow", frame: box(-2000, 200, 300, 24))
            .adding(FakeNode("AXCell", value: "Audio 1", frame: box(-1990, 202, 120, 20)))
        let table = FakeNode("AXTable", frame: box(-2010, 190, 320, 400)).adding(row)
        let root = FakeNode("AXWindow", frame: window).adding(table)
        #expect(AccessibilityAugmentation.elements(under: root, windowFrame: window, reader: reader).isEmpty)
    }

    @Test("fields and pop-up buttons take a handle; checkboxes and radios carry their true state")
    func fieldsAndStatefulControls() {
        let name  = FakeNode("AXTextField", descriptionText: "Name", value: "Audio", frame: box(300, 300, 200, 24))
        let count = FakeNode("AXTextField", value: "1", frame: box(300, 340, 60, 24))
        let popup = FakeNode("AXPopUpButton", value: "Stereo", frame: box(300, 380, 120, 24))
        let check = FakeNode("AXCheckBox", title: "Use vertical resolution", numericValue: 1, frame: box(300, 420, 240, 20))
        let radio = FakeNode("AXRadioButton", title: "Square", numericValue: 0, frame: box(300, 450, 100, 20))
        let mixed = FakeNode("AXCheckBox", title: "All tracks", numericValue: 2, frame: box(300, 480, 100, 20))
        let combo = FakeNode("AXComboBox", value: "48000", frame: box(300, 510, 220, 24))
        let root = FakeNode("AXWindow", frame: window).adding(name, count, popup, check, radio, mixed, combo)

        let out = AccessibilityAugmentation.elements(under: root, windowFrame: window, reader: reader)

        #expect(out.map(\.label) == ["Name", "1", "Stereo", "Use vertical resolution", "Square", "All tracks", "48000"])
        #expect(out[3].state == .on)
        #expect(out[4].state == .off)
        #expect(out[5].state == .mixed)
        #expect(out[6].state == nil)
        #expect(out[6].role == "AXComboBox")
    }

    @Test("duplicate handles take ordinals so resolution stays unique")
    func ordinals() {
        let a = FakeNode("AXTextField", descriptionText: "Track Name", frame: box(300, 300, 200, 24))
        let b = FakeNode("AXTextField", descriptionText: "Track Name", frame: box(300, 340, 200, 24))
        let root = FakeNode("AXWindow", frame: window).adding(a, b)
        let out = AccessibilityAugmentation.elements(under: root, windowFrame: window, reader: reader)
        #expect(out.map(\.label) == ["Track Name", "Track Name #2"])
    }

    @Test("an empty multiline editor is addressable by description or identifier", arguments: [true, false])
    func emptyTextArea(namedByDescription: Bool) throws {
        let body = FakeNode(
            "AXTextArea",
            descriptionText: namedByDescription ? "First Text View" : nil,
            value          : "",
            frame          : box(120, 200, 600, 400)
        )
        body.identifier = namedByDescription ? nil : "First Text View"
        let root = FakeNode(
            "AXWindow",
            frame: window
        ).adding(body)
        let elements = AccessibilityAugmentation.elements(
            under      : root,
            windowFrame: window,
            reader     : reader
        )
        let editor = try #require(elements.first)
        #expect(elements.count == 1)
        #expect(editor.role == "AXTextArea")
        #expect(editor.label == "First Text View")
        #expect(editor.bounds == NormalizedRect(
            x     : 0.02,
            y     : 0.125,
            width : 0.6,
            height: 0.5
        ))
    }

    @Test("renderer fields below window containers stay within the bounded walk")
    func rendererFieldsBelowWindowContainers() throws {
        var subtree = FakeNode("AXTextField", descriptionText: "Probe Text",
                               frame: box(120, 200, 300, 40))
        // The measured Chrome tree puts the page's editable controls at depth ten.
        for _ in 0..<9 { subtree = FakeNode("AXGroup", frame: window).adding(subtree) }
        let root = FakeNode("AXWindow", frame: window).adding(subtree)
        let elements = AccessibilityAugmentation.elements(under: root, windowFrame: window, reader: reader)
        #expect(try #require(elements.first).label == "Probe Text")
        #expect(AccessibilityAugmentation.elements(
            under: root, windowFrame: window, reader: reader,
            limits: .init(maxDepth: 10)
        ).isEmpty)
    }

    @Test("the deadline stops the walk with what was read so far")
    func deadlineStopsTheWalk() {
        let rows = (0..<20).map { index in
            FakeNode("AXRow", frame: box(120, 200 + CGFloat(index) * 24, 300, 24))
                .adding(FakeNode("AXCell", value: "Row \(index)", frame: box(130, 202 + CGFloat(index) * 24, 120, 20)))
        }
        let table = FakeNode("AXTable", frame: box(110, 190, 320, 600))
        for row in rows { table.adding(row) }
        let root = FakeNode("AXWindow", frame: window).adding(table)
        final class Ticks: @unchecked Sendable { var count = 0 }
        let ticks = Ticks()
        let limits = AccessibilityAugmentation.Limits(isPastDeadline: { ticks.count += 1; return ticks.count > 8 })
        let out = AccessibilityAugmentation.elements(under: root, windowFrame: window, reader: reader, limits: limits)
        #expect(!out.isEmpty)
        #expect(out.count < 20)
    }

    @Test("a window with no area yields nothing")
    func degenerateWindow() {
        let root = FakeNode("AXWindow", frame: .zero).adding(FakeNode("AXCheckBox", title: "x", numericValue: 1, frame: box(0, 0, 10, 10)))
        #expect(AccessibilityAugmentation.elements(under: root, windowFrame: .zero, reader: reader).isEmpty)
    }

    // MARK: Merge

    @Test("a missed numeric display keeps its native value as read-only text")
    func aMissedNumericDisplay() throws {
        let body = box(500, 250, 230, 408)
        let display = FakeNode("AXStaticText", descriptionText: "Edit field", value: "0",
                               frame: box(701, 339, 19, 36))
        let digit = FakeNode("AXButton", descriptionText: "0", frame: box(564, 599, 48, 48))
        let root = FakeNode("AXWindow", frame: body).adding(display, digit)
        let native = AccessibilityAugmentation.elements(under: root, windowFrame: body, reader: reader)
        let value = try #require(native.first { $0.role == "AXStaticText" })
        #expect(value.kind == .text)
        #expect(value.label == "0")
        #expect(value.value == "0")
        #expect(value.state == nil)
        #expect(!AccessibilityAugmentation.interactiveRoles.contains(try #require(value.role)))
        let scene = SceneSnapshot(
            bundleID: "com.example.fixture", appName: "Fixture", windowTitle: "Fixture",
            viewportPixelSize: ViewportPixelSize(width: 230, height: 408), elements: native
        )
        guard case .found(let target) = scene.resolve(target: "0", preferNativeControls: true) else {
            Issue.record("The digit button must remain independently addressable")
            return
        }
        #expect(target.role == "AXButton")
        #expect(target.bounds != value.bounds)
    }

    @Test("read-only text cannot consume the control budget")
    func staticTextDoesNotConsumeTheControlBudget() {
        let root = FakeNode("AXWindow", frame: window)
        for index in 0..<8 {
            root.adding(FakeNode("AXStaticText", value: "\(index)", frame: box(200, 200, 40, 30)))
        }
        root.adding(FakeNode("AXButton", title: "Cancel", frame: box(600, 500, 80, 30)))
        let native = AccessibilityAugmentation.elements(
            under: root, windowFrame: window, reader: reader, limits: .init(maxElements: 2)
        )
        #expect(native.count == 2)
        #expect(native.first?.label == "Cancel")
        #expect(native.last?.role == "AXStaticText")
    }

    @Test("a static caption inside an interactive control is not another display")
    func staticControlCaptionsAreNotDisplays() {
        let button = FakeNode("AXButton", title: "0", frame: box(300, 300, 48, 48))
            .adding(FakeNode("AXStaticText", value: "0", frame: box(310, 310, 18, 24)))
        let root = FakeNode("AXWindow", frame: window).adding(button)
        let native = AccessibilityAugmentation.elements(under: root, windowFrame: window, reader: reader)
        #expect(native.count == 1)
        #expect(native.first?.role == "AXButton")
    }

    @Test("static values retain the existing window and scrolling frame guards")
    func untrustedStaticValuesAreExcluded() {
        let root = FakeNode("AXWindow", frame: window).adding(
            FakeNode("AXStaticText", value: "outside", frame: box(2000, 200, 60, 30)),
            FakeNode("AXStaticText", value: "empty frame", frame: .zero),
            FakeNode("AXStaticText", descriptionText: "Edit field", frame: box(300, 300, 60, 30)),
            FakeNode("AXScrollArea", frame: box(200, 200, 200, 100))
                .adding(FakeNode("AXStaticText", value: "clipped", frame: box(200, 450, 60, 30)))
        )
        #expect(AccessibilityAugmentation.elements(under: root, windowFrame: window, reader: reader).isEmpty)
    }

    private func pixel(_ id: String, _ label: String, kind: ElementKind = .text, x: Double, y: Double,
                       w: Double = 0.1, h: Double = 0.02, state: ControlState? = nil) -> SceneElement {
        SceneElement(id: id, kind: kind, label: label, bounds: NormalizedRect(x: x, y: y, width: w, height: h), state: state)
    }

    private func harvested(_ label: String, role: String, x: Double, y: Double, w: Double, h: Double,
                           state: ControlState? = nil) -> SceneElement {
        SceneElement(id: "control|\(LabelText.normalize(label))", kind: .control, label: label,
                     bounds: NormalizedRect(x: x, y: y, width: w, height: h), role: role, state: state)
    }

    @Test("an interactive harvest upgrades the pixel element in place and keeps its precise position")
    func interactiveUpgrade() {
        let pixels = [pixel("t", "Use vertical resolution", x: 0.32, y: 0.40, w: 0.2, h: 0.02)]
        let checkbox = harvested("Use vertical resolution", role: "AXCheckBox", x: 0.30, y: 0.39, w: 0.4, h: 0.04, state: .on)
        let merged = AccessibilityAugmentation.merge(pixels: pixels, accessibility: [checkbox])
        #expect(merged.count == 1)
        #expect(merged[0].kind == .control)
        #expect(merged[0].role == "AXCheckBox")
        #expect(merged[0].state == .on)
        #expect(merged[0].bounds == pixels[0].bounds)
    }

    @Test("a second facet of one control never overwrites the first upgrade")
    func upgradeIsFinal() {
        // Premiere's panel tab, measured live: a radio button with the state, then a combo box with
        // the same title and no state, both over the one pixel text.
        let pixels = [pixel("t", "Lumetri Scopes", x: 0.07, y: 0.06, w: 0.06, h: 0.015)]
        let radio = harvested("Lumetri Scopes", role: "AXRadioButton", x: 0.066, y: 0.047, w: 0.07, h: 0.03, state: .off)
        let combo = harvested("Lumetri Scopes #2", role: "AXComboBox", x: 0.072, y: 0.052, w: 0.06, h: 0.02)
        let merged = AccessibilityAugmentation.merge(pixels: pixels, accessibility: [radio, combo])
        #expect(merged.count == 1)
        #expect(merged[0].label == "Lumetri Scopes")
        #expect(merged[0].role == "AXRadioButton")
        #expect(merged[0].state == .off)
        // The same tab when its pixel text was garbled ("irce: (no clips)"): the radio is appended as
        // its own element, and the combo must not overwrite that either.
        let garbled = [pixel("g", "irce: (no clips)", x: 0.0, y: 0.06, w: 0.06, h: 0.015)]
        let sourceRadio = harvested("Source: (no clips)", role: "AXRadioButton", x: -0.019, y: 0.047, w: 0.07, h: 0.03, state: .off)
        let sourceCombo = harvested("Source: (no clips) #2", role: "AXComboBox", x: -0.013, y: 0.052, w: 0.06, h: 0.02)
        let appended = AccessibilityAugmentation.merge(pixels: garbled, accessibility: [sourceRadio, sourceCombo])
        #expect(appended.map(\.label) == ["irce: (no clips)", "Source: (no clips)"])
        #expect(appended[1].state == .off)
    }

    @Test("a duplicate row yields to pixels; a new row is added; pixels are never removed")
    func rowsAreAdditive() {
        let pixels = [pixel("a", "Audi 13", x: 0.05, y: 0.20), pixel("b", "Export", kind: .control, x: 0.80, y: 0.90)]
        let same = harvested("Audio 13", role: "AXRow", x: 0.03, y: 0.19, w: 0.3, h: 0.03)
        let twin = harvested("Audi 13", role: "AXRow", x: 0.03, y: 0.19, w: 0.3, h: 0.03)
        let fresh = harvested("Audio 14", role: "AXRow", x: 0.03, y: 0.23, w: 0.3, h: 0.03)
        let merged = AccessibilityAugmentation.merge(pixels: pixels, accessibility: [same, twin, fresh])
        #expect(merged.map(\.label) == ["Audi 13", "Export", "Audio 13", "Audio 14"])
    }

    @Test("an ordinal does not defeat the core match")
    func ordinalsCoreMatch() {
        let pixels = [pixel("t", "Track Name", x: 0.32, y: 0.40)]
        let field = harvested("Track Name #2", role: "AXTextField", x: 0.30, y: 0.39, w: 0.2, h: 0.04)
        let merged = AccessibilityAugmentation.merge(pixels: pixels, accessibility: [field])
        #expect(merged.count == 1)
        #expect(merged[0].label == "Track Name #2")
        #expect(AccessibilityAugmentation.strippingOrdinal("Track Name #2") == "Track Name")
        #expect(AccessibilityAugmentation.strippingOrdinal("Room #") == "Room #")
    }

    @Test("labels are cleaned of toolkit suffixes and prefixes")
    func cleanLabels() {
        #expect(AccessibilityAugmentation.cleanLabel("Audio 13 - Audio Track ") == "Audio 13")
        #expect(AccessibilityAugmentation.cleanLabel("Shown. Audio 13") == "Audio 13")
        #expect(AccessibilityAugmentation.cleanLabel("Hidden. Bus 2") == "Bus 2")
        #expect(AccessibilityAugmentation.cleanLabel(" Plain ") == "Plain")
        #expect(AccessibilityAugmentation.cleanLabel("Drums - Room") == "Drums - Room")
        #expect(AccessibilityAugmentation.cleanLabel("Drums - Room - Audio Track ") == "Drums - Room")
    }
}
