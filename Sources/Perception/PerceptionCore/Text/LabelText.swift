//
//  LabelText.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import Foundation

/// LabelText is the small, dependency-free vocabulary for comparing UI labels: a coarse normalizer
/// for candidate selection, a tokenizer, a title family, and the test that a string can name a
/// control at all. Final correctness of any match is the caller's live verification, never these.
public enum LabelText {

    /// Lowercase alphanumerics only: "✓ 48000" and "48000" normalize alike.
    public static func normalize(_ string: String) -> String {
        String(string.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The text without the bidi isolates and marks an application wraps names in, U+2066 to
    /// U+2069, U+200E and U+200F, and without outer whitespace: a file panel reads its folders as
    /// isolated names, and a model copies them back with or without them.
    public static func withoutBidiControls(_ string: String) -> String {
        let controls: Set<UInt32> = [0x2066, 0x2067, 0x2068, 0x2069, 0x200E, 0x200F]
        let kept = string.unicodeScalars.filter { !controls.contains($0.value) }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
    }

    /// A menu item's title as compared: without bidi controls, typographic quotes read as straight
    /// ones, no trailing ellipsis or three dots, lowercased. Finder titles an item
    /// `Compress “carla_video_bn”`, and a model or a recognizer gives it straight quotes.
    public static func menuTitleKey(_ title: String) -> String {
        var text = withoutBidiControls(title)
        for (typographic, straight) in [("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'")] {
            text = text.replacingOccurrences(of: typographic, with: straight)
        }
        if text.hasSuffix("\u{2026}") { text.removeLast() } else if text.hasSuffix("...") { text.removeLast(3) }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Which of `titles` a menu item named `wanted` is: the one whose `menuTitleKey` equals it, else
    /// the one whose key begins with it and a space or a quote, as "Compress" names Finder's
    /// `Compress “carla_video_bianco_nero.mov”`. Nil for none or several: an exact title wins over a
    /// longer one ("Open" over "Open With"), and two longer ones stay ambiguous.
    public static func menuItemMatch(_ wanted: String, in titles: [String]) -> Int? {
        let key = menuTitleKey(wanted)
        guard !key.isEmpty else { return nil }
        let keys  = titles.map(menuTitleKey)
        let exact = keys.indices.filter { keys[$0] == key }
        if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        let longer = keys.indices.filter { index in
            [" ", "\"", "'"].contains { keys[index].hasPrefix(key + $0) }
        }
        return longer.count == 1 ? longer[0] : nil
    }

    /// The `{context}` a rendered map appends to a label, nil when the string carries none.
    public static func displayContext(_ string: String) -> String? {
        var text = string.trimmingCharacters(in: .whitespaces)
        while let last = text.last, let opener = [Character("]"): " [", ")": " (", "}": " {"][last],
              let range = text.range(of: opener, options: .backwards) {
            if last == "}" { return String(text[range.upperBound..<text.index(before: text.endIndex)]) }
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Lowercase runs of letters and digits, punctuation dropped.
    public static func tokens(_ string: String) -> [String] {
        string.lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Lowercase letters only: the title's family, stable across a counter or timecode in it.
    public static func letters(_ string: String) -> String {
        String(string.lowercased().filter { $0.isLetter })
    }

    /// True when the text holds at least one letter or digit. Punctuation-only recognitions such as
    /// "•••" or "›" are chrome misreads and never name a control.
    public static func isNameworthy(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Coarse, digit-sensitive lexical score of a query against a text, 0 for no relation. Exact
    /// normalized equality scores 3, the same token set 2.5, one token set inside the other 2, and
    /// otherwise the fraction of query tokens found.
    public static func matchScore(query: String, against text: String) -> Double {
        let normalizedQuery = normalize(query), normalizedText = normalize(text)
        guard !normalizedQuery.isEmpty, !normalizedText.isEmpty else { return 0 }
        if normalizedQuery == normalizedText { return 3 }
        let queryTokens = Set(tokens(query)), textTokens = Set(tokens(text))
        guard !queryTokens.isEmpty, !textTokens.isEmpty else { return 0 }
        if queryTokens == textTokens { return 2.5 }
        if queryTokens.isSubset(of: textTokens) || textTokens.isSubset(of: queryTokens) { return 2 }
        return Double(queryTokens.intersection(textTokens).count) / Double(queryTokens.count)
    }

    /// Junk-tolerant core of a label: leading tokens of two characters or fewer are dropped (the
    /// avatar glyph a recognizer fuses into a name), the rest is joined without punctuation.
    /// "Ze Simone" and "Za Simone" both become "simone"; "#_all-team" becomes "allteam".
    public static func coreKey(_ string: String) -> String {
        var parts = tokens(string)
        while parts.count > 1, parts[0].count <= 2 { parts.removeFirst() }
        return parts.joined()
    }

    /// True for a label that is stable UI, a name, rather than a live measurement. Pure numerics and
    /// timecodes have no letters; dB readouts are digits plus a unit; two known misreads of a dB
    /// readout are listed by shape.
    public static func isStableLabel(_ string: String) -> Bool {
        guard string.count >= 2, string.filter(\.isLetter).count >= 2 else { return false }
        let normalized = normalize(string)
        if normalized.hasSuffix("db"), normalized.dropLast(2).allSatisfy({ $0.isNumber }) { return false }
        if normalized.hasPrefix("od") || normalized.hasSuffix("ode") || normalized == "odb" { return false }
        return true
    }

    /// Strips the display annotations a rendered map appends, " [state]", " (ordinal)" and
    /// " {context}", so a target copied from the map still matches the bare label. Peels repeatedly.
    public static func strippingDisplayAnnotations(_ string: String) -> String {
        var text = string.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("]") || text.hasSuffix(")") || text.hasSuffix("}") {
            let opener = text.hasSuffix("]") ? " [" : text.hasSuffix(")") ? " (" : " {"
            guard let range = text.range(of: opener, options: .backwards) else { break }
            text = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }
}
