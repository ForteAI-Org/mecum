//
//  SceneTargetReferenceTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

import Foundation
@testable import PerceptionCore
import Testing

/// A model passes a target as the text map shows it. The lines below are the ones Claude copied in
/// the live runs of 28/09/2026 on Pro Tools and TextEdit, plus the rendering's own output.
@Suite("Scene target reference")
struct SceneTargetReferenceTests {

    @Test("a line copied from the scene reads back as its label, value and container")
    func copiedLines() {
        let cases: [(String, String, String?, String?)] = [
            ("Automation Mode selector = auto read {Track 2}", "Automation Mode selector", "auto read", "Track 2"),
            (#"Track name "Track 2" = Track 2 {Track 2}"#, #"Track name "Track 2""#, "Track 2", "Track 2"),
            (#"Track name "Track 2" {Track 2}"#, #"Track name "Track 2""#, nil, "Track 2"),
            ("grassetto [off] {Formattazione} (row#1)", "grassetto", nil, "Formattazione"),
            ("spaziatura riga = 1,0 {Formattazione}", "spaziatura riga", "1,0", "Formattazione"),
            ("spaziatura riga = 1,0", "spaziatura riga", "1,0", nil),
            ("Mute {Track 2} (row#3)", "Mute", nil, "Track 2"),
            ("Insert selector A {Track 1 / Inserts A-E} (INSERTS A-E#1)", "Insert selector A", nil,
             "Track 1 / Inserts A-E"),
            ("azioni per il documento [disabled]", "azioni per il documento", nil, nil),
        ]
        for (text, label, value, container) in cases {
            let reference = SceneTargetReference(parsing: text)
            #expect(reference == SceneTargetReference(label: label, value: value, container: container), "\(text)")
        }
    }

    @Test("a plain label is its own label, its own parentheses and brackets included")
    func plainLabels() {
        for text in ["Mute", "Save (Recommended)", "Output [Main]", "AltoriMBP12 =", "Prova mecum", "?|@2,1"] {
            let reference = SceneTargetReference(parsing: text)
            #expect(reference == SceneTargetReference(label: text), "\(text)")
            #expect(!reference.isDecorated)
        }
    }

    @Test("a label the scene shows is kept whole, even when it looks like a rendering mark")
    func shownLabelsAreKept() {
        let shown: Set<String> = ["x = y", "mix {a}", "export"].reduce(into: []) { $0.insert(LabelText.normalize($1)) }
        #expect(SceneTargetReference(parsing: "x = y", shownLabels: shown) == SceneTargetReference(label: "x = y"))
        #expect(SceneTargetReference(parsing: "Mix {A}", shownLabels: shown) == SceneTargetReference(label: "Mix {A}"))
        #expect(SceneTargetReference(parsing: "x = y {Panel}", shownLabels: shown)
                == SceneTargetReference(label: "x = y", container: "Panel"))
        #expect(SceneTargetReference(parsing: "Export = PDF {File}", shownLabels: shown)
                == SceneTargetReference(label: "Export", value: "PDF", container: "File"))
        #expect(SceneTargetReference(parsing: "x = y") == SceneTargetReference(label: "x", value: "y"),
                "without the scene's labels every mark is read")
    }

    @Test("every element line the rendering writes reads back as the element it shows")
    func renderingRoundTrip() {
        let bounds = NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.05)
        let elements = [
            SceneElement(id: "a", kind: .control, label: "Mute", bounds: bounds, state: .on, container: "Track 2",
                         group: "row#3"),
            SceneElement(id: "b", kind: .control, label: "stile", bounds: bounds, value: "Regolare",
                         container: "Formattazione"),
            SceneElement(id: "c", kind: .control, label: "Export", bounds: bounds, isEnabled: false),
            SceneElement(id: "d", kind: .text, label: "Prova mecum", bounds: bounds),
        ]
        let scene = SceneSnapshot(bundleID: "com.x", appName: "X", windowTitle: "W",
                                  viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: elements)
        let lines = scene.text().split(separator: "\n").filter { $0.contains("] ") && $0.contains("  @ ") }
        #expect(lines.count == elements.count)
        for (line, element) in zip(lines, elements) {
            let shown = String(line[line.range(of: "] ")!.upperBound...])
            let reference = SceneTargetReference(parsing: shown)
            #expect(reference.label == element.label, "\(shown)")
            #expect(reference.value == element.value, "\(shown)")
            #expect(reference.container == element.container, "\(shown)")
        }
    }
}
