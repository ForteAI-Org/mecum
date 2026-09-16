//
//  TextMeasureTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics
import SeatCore
import Testing

@Suite("Text measure")
struct TextMeasureTests {

    /// A family emoji: one grapheme cluster, several scalars joined by zero
    /// width joiners, and eleven UTF-16 code units. It is the string that makes
    /// the difference between the two units visible.
    static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"

    /// A flag: one cluster, two regional indicators, four code units.
    static let flag = "\u{1F1EE}\u{1F1F9}"

    @Test("a typed string is counted in grapheme clusters, because that is what it costs")
    func typedTextCountsClusters() {
        let measure = InputCommand.text(Self.family).textMeasure

        // One keystroke, not eleven. A person pressing this produces one.
        #expect(measure == TextMeasure(1, .graphemeClusters))
    }

    @Test("an inserted string is counted in UTF-16 code units, because that is its payload")
    func insertedTextCountsCodeUnits() {
        let measure = InputCommand.insertText(Self.family).textMeasure

        // What `keyboardSetUnicodeString` is handed, and what its limit is
        // expressed in.
        #expect(measure == TextMeasure(8, .utf16CodeUnits))
    }

    @Test("the two units agree on ASCII, which is why mixing them went unnoticed")
    func unitsAgreeOnASCII() {
        let typed    = InputCommand.text("agentseat").textMeasure
        let inserted = InputCommand.insertText("agentseat").textMeasure

        #expect(typed?.count == inserted?.count)
        #expect(typed?.unit != inserted?.unit)
    }

    @Test("a flag is one keystroke and four code units")
    func flagIsOneCluster() {
        #expect(InputCommand.text(Self.flag).textMeasure       == TextMeasure(1, .graphemeClusters))
        #expect(InputCommand.insertText(Self.flag).textMeasure == TextMeasure(4, .utf16CodeUnits))
    }

    @Test("a key carries its text in the unit it travels on the event in")
    func keyCountsCodeUnits() {
        #expect(
            InputCommand.key(virtualKey: 0, text: "à").textMeasure
                == TextMeasure(1, .utf16CodeUnits)
        )
    }

    @Test("a Command that carries no text measures nothing rather than zero")
    func noTextMeansNoMeasure() {
        // Nil and not zero: a zero would read as a Command that carried an
        // empty string, which is a refusal, not a measurement.
        #expect(InputCommand.key(virtualKey: 53, text: "").textMeasure == nil)
        #expect(InputCommand.scroll(Self.location, deltaY: -6).textMeasure == nil)
    }

    private static let location = InputLocation(
        screenPoint       : .init(x: 10, y: 10),
        windowPointFromTop: .init(x: 10, y: 10)
    )
}
