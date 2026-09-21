import Foundation

/// Recognizes ACCORDION / DISCLOSURE rows — a section header preceded by a chevron that is collapsed
/// (▸ points right) or expanded (▾ points down). This is the pattern that defeated a live agent
/// session: Premiere's export panel is a stack of these (VIDEO, AUDIO, GENERAL, METADATA…), and
/// "expand GENERAL and show me what's inside" flailed because the scene showed "> GENERAL" / "V
/// METADATA" as raw text — the model never learned the chevron MEANS collapsed/expanded.
///
/// We surface the meaning as an affordance: a collapsed row gets `does = "click: EXPANDS this
/// section (collapsed — its options are hidden until you click)"`, an expanded row gets `does =
/// "click: collapses (expanded — its options are listed below)"`, and the chevron glyph is stripped
/// from the label so `act(target:"GENERAL")` resolves cleanly. Pure + deterministic; no model.
public enum DisclosureRow {
    public enum State: Equatable { case collapsed, expanded }

    // OCR renders the chevrons a few ways; ">" collapsed, "v"/"V"/"⌄" expanded are what we see live.
    private static let collapsedGlyphs: Set<Character> = [">", "›", "▶", "▸", "❯", "→"]
    private static let expandedGlyphs: Set<Character> = ["v", "V", "⌄", "▼", "▾", "∨"]

    /// If `label` is a disclosure row, return its clean header + state. Guarded hard against false
    /// positives: the rest after the glyph must be an ALL-CAPS section header (letters/spaces, ≥3
    /// chars) — "> AUDIO", "V METADATA", "V CONTENT CREDENTIALS" qualify; "Video content fragment"
    /// and a stray "v" in prose do not.
    public static func classify(_ label: String) -> (header: String, state: State)? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        let state: State
        if collapsedGlyphs.contains(first) { state = .collapsed }
        else if expandedGlyphs.contains(first) { state = .expanded }
        else { return nil }
        // The glyph must be its OWN token (a space follows), not the first letter of a word ("Video").
        let afterGlyph = trimmed.dropFirst()
        guard let sep = afterGlyph.first, sep == " " else { return nil }
        let rest = afterGlyph.drop(while: { $0 == " " })
        let headerLetters = rest.filter { $0.isLetter }
        guard headerLetters.count >= 3,
              headerLetters.allSatisfy({ $0.isUppercase }),
              rest.allSatisfy({ $0.isLetter || $0.isWhitespace }) else { return nil }
        return (String(rest).trimmingCharacters(in: .whitespaces), state)
    }

    /// Rewrite disclosure rows in a scene element list: clean the label, attach the expand/collapse
    /// affordance. Everything else passes through untouched. Idempotent.
    public static func annotate(_ elements: [SceneElement]) -> [SceneElement] {
        elements.map { e in
            guard e.kind != "icon", let (header, state) = classify(e.label) else { return e }
            var out = e
            out.label = header
            out.does = (state == .collapsed)
                ? "click: EXPANDS this section (collapsed — its options are hidden until you click it)"
                : "click: collapses (expanded — its options are listed below it)"
            return out
        }
    }
}
