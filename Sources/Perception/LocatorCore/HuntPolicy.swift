import Foundation

/// WHAT A MISS IS ALLOWED TO COST — how much scroll-hunting a `reach` may pay for, decided BEFORE the
/// first capture from what accessibility has already said for free.
///
/// The measurement this exists for (ticket 13, DaVinci's Deliver page, one call apart):
///
///     reach("Audio Only")  → found_acted, AX-directed                  1.08s
///     reach("Pro Tools")   → honest_miss, AX-directed + vertical hunt  18.42s
///
/// 18.42s bought exactly one bit — "not here" — and it is paid precisely when the agent guessed a label
/// wrong, which is the common case, not the rare one. A miss is also the moment the agent has the LEAST
/// information and most needs another round, so it is the worst possible place to spend a session's
/// patience.
///
/// The cheap answer is available before the expensive one runs: one bounded AX walk of the window
/// (measured at 0.02–0.04s on Resolve and Premiere) says whether accessibility knows this label at all.
/// The whole difficulty is deciding when that silence MEANS anything, and the honest answer is not "does
/// the app have AX" — it is "does its AX map know its own list CONTENT":
///
///     DaVinci Resolve  278 labels, 232 of them content (172 static texts, 59 checkable presets)
///     Adobe Premiere   144 labels,   5 of them content — 91 buttons, 26 combo boxes: pure chrome
///     Google Chrome     30 labels,   0 of them content
///     Finder           186 labels, 146 content, but the walk RAN OUT of its wall budget
///
/// Every toolkit hands out its widget layer for free, so a label count says nothing; the rows, cells,
/// static texts and checkable items a LIST is made of are what a reach target actually is. Premiere is
/// the app the pixel hunt exists for and it would sail past any label-count floor — hence the content
/// floor, and hence a walk that must have FINISHED before its silence is allowed to end a search.
///
/// Pure and unit-tested: the numbers above are pinned as cases, so the next person changing a threshold
/// argues with a measurement instead of with a hunch.
public enum HuntPolicy {

    /// The axis accessibility placed an off-view target on. Sideways matters because the vision hunt is
    /// vertical-only — no amount of it can move a pane sideways.
    public enum Axis: Sendable, Equatable { case sideways, vertical }

    /// What ONE bounded AX walk of the target window learned, before anything scrolled.
    public struct AXVerdict: Sendable, Equatable {
        /// Every label the walk read. The map's SIZE — reported so a reader can judge the claim.
        public let labelsRead: Int
        /// Labels on CONTENT roles (rows, cells, static text, checkable list items) as opposed to chrome
        /// (buttons, tabs, combo boxes). The exposure signal that actually discriminates — see above.
        public let contentLabels: Int
        /// The walk covered the tree: it neither ran out of its wall budget nor truncated at its depth
        /// cap. An unfinished census can only say "not in the part I read".
        public let complete: Bool
        /// Some label anywhere in the map matched the target — on-view, off-view, static or interactive.
        /// Wider than `placed` on purpose: if AX knows the label at all, the target exists and the hunt
        /// is worth its cost.
        public let knowsLabel: Bool
        /// AX matched the target as an off-view INTERACTIVE control, and which way it sits from its
        /// container's visible box (`AXSceneAugmentor.findOffView`'s hit). nil = no such placement.
        public let placed: Axis?

        public init(labelsRead: Int, contentLabels: Int, complete: Bool, knowsLabel: Bool, placed: Axis?) {
            self.labelsRead = labelsRead; self.contentLabels = contentLabels
            self.complete = complete; self.knowsLabel = knowsLabel; self.placed = placed
        }
    }

    /// How much hunting is authorized, and why.
    public struct Plan: Sendable, Equatable {
        /// Candidate panes the vision hunt may walk: nil = every candidate (today's behaviour, unchanged
        /// for every app whose AX cannot rule anything out), 0 = do not hunt at all.
        public let panes: Int?
        /// Wall budget for the hunt, seconds. 0 when there is no hunt.
        public let seconds: Int
        /// Why this much — always non-empty, because a shortened search that cannot say so reads as a
        /// proof of absence, which is the one thing it never is.
        public let because: String
        public var huntsAtAll: Bool { panes != 0 }

        public init(panes: Int?, seconds: Int, because: String) {
            self.panes = panes; self.seconds = seconds; self.because = because
        }

        /// The hunt as it ran before any of this existed — every candidate pane, the full budget. What a
        /// caller that took no AX census gets, so "no census" can never mean "search less".
        public static let unrestricted = Plan(
            panes: nil, seconds: fullHuntSeconds,
            because: "no accessibility census was taken here, so the hunt ran unrestricted.")
    }

    /// CONTENT labels at or above which a completed AX map is trusted to know its own lists, so a label
    /// missing from it is treated as absent. 24 sits an order of magnitude below Resolve's 232 and well
    /// above Premiere's 5, Chrome's 0 and TextEdit's 13 (a toolbar's worth of checkable items) — the
    /// margin is wide on both sides, which is the only reason a single constant is honest here.
    public static let trustedContentFloor = 24
    /// The interactive hunt budget as it stands today, for every case AX cannot shorten.
    public static let fullHuntSeconds = 25
    /// A hunt that only needs to CHECK accessibility's placement, not search the app: two panes is what
    /// the cold-target path already probes, and 10s covers a couple of screenfuls of list.
    public static let cappedHuntSeconds = 10
    public static let cappedHuntPanes = 2

