import Foundation

/// Fuzzy match a user's spoken app phrase against a running app's name + bundle id. The LLM passes what
/// the USER said ("premiere", "Premiere Pro", "pro tools"), never the bundle — and app NAMES rarely
/// equal that phrase (Premiere's localizedName is "Adobe Premiere", bundle com.adobe.PremierePro.26).
/// So we normalize both to lowercase-alphanumeric and match by containment, then fall back to "every
/// query WORD appears" — order- and punctuation-insensitive. (Measured: literal-substring matching
/// failed "Premiere Pro" because the space isn't in "adobe premiere" or "com.adobe.premierepro.26".)
public enum AppMatch {
    public static func matches(query: String, name: String, bundle: String) -> Bool {
        let hay = KnowledgeText.normalize(name) + KnowledgeText.normalize(bundle)
        guard !hay.isEmpty else { return false }
        let qn = KnowledgeText.normalize(query)
        if !qn.isEmpty, hay.contains(qn) { return true }                 // "premierepro" ⊂ "…premierepro26"
        let toks = KnowledgeText.tokens(query).map { KnowledgeText.normalize($0) }.filter { !$0.isEmpty }
        return !toks.isEmpty && toks.allSatisfy { hay.contains($0) }      // all words present, any order
    }

    /// The INVERSE direction: is this app MENTIONED inside a longer phrase ("go to simone in slack" →
    /// Slack)? Lets the server infer the app from a tool's own text when the model forgot the app arg —
    /// a small model shouldn't need to route perfectly when the query already names the app (measured:
    /// gemma called run_route(name:"slack") with no app and got refused, then gave up). Conservative:
    /// only name tokens ≥4 chars count (a 2-3 char token like "to"/"pro" alone would false-positive),
    /// and the caller must require a UNIQUE app across the running set.
    public static func mentioned(in phrase: String, name: String, bundle: String) -> Bool {
        let words = Set(KnowledgeText.tokens(phrase).map { KnowledgeText.normalize($0) })
        guard !words.isEmpty else { return false }
        let nameToks = KnowledgeText.tokens(name).map { KnowledgeText.normalize($0) }.filter { $0.count >= 4 }
        if nameToks.contains(where: { words.contains($0) }) { return true }
        // Also try the bundle's distinctive component ("com.tinyspeck.slackmacgap" → "slackmacgap"
        // won't match, but "com.adobe.PremierePro" → "premierepro" contains "premiere"): check whether
        // any phrase word ≥4 chars is a substring of the normalized name+bundle.
        let hay = KnowledgeText.normalize(name) + KnowledgeText.normalize(bundle)
        return words.contains { $0.count >= 4 && hay.contains($0) }
    }
}
