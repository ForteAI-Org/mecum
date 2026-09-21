import Foundation
import CoreGraphics

/// THE NEXT MOVE, COMPOSED FROM WHAT THE ENGINE ALREADY KNOWS.
///
/// A miss that only says what did NOT happen makes the agent guess, and the guess is usually the same
/// click again: a measured session clicked a phantom four times, then rendered with the wrong export
/// preset. Everything needed to end that loop was already in hand at the moment of the miss — which
/// pane scrolls and on which AXIS (`SceneSection.scrolls` / `.scrollsX`), where ACCESSIBILITY says the
/// target hides (`AXSceneAugmentor.findOffView`), and whether anything moved ELSEWHERE (the app's
/// window list before vs after the gesture). This composer turns those facts into ONE sentence.
///
/// Deliberately pure, and deliberately NOT a discoverer: it never scrolls, captures, or walks AX to
/// find something to say. Callers hand it what they already paid for; a fact it isn't given simply
/// goes unsaid. That is what keeps a guided miss the same round trip as an unguided one, and what lets
/// the wording be pinned by offline tests instead of by watching a live app.
public enum MissGuide {

    // MARK: - Where a target hides, and which way to go

    /// An element ACCESSIBILITY places outside its container's visible box — `findOffView`'s answer,
    /// restated without a dependency on the Relocation module (this module is the leaf). Both rects are
    /// global top-left points, the space AX and CGWindowList agree on.
    public struct OffView: Sendable, Equatable {
        public let label: String
        public let frame: CGRect        // the target's VIRTUAL (unclipped) frame
        public let container: CGRect    // its clipping container's VISIBLE box
        public init(label: String, frame: CGRect, container: CGRect) {
            self.label = label; self.frame = frame; self.container = container
        }
    }

    /// Which way a pane must move to reveal something outside it. Same arithmetic reach steers by, so
    /// the sentence an agent reads and the scroll the engine performs can never disagree.
    public struct Way: Sendable, Equatable {
        public let horizontal: Bool
        public let goRight: Bool
        public let goDown: Bool
        /// The direction as the scroll verb spells it — "right" / "left" / "down" / "up".
        public var word: String { horizontal ? (goRight ? "right" : "left") : (goDown ? "down" : "up") }
        /// The direction as the map spells it, for a reader skimming arrows.
        public var arrow: String { horizontal ? (goRight ? "→" : "←") : (goDown ? "↓" : "↑") }
        /// The direction as ENGLISH places it — "right of", "below" — for naming where a thing sits.
        public var side: String { horizontal ? (goRight ? "right of" : "left of") : (goDown ? "below" : "above") }
    }

    /// A GESTURE THE ENGINE HAS ALREADY WATCHED DO NOTHING — one pane, one direction, as the scroll verb
    /// spells them. Measured defect (ticket 15): minutes after `scroll(section:"content (Render
    /// Settings)", direction:"right")` answered `acted_noop`, a miss on that same window recommended
    /// that exact call. Guidance the agent cannot follow is worse than no guidance — it turns one wasted
    /// round into two, and it teaches the agent to distrust the one channel meant to end the flailing.
    ///
    /// DIRECTIONAL on purpose: a sideways no-op is genuinely ambiguous between "this pane does not
    /// scroll" and "it is at its right end", and only the second reading survives a left recommendation.
    /// Withholding a true next move is the same failure in the other direction.
    public struct DeadScroll: Sendable, Hashable {
        public let section: String      // the MAP's name for the pane, as scroll(section:) takes it
        public let direction: String    // "right" / "left" / "down" / "up"
        public init(section: String, direction: String) {
            self.section = section; self.direction = direction
        }
    }

    /// The direction from a container's visible box to a target sitting outside it. Y grows DOWNWARD
    /// (global top-left points), so a larger midY is genuinely "below". The axis with the larger
    /// overshoot wins; a tie goes to horizontal, which is the axis a vertical hunt can never cover.
    public static func way(target: CGRect, container: CGRect) -> Way {
        let dxR = target.midX - container.maxX      // >0 ⇒ target lies right of the visible box
        let dxL = container.minX - target.midX      // >0 ⇒ left
        let dyD = target.midY - container.maxY      // >0 ⇒ below
        let dyU = container.minY - target.midY      // >0 ⇒ above
        return Way(horizontal: max(dxR, dxL) >= max(dyD, dyU), goRight: dxR >= dxL, goDown: dyD >= dyU)
    }

