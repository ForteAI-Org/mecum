//
//  TextMeasure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

/// TextUnit is what a quantity of text is counted in, and there are two because
/// the two text paths of this kit genuinely count in different things.
///
/// On ASCII they agree, which is exactly why writing "characters" for both went
/// unnoticed: a limit derived from one and applied to the other is wrong only
/// where it matters, on an emoji with a zero width joiner, on a flag, on a
/// combining sequence.
public enum TextUnit: Sendable, Equatable {

    /// What a person would call a character, and what Swift calls a
    /// `Character`. It is the unit of `.text` because it is the unit of the
    /// **cost**: one key down and one key up per cluster.
    case graphemeClusters

    /// The unit `keyboardSetUnicodeString` actually takes, and therefore the
    /// unit of anything carried on an event: `.insertText` and the text of a
    /// `.key`. It is also the unit of their limit.
    case utf16CodeUnits
}

/// TextMeasure is a quantity of text that says what it counted.
///
/// A bare `Int` is what let the two units blur together in the first place, and
/// a receipt read by a report, a test and a budget check cannot afford the
/// ambiguity. Bytes are deliberately not a unit here: `data.count` is the
/// natural and wrong way to derive a limit for either path.
public struct TextMeasure: Sendable, Equatable {

    public let unit : TextUnit
    public let count: Int

    public init(_ count: Int, _ unit: TextUnit) {
        self.count = count
        self.unit  = unit
    }
}