    /// The one decision. Ordered by how much the input actually proves.
    public static func decide(ax: AXVerdict) -> Plan {
        // 1. AX PLACED IT SIDEWAYS and the directed slide already failed. The vertical hunt cannot cover
        //    that axis at all, so its cost is pure waste — this is the stack that measured 18.42s.
        if ax.placed == .sideways {
            return Plan(panes: 0, seconds: 0,
                        because: "accessibility places this label SIDEWAYS of its container and the AX-directed slide couldn't reveal it; the vision hunt only scrolls vertically, so it cannot cover that axis.")
        }
        // 2. AX PLACED IT VERTICALLY and the directed scroll still failed. The virtual frame may be a
        //    phantom, and the pane hunt is the tool that can check — capped, since a cheap answer exists.
        if ax.placed == .vertical {
            return Plan(panes: cappedHuntPanes, seconds: cappedHuntSeconds,
                        because: "accessibility places this label above/below its container but the directed scroll didn't reveal it, so the pane hunt was capped to \(cappedHuntPanes) panes to check.")
        }
        // 3. A FINISHED MAP THAT KNOWS ITS OWN CONTENT AND NOT THIS LABEL. The cheap answer, and the
        //    whole point: the pixel hunt would spend ~20s to reach the same conclusion.
        if !ax.knowsLabel, ax.complete, ax.contentLabels >= trustedContentFloor {
            return Plan(panes: 0, seconds: 0,
                        because: "accessibility lists \(ax.contentLabels) content labels in this window and none of them is this one, so a scroll-hunt would spend ~20s to learn the same thing.")
        }
        // 4. EVERYTHING ELSE HUNTS AS IT DOES TODAY. Four distinct reasons, all reported by name — the
        //    difference between "we know nothing" and "we know the label exists" matters to a reader.
        let why: String
        if ax.knowsLabel {
            why = "accessibility does know this label, just not as an off-view control, so the pane hunt was worth its cost."
        } else if ax.labelsRead == 0 {
            // BEFORE the incomplete case, not after it: zero labels can mean the app exposes no
            // accessibility OR that there was no window frame to walk one with (`OffViewProbe.noWindow`,
            // which is honestly `complete: false`). Blaming a budget for a walk that never happened is a
            // claim about work nobody did.
            why = "no accessibility map was read here at all, so the pixel hunt is the only evidence and it ran in full."
        } else if !ax.complete {
            why = "the accessibility walk ran out of its own budget here, so its silence proves nothing and the hunt ran in full."
        } else {
            why = "accessibility here exposes chrome only (\(ax.labelsRead) labels, \(ax.contentLabels) of them list content), so it cannot rule anything out and the hunt ran in full."
        }
        return Plan(panes: nil, seconds: fullHuntSeconds, because: why)
    }

    /// HOW MUCH OF THE APP WAS ACTUALLY SEARCHED, for the miss text. Facts only — what was looked at,
    /// what was not, and the plan's reason. It deliberately recommends nothing: `MissGuide` owns the
    /// "next:" clause, and two composers offering advice in one sentence is how a message comes to
    /// contradict itself.
    /// - `walked`: panes the hunt really walked; nil when it never ran.
    /// - `seconds`: what the hunt cost; nil when it never ran.
    /// - `stoppedEarly`: the hunt hit its budget with panes left — said out loud, never silently.
    public static func searched(ax: AXVerdict, plan: Plan, panesAvailable: Int,
                                walked: Int?, seconds: Double?, stoppedEarly: Bool) -> String {
        var parts = ["the visible scene"]
        // WHAT THE MAP CONTRIBUTED, worded from how far the walk actually got. A census is only quotable
        // as the map's size when the walk finished it: the walk that stops at an off-view match read the
        // tree only up to that node (measured: 57 of Resolve's 278 labels), and quoting that understates
        // the map by 5x — while the placement it stopped for is the real evidence anyway.
        if ax.placed != nil {
            parts.append("accessibility's own placement for it")
        } else if ax.labelsRead == 0 {
            parts.append("no accessibility map here to consult")
        } else if !ax.complete {
            parts.append("accessibility's map of it, read as far as the walk's budget allowed (\(ax.labelsRead) labels)")
        } else {
            parts.append("accessibility's map of it (\(ax.labelsRead) labels, \(ax.contentLabels) of them list content)")
        }
        // A window whose map advertises no scrolling anywhere has no denominator to report; "0 of 0"
        // reads as a counting bug rather than as "there was nothing to walk".
        //
        // Just "panes", never "scrollable panes": the denominator is the hunt's own candidate list
        // (tall panels plus the whole window), which is NOT the set of panes the map advertises as
        // scrollable. Measured live on Premiere, that one word put "2 of 2 scrollable panes pixel-hunted"
        // one clause away from the guidance's "no pane here advertises scrolling" — two true statements
        // about different things, reading as a contradiction.
        let panes = panesAvailable == 0
            ? "no pane the map calls scrollable"
            : "\(walked ?? 0) of \(panesAvailable) pane\(panesAvailable == 1 ? "" : "s")"
        if plan.huntsAtAll {
            var hunt = "\(panes) pixel-hunted"
            if let seconds { hunt += String(format: " in %.1fs", seconds) }
            if stoppedEarly { hunt += ", then stopped with panes left" }
            parts.append(hunt)
        } else {
            parts.append("\(panes) pixel-hunted — that hunt was skipped")
        }
        return "searched: " + parts.joined(separator: " + ") + ". " + plan.because
    }
}