    /// The BAND of a container that actually holds an off-view target — its ROW when the target is
    /// hidden sideways, its COLUMN when hidden vertically. The same narrowing reach aims its wheel by,
    /// and here it is what makes a name findable: AX containers and CV sections are drawn by different
    /// eyes, and the measured case has no tight AX node at all — the Deliver carousel's only ancestor is
    /// the whole 449×754 settings panel, which no single section covers. The band does land inside one.
    public static func band(target: CGRect, container: CGRect, way: Way) -> CGRect {
        let r: CGRect = way.horizontal
            ? CGRect(x: container.minX, y: max(container.minY, target.minY - 8),
                     width: container.width, height: min(target.height + 48, container.height))
            : CGRect(x: max(container.minX, target.minX - 8), y: container.minY,
                     width: min(target.width + 48, container.width), height: container.height)
        let clipped = r.intersection(container)
        return clipped.isNull ? container : clipped
    }

    /// The MAP'S NAME for a rect — the section an agent can pass to `scroll(section:)`. Chosen by how
    /// much of the rect a section covers. Returns nil rather than the nearest guess: a section name that
    /// doesn't exist sends the next call straight into another miss.
    public static func containerName(_ container: CGRect, windowFrame: CGRect?,
                                     sections: [SceneSection]) -> String? {
        guard let win = windowFrame, win.width > 0, win.height > 0, !container.isNull else { return nil }
        let norm = CGRect(x: (container.minX - win.minX) / win.width, y: (container.minY - win.minY) / win.height,
                          width: container.width / win.width, height: container.height / win.height)
        guard norm.width > 0, norm.height > 0 else { return nil }
        var best: (name: String, cover: CGFloat)?
        for s in sections where s.pos.count == 4 {
            let r = CGRect(x: s.pos[0], y: s.pos[1], width: s.pos[2], height: s.pos[3])
            let inter = r.intersection(norm)
            guard !inter.isNull, inter.width > 0, inter.height > 0 else { continue }
            let cover = (inter.width * inter.height) / (norm.width * norm.height)
            if cover > (best?.cover ?? 0) { best = (s.name, cover) }
        }
        guard let best, best.cover >= 0.5 else { return nil }
        return best.name
    }

