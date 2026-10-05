//
//  CaptureSampleContentTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
@testable import Memory
import PerceptionCore
import Testing

/// A sample's content is compared as the file keeps it: every text byte for byte, NULL apart from
/// empty text, every other field typed and in order, a bound as the number it is.
@Suite("A capture sample's content is its bytes")
struct CaptureSampleContentTests {

    static func element(_ label: String = "Send", role: String = "AXButton", path: String = "AXWindow/AXGroup",
                        x: Double = 0.5) -> CaptureElement {
        CaptureElement(kind: .control, role: role, label: label, labelOrigin: .title, containerPath: path,
                       isUnderCollection: false, state: nil, bounds: NormalizedRect(x: x, y: 0.1, width: 0.03, height: 0.017))
    }

    static func sample(title: String? = "Inbox", elements: [CaptureElement] = [element(), element("Draft", x: 0.6)],
                       quality: CaptureQuality = CaptureQuality(walkCompleted: true, stoppedBy: nil, windowFound: true, isGrantAvailable: true,
                                                                windowRole: "AXWindow", windowSubrole: "AXStandardWindow",
                                                                nodesVisited: 12, elementsEmitted: 2)) -> CaptureSample {
        CaptureSample(key: CaptureSampleKey(eventID: "e1", phase: .after), windowTitle: title, sessionRevision: 3,
                      surface: .window, quality: quality, elements: elements)
    }

    static func quality(role: String = "AXWindow", subrole: String = "AXStandardWindow") -> CaptureQuality {
        CaptureQuality(walkCompleted: true, stoppedBy: nil, windowFound: true, isGrantAvailable: true, windowRole: role,
                       windowSubrole: subrole, nodesVisited: 12, elementsEmitted: 2)
    }

    @Test("elements whose texts are canonically equivalent but different bytes are two elements, in a set and a dictionary; built again from the same bytes they are one; −0.0 and +0.0 are one bound")
    func elementsAreBytes() {
        let composed = "café", decomposed = "cafe\u{301}"
        let variants = [Self.element(composed), Self.element(decomposed), Self.element(role: "AX\(composed)"), Self.element(role: "AX\(decomposed)"),
                        Self.element(path: composed), Self.element(path: decomposed)]
        for (i, lhs) in variants.enumerated() {
            for (j, rhs) in variants.enumerated() { #expect((lhs == rhs) == (i == j), Comment(rawValue: "\(i) against \(j)")) }
        }
        #expect(Set(variants).count == 6)
        #expect(Set(variants + [Self.element("caf" + "é"), Self.element(path: "cafe" + "\u{301}")]).count == 6)
        var indexed: [CaptureElement: Int] = [:]
        for (index, element) in variants.enumerated() { indexed[element] = index }
        #expect(indexed.count == 6 && indexed[Self.element(decomposed)] == 1)
        #expect(Self.element(x: -0.0) == Self.element(x: 0.0) && Set([Self.element(x: -0.0), Self.element(x: 0.0)]).count == 1)
    }

    @Test("a sample's every persisted text is compared byte for byte, NULL apart from empty, and every other field typed and in order")
    func samplesAreBytes() {
        let base = Self.sample(title: "café", elements: [Self.element("café", role: "AXcafé", path: "café")], quality: Self.quality(role: "café", subrole: "café"))
        let decomposed = "cafe\u{301}"
        let variants: [(String, CaptureSample)] = [
            ("windowTitle", Self.sample(title: decomposed, elements: base.elements, quality: base.quality)),
            ("label", Self.sample(title: "café", elements: [Self.element(decomposed, role: "AXcafé", path: "café")], quality: base.quality)),
            ("role", Self.sample(title: "café", elements: [Self.element("café", role: "AX\(decomposed)", path: "café")], quality: base.quality)),
            ("containerPath", Self.sample(title: "café", elements: [Self.element("café", role: "AXcafé", path: decomposed)], quality: base.quality)),
            ("windowRole", Self.sample(title: "café", elements: base.elements, quality: Self.quality(role: decomposed, subrole: "café"))),
            ("windowSubrole", Self.sample(title: "café", elements: base.elements, quality: Self.quality(role: "café", subrole: decomposed))),
        ]
        #expect(base == Self.sample(title: "caf" + "é", elements: [Self.element("caf" + "é", role: "AXcaf" + "é", path: "caf" + "é")],
                                    quality: Self.quality(role: "caf" + "é", subrole: "caf" + "é")))
        for (name, variant) in variants {
            #expect(base != variant && variant != base, Comment(rawValue: name))
        }
        let plain = Self.sample()
        var other = plain
        other.windowTitle = nil
        #expect(plain != other)
        other.windowTitle = ""
        #expect(plain != other && Self.sample(title: nil) != Self.sample(title: ""))
        other = plain
        other.elements.reverse()
        #expect(plain != other, "elements in another order are another sample")
        other = plain
        other.sessionRevision = nil
        #expect(plain != other)
        other = plain
        other.elements[0].isUnderCollection = true
        #expect(plain != other)
        other = plain
        other.elements[0].bounds.y = other.elements[0].bounds.y.nextUp
        #expect(plain != other)
        other = plain
        other.quality.nodesVisited = 13
        #expect(plain != other)
        other = plain
        other.elements[0].label = "Send\u{0}"
        #expect(plain != other)
    }
}
