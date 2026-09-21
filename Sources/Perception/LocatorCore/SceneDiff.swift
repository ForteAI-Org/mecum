import Foundation
import CoreGraphics

/// TEXT-scene differ — how the brain learns CAUSALITY (B2, docs/UI_BRAIN_PLAN.md §5): diff the scene
/// before/after a user input event and name the effect. Pure + deterministic, so it's testable with
/// synthetic scene pairs — never a pixel diff.
public enum SceneDiff {
    /// The effect FAMILY ("stateFlip", "menuOpened", …) — for comparing an observed effect against an
    /// expectation: a flip's direction or a menu's exact items may vary; the KIND of effect shouldn't.
    public static func family(_ effect: String) -> String { String(effect.prefix(while: { $0 != ":" })) }

    /// Human-compact rendering for scene annotations and act reports ("toggles", "opens menu(Cut|Copy…)").
    public static func summary(_ effect: String) -> String {
        let fam = family(effect)
        let rest = effect.count > fam.count ? String(effect.dropFirst(fam.count + 1)) : ""
        switch fam {
        case "stateFlip": return "toggles"
        case "menuOpened":
            let items = rest.split(separator: "|")
            return "opens menu(\(items.prefix(3).joined(separator: "|"))\(items.count > 3 ? "…" : ""))"
        case "elementsAppeared": return "reveals elements"
        case "elementsDisappeared": return "closes elements"
        case "windowTitleChanged": return "navigates to \(rest)"
        default: return effect
        }
    }

    /// The learned effect of an event, as a compact stable string (nil = nothing attributable):
    ///   "windowTitleChanged:<title>" | "stateFlip:<from>><to>" | "menuOpened:<l1>|<l2>|…"
    ///   | "elementsAppeared:<n>:<l1>|…" | "elementsDisappeared:<n>"
    /// `targetID` = the element the event hit (from the BEFORE scene); `point` = normalized event point.
    public static func effect(before: SceneSnapshot, after: SceneSnapshot,
                              targetID: String?, point: CGPoint?) -> String? {
        // 1. Navigation: the window title family changed (letters-only — counters/timecodes don't count).
        if KnowledgeText.letters(before.windowTitle) != KnowledgeText.letters(after.windowTitle) {
            return "windowTitleChanged:\(String(after.windowTitle.prefix(40)))"
        }

        // 2. The target's state flipped (the clicked switch toggled).
        if let targetID, let t0 = before.elements.first(where: { $0.id == targetID }), let s0 = t0.state {
            let t1 = after.elements.first(where: { $0.id == targetID })
                ?? after.elements.first(where: {
                    $0.kind == t0.kind && $0.state != nil
                        && KnowledgeText.normalize($0.label) == KnowledgeText.normalize(t0.label)
                })
            if let s1 = t1?.state, s1 != s0 { return "stateFlip:\(s0)>\(s1)" }
        }

        // 3. New elements — damped against OCR jitter AND live-pane volatility: an element counts as
        //    NEW only if neither its id nor its (normalized) label existed before, and only STABLE
        //    labels count at all — a pro-audio canvas repaints meters/dB/timecodes on every frame, and
        //    measurements are NOT UI (measured on Pro Tools: three identical mute clicks produced three
        //    unique effect strings of meter noise, so no transition could ever reach trusted evidence).
        //    Effect strings carry SORTED stable labels and NO counts — same action ⇒ same string.
        let beforeIDs = Set(before.elements.map(\.id))
        let beforeLabels = Set(before.elements.map { KnowledgeText.normalize($0.label) }.filter { !$0.isEmpty })
        let fresh = after.elements.filter { e in
            guard !beforeIDs.contains(e.id), e.unlabeled != true, e.pos.count == 4,
                  isStableLabel(e.label) else { return false }
            let n = KnowledgeText.normalize(e.label)
            return !n.isEmpty && !beforeLabels.contains(n)
        }
        if fresh.count >= 3 {
            let xs = fresh.map { $0.pos[0] }, ys = fresh.map { $0.pos[1] }
            let clustered = (xs.max()! - xs.min()!) <= 0.45 && (ys.max()! - ys.min()!) <= 0.7
            let labels = canonicalLabels(fresh)
            return clustered ? "menuOpened:\(labels)" : "elementsAppeared:\(labels)"
        }
        if fresh.count >= 1 { return "elementsAppeared:\(canonicalLabels(fresh))" }

        // 4. A cluster of stable elements vanished (panel/menu closed).
        let afterIDs = Set(after.elements.map(\.id))
        let afterLabels = Set(after.elements.map { KnowledgeText.normalize($0.label) }.filter { !$0.isEmpty })
        let gone = before.elements.filter { e in
            guard !afterIDs.contains(e.id), e.unlabeled != true, isStableLabel(e.label) else { return false }
            let n = KnowledgeText.normalize(e.label)
            return !n.isEmpty && !afterLabels.contains(n)
        }
        if gone.count >= 3 { return "elementsDisappeared:\(canonicalLabels(gone))" }
        return nil
    }

    /// Sorted, deduped, capped label list — the CANONICAL identity of an appearance effect. Sorting +
    /// dedup + no counts is what lets the same action produce the same string, so evidence accumulates.
    static func canonicalLabels(_ elements: [SceneElement], cap: Int = 6) -> String {
        // NAMES only, not prose: a Creative Cloud menu carried items like "A Create stunning
        // illustrations and graphics." (a description OCR'd next to the real item) — storing those as
        // the menu's contents buried the actual commands ("Desktop") the knowledge exists to surface.
        let named = elements.map(\.label)
            .filter { $0.count <= 24 && !$0.hasSuffix(".") }
        let pool = named.isEmpty ? elements.map(\.label) : named
        return Array(Set(pool)).sorted().prefix(cap).joined(separator: "|")
    }

    /// Is this label STABLE UI (a name) rather than a live MEASUREMENT? Filters what a diff may treat
    /// as appearing/vanishing. Rules from real Pro Tools data: pure numerics/timecodes ("00:00:12:00",
    /// "2827313") have no letters; dB readouts ("+17.6 db", "-Od", "+0dB") are digits + a dB unit.
    public static func isStableLabel(_ s: String) -> Bool {
        guard s.count >= 2, s.filter(\.isLetter).count >= 2 else { return false }
        let n = KnowledgeText.normalize(s)
        if n.hasSuffix("db"), n.dropLast(2).allSatisfy({ $0.isNumber }) { return false }   // "+17.6 db"
        if n.hasPrefix("od") || n.hasSuffix("ode") || n == "odb" { return false }          // "-Od"/"+OdE" misreads
        return true
    }
}