    /// ONE sentence of guidance for a target that did not resolve — nil when the engine knows nothing
    /// useful (silence beats filler at prompt cost).
    /// - `suggestReach`: false once reach ITSELF has missed, because "call reach" is then the advice
    ///   that just failed; the pane and the axis stay true, the verb becomes the unspent one.
    /// - `deadScrolls`: pane+direction gestures already PROVEN inert (the ledger's remembered no-ops).
    ///   Never recommended — see `DeadScroll`.
    /// - `directedStuck`: the AX-directed scroll acted on THIS placement and the pane did not budge, so
    ///   accessibility's claim is a map entry the engine could not corroborate rather than a fact about
    ///   the screen. It changes how strongly the placement is stated, and it retires the gesture.
    public static func forMissedTarget(target: String, sections: [SceneSection], offView: OffView?,
                                      windowFrame: CGRect?, suggestReach: Bool,
                                      deadScrolls: Set<DeadScroll> = [],
                                      directedStuck: Bool = false) -> String? {
        // 1. ACCESSIBILITY KNOWS WHERE IT IS. The strongest fact available: a named container and a
        //    direction, which is exactly what reach's AX-directed path steers by.
        if let off = offView {
            let w = way(target: off.frame, container: off.container)
            // Name the BAND, never the raw container: a wide AX container often spans several map
            // sections, and then the section covering "most" of it can easily be one the target is not
            // in (measured shape: a 900×720 panel whose lower half is a different pane entirely). The
            // row — or column — the target actually sits in is both the honest answer and the one an
            // agent can pass to scroll(section:). No name ⇒ say "its scrolling container" and let reach
            // find the pane, which is what it is for.
            let name = containerName(band(target: off.frame, container: off.container, way: w),
                                     windowFrame: windowFrame, sections: sections)
            // AS STRONGLY AS THE EVIDENCE SUPPORTS, AND NO STRONGER. "places" is a claim about the
            // screen; once the AX-directed scroll has acted on this very placement and the pane refused
            // to move, that claim is exactly what the same call just failed to act on — printing it as a
            // fact next to the failure is the self-contradiction ticket 15 measured, and the agent has no
            // way to tell which half to believe. "lists" is the honest verb for a map entry.
            let place = "accessibility \(directedStuck ? "lists" : "places") '\(off.label)' \(w.side) \(name.map { "▣ \($0)" } ?? "its scrolling container")"
            if suggestReach {
                // reach is the gesture that reaches a SUB-container the section-level wheel cannot (it
                // aims at the pane's centre and lands on the settings form — ticket 14), so a remembered
                // section-scroll no-op is no reason to stop naming it.
                return "next: \(place) — reach(target:\"\(target)\") scrolls that pane \(w.word) for you."
            }
            // THE GESTURE ABOUT TO BE RECOMMENDED, CHECKED AGAINST WHAT THE ENGINE ALREADY KNOWS. Both
            // ways of knowing count: this call's own directed attempt stalling, and a no-op the ledger
            // remembers from an earlier call on the same pane and direction.
            let learnedDead = name.map { deadScrolls.contains(DeadScroll(section: $0, direction: w.word)) } ?? false
            if directedStuck || learnedDead {
                let why = directedStuck
                    ? "but that pane did NOT move when scrolled \(w.word) (wheel + thumb both tried)"
                    : "but scrolling it \(w.word) already answered acted_noop here"
                return "next: \(place), \(why) — another scroll round is wasted: manage_window(action:\"maximize\") shows more of that pane, or re-read the label."
            }
            if let name {
                return "next: \(place) — scroll(section:\"\(name)\", direction:\"\(w.word)\") and look again."
            }
            return "next: \(place) — scroll(direction:\"\(w.word)\") aimed at that pane and look again."
        }
        // 2. A PROVEN SIDEWAYS STRIP. reach's vision hunt is vertical, so the sideways axis has to name
        //    the scroll verb explicitly even when reach is still worth suggesting for the other axis.
        // Only the directions that have NOT already answered acted_noop here. Both spent ⇒ this branch
        // has no true move left; it hands over to the vertical panes and, failing those, to the honest
        // negative below — which must then NOT claim that nothing here scrolls.
        var sidewaysSpent: String?
        if let strip = biggest(sections.filter { $0.scrollsX != nil }) {
            let ways = ["right", "left"].filter { !deadScrolls.contains(DeadScroll(section: strip.name, direction: $0)) }
            if let first = ways.first {
                let alt = ways.count > 1 ? " or \"\(ways[1])\"" : ""
                return "next: ▣ \(strip.name) slides sideways (proven) — scroll(section:\"\(strip.name)\", direction:\"\(first)\")\(alt) and look again."
            }
            sidewaysSpent = strip.name
        }
        // 3. VERTICAL SCROLLERS. reach owns that hunt; name the panes so a section arg is available.
        let vertical = sections.filter { $0.scrolls != nil }.sorted { area($0) > area($1) }.prefix(2)
        if !vertical.isEmpty {
            let names = vertical.map { "▣ \($0.name)" }.joined(separator: " / ")
            let verb = vertical.count > 1 ? "scroll" : "scrolls"
            let firstV = vertical.first?.name ?? ""
            if suggestReach {
                return "next: \(names) \(verb) — reach(target:\"\(target)\") hunts it for you."
            }
            // A pane whose DOWN already answered acted_noop is at its bottom (or deaf); either way only
            // an unspent direction is worth naming, and with both spent the pane is not where to look.
            let unspent = ["down", "up"].filter { !deadScrolls.contains(DeadScroll(section: firstV, direction: $0)) }
            guard let vWord = unspent.first else {
                return "next: \(names) \(verb), but ▣ \(firstV) already answered acted_noop both ways — the label is wrong, or it sits behind a dropdown/tab rather than below the fold."
            }
            return "next: \(names) \(verb) — scroll(section:\"\(firstV)\", direction:\"\(vWord)\") a page at a time, or the label is wrong."
        }
        // 4. NOTHING SCROLLS — and saying so is the guidance. Scroll-hunting a static window is the
        //    round this sentence exists to stop. A strip whose BOTH directions are spent is the one case
        //    where that negative would be false: this window does scroll sideways, it just has nothing
        //    left to give, and claiming otherwise is the same lie in reverse.
        if let spent = sidewaysSpent {
            // reach aims INSIDE the pane — at the target's own row, not the pane's centre — so it drives
            // sub-containers the section verb cannot reach (ticket 14, and verified live: `scroll(section:)`
            // no-ops BOTH ways on Resolve's carousel while `reach` slides it every time). A spent section
            // verb therefore says nothing about reach, and dropping it here would withhold the one gesture
            // that still works: this ticket's defect in reverse. Once reach has missed too, nothing is left.
            if suggestReach {
                return "next: ▣ \(spent) slides sideways but scroll(section:) answered acted_noop both ways — reach(target:\"\(target)\") drives that pane itself, or the label is wrong."
            }
            return "next: ▣ \(spent) slides sideways but already answered acted_noop both ways, and no other pane here scrolls — re-read the label, or open the dropdown/tab that holds it."
        }
        return "next: no pane here advertises scrolling, so a scroll or reach round is wasted — re-read the label, or open the dropdown/tab that holds it."
    }

    // MARK: - What changed elsewhere after an act that could not be verified

    /// One of the app's on-screen windows, cheaply: identity, title, layer, size — no pixels, no OCR.
    /// Comparing this before and after a gesture is how "nothing happened here" becomes either "nothing
    /// happened ANYWHERE" or "the effect landed in that other window".
    public struct WindowSig: Sendable, Equatable {
        public let id: UInt32
        public let title: String?
        public let layer: Int
        public let size: CGSize
        /// Whether the CAPTURE layer classified this window as an open pop-up. A layer number cannot
        /// answer that on its own: a toolkit that draws its own widgets parks a dropdown on an ORDINARY
        /// window layer (DaVinci Resolve — ticket 12), and calling that "a NEW window appeared" sends
        /// the agent hunting for a window when what opened was a list to read. Defaults to false, so a
        /// caller with no classifier still gets the layer-range answer below.
        public let isPopup: Bool
        public init(id: UInt32, title: String?, layer: Int, size: CGSize, isPopup: Bool = false) {
            self.id = id; self.title = title; self.layer = layer; self.size = size; self.isPopup = isPopup
        }
    }

    /// Layers where macOS parks an OPEN POP-UP MENU. Mirrors `WindowCaptureService.isPopupLayer`; the
    /// constant cannot be shared from there because this module is the leaf both sides build on.
    static let popupLayers = 21...200

    /// What the census found, and its one clause. `changed` exists so a caller can DROP its own
    /// speculation instead of contradicting the fact: "the click likely did not register" must not be
    /// printed next to "a new window appeared".
    public struct Elsewhere: Sendable, Equatable {
        public let changed: Bool
        public let sentence: String
        public init(changed: Bool, sentence: String) { self.changed = changed; self.sentence = sentence }
    }

    /// ONE clause naming what changed OUTSIDE the window that was perceived — or naming the absence,
    /// which is the whole point: an agent that knows nothing moved anywhere stops retrying the click.
    /// Never nil, because "nothing" is itself the answer a dead click needs.
    ///
    /// The census is THIS APP's windows, and the wording says so. Widening it to every app on screen
    /// would read live chrome — a clock, a mail badge, another agent's window — as the effect of this
    /// click, so the negative stays scoped and keeps the cross-app pointer the old speculative tail
    /// carried, rather than declaring a cross-app effect dead.
    public static func forUnverifiedAct(app: String, before: [WindowSig], after: [WindowSig]) -> Elsewhere {
        let had = Set(before.map(\.id))
        let has = Set(after.map(\.id))
        // APPEARED wins: a dialog or a menu that opened IS the effect, and it is where to look next.
        if let new = after.first(where: { !had.contains($0.id) }) {
            if new.isPopup || popupLayers.contains(new.layer) {
                return Elsewhere(changed: true, sentence: "Elsewhere a pop-up menu opened — the click did land; read the menu in the scene below (or Escape it).")
            }
            return Elsewhere(changed: true, sentence: "Elsewhere a NEW window \(quoted(new.title, fallback: "\(Int(new.size.width))×\(Int(new.size.height))pt")) appeared — the effect landed THERE; describe_scene reads it.")
        }
        if let gone = before.first(where: { !has.contains($0.id) }) {
            if gone.isPopup || popupLayers.contains(gone.layer) {
                return Elsewhere(changed: true, sentence: "Elsewhere a pop-up menu closed — the click dismissed it rather than selecting in this window.")
            }
            return Elsewhere(changed: true, sentence: "Elsewhere the window \(quoted(gone.title, fallback: "\(Int(gone.size.width))×\(Int(gone.size.height))pt")) closed — that was the effect.")
        }
        // A RETITLED window is a navigation the perceived window may not show.
        for b in before {
            guard let a = after.first(where: { $0.id == b.id }) else { continue }
            let t0 = (b.title ?? "").trimmingCharacters(in: .whitespaces)
            let t1 = (a.title ?? "").trimmingCharacters(in: .whitespaces)
            if t0 != t1, !t1.isEmpty {
                return Elsewhere(changed: true, sentence: "Elsewhere the window is now titled \(quoted(t1, fallback: t1)) — that was the effect.")
            }
        }
        // A RESIZE ALONE IS NOT AN EFFECT. Live UIs reflow their own bounds (a canvas repainting, a
        // meter strip), and calling that "something changed" would relaunch the very guessing this
        // sentence exists to end.
        return Elsewhere(changed: false, sentence: "Nothing else in \(app) changed either — no window of it opened, closed or retitled; if the effect was meant for ANOTHER app verify there, otherwise this was a dead click, not a slow one.")
    }

    // MARK: - helpers

    private static func quoted(_ s: String?, fallback: String) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? fallback : "\"\(t)\""
    }
    private static func area(_ s: SceneSection) -> Double {
        s.pos.count == 4 ? s.pos[2] * s.pos[3] : 0
    }
    private static func biggest(_ ss: [SceneSection]) -> SceneSection? {
        ss.max { area($0) < area($1) }
    }
}
