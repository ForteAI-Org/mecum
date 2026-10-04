//
//  ElementGrouper.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation

/// ElementGrouper turns raw detections, text runs and icon boxes, into composite elements before a
/// scene is built: it merges the fragments of one line into a phrase, pairs an icon with the text
/// that names it (to its right, to its left, or centered beneath it) into one control, and pairs a
/// switch with its same-row label across a settings row, carrying the switch's state.
///
/// Pure geometry over rectangles in one pixel space. Every threshold scales with the element it
/// judges, so the rules hold at any pixel density. Output order is deterministic: composites,
/// then the remaining texts, then the remaining icons, each in input order.
public enum ElementGrouper {

    /// One recognized text run in pixel space.
    public struct TextRun: Sendable, Equatable {
        public var rect: CGRect
        public var text: String

        public init(rect: CGRect, text: String) {
            self.rect = rect
            self.text = text
        }
    }

    /// One icon candidate. `label` is a taught name when one is known; `isToggle` and `isMark` say
    /// which pairing convention applies; `state` is what a pixel read established.
    public struct IconCandidate: Sendable, Equatable {
        public var rect: CGRect
        public var label: String?
        public var isToggle: Bool
        public var isMark: Bool
        public var state: ControlState?

        public init(
            rect    : CGRect,
            label   : String? = nil,
            isToggle: Bool = false,
            isMark  : Bool = false,
            state   : ControlState? = nil
        ) {
            self.rect     = rect
            self.label    = label
            self.isToggle = isToggle
            self.isMark   = isMark
            self.state    = state
        }
    }

    /// One composite element. `label` is empty only when `isUnlabeled` is true.
    public struct GroupedElement: Sendable, Equatable {
        public var rect: CGRect
        public var kind: ElementKind
        public var label: String
        public var isUnlabeled: Bool
        public var state: ControlState?

        public init(
            rect       : CGRect,
            kind       : ElementKind,
            label      : String,
            isUnlabeled: Bool = false,
            state      : ControlState? = nil
        ) {
            self.rect        = rect
            self.kind        = kind
            self.label       = label
            self.isUnlabeled = isUnlabeled
            self.state       = state
        }
    }

    /// A detected switch. `inferredState` is set when geometry alone tells the state (the knob's
    /// side), which beats any pixel read; nil asks the caller to read pixels. `isAssumed` marks the
    /// unanchored-column fallback, whose knob the caller must confirm is a plain disc.
    public struct SwitchCandidate: Sendable, Equatable {
        public let rect: CGRect
        public let inferredState: ControlState?
        public let isAssumed: Bool

        public init(rect: CGRect, inferredState: ControlState?, isAssumed: Bool = false) {
            self.rect          = rect
            self.inferredState = inferredState
            self.isAssumed     = isAssumed
        }

        /// The square at the switch's left end, where an assumed switch's knob must be.
        public var knobSquare: CGRect {
            CGRect(x: rect.minX, y: rect.minY, width: rect.height, height: rect.height)
        }

        public var rightEndSquare: CGRect {
            CGRect(x: rect.maxX - rect.height, y: rect.minY, width: rect.height, height: rect.height)
        }
    }

    private struct Claim {
        let icon: Int
        let text: Int
        let gap: CGFloat
        let enclosureRank: Int

        init(icon: Int, text: Int, gap: CGFloat, enclosureRank: Int = 1) {
            self.icon = icon
            self.text = text
            self.gap = gap
            self.enclosureRank = enclosureRank
        }
    }

    // MARK: Grouping

    /// Runs the full pass: merge text fragments, then pair icons with their captions, marks with
    /// the text on their right, and switches with the label on their left.
    public static func group(texts: [TextRun], icons: [IconCandidate]) -> [GroupedElement] {
        let merged = mergeLines(texts)

        // Caption pass: every icon claims its nearest caption; one text names at most one icon.
        var claims: [Claim] = []
        for (iconIndex, icon) in icons.enumerated() {
            var best: (text: Int, gap: CGFloat, enclosureRank: Int)?
            for (textIndex, text) in merged.enumerated() {
                guard text.text.count <= 48,
                      LabelText.isNameworthy(text.text),
                      text.rect.height <= 2.5 * icon.rect.height,
                      let gap = pairGap(icon: icon.rect, text: text.rect) else { continue }
                // A switch is named by the row pass, from its left; a caption to its right is a list row.
                if icon.isToggle, text.rect.minX >= icon.rect.minX - 0.2 * icon.rect.height { continue }
                if isNextListLine(icon: icon.rect, caption: text.rect, texts: merged) { continue }
                let rank = enclosesButtonLabel(icon: icon.rect, text: text.rect) ? 0 : 1
                if best.map({ (rank, gap) < ($0.enclosureRank, $0.gap) }) ?? true {
                    best = (textIndex, gap, rank)
                }
            }
            if let best {
                claims.append(Claim(icon: iconIndex, text: best.text, gap: best.gap,
                                    enclosureRank: best.enclosureRank))
            }
        }

        var out: [GroupedElement] = []
        var consumedText = Set<Int>(), pairedIcon = Set<Int>()
        for claim in claims.sorted(by: {
            ($0.enclosureRank, $0.gap, $0.icon) < ($1.enclosureRank, $1.gap, $1.icon)
        })
        where !consumedText.contains(claim.text) && !pairedIcon.contains(claim.icon) {
            let icon = icons[claim.icon], text = merged[claim.text]
            out.append(GroupedElement(
                rect: icon.rect.union(text.rect), kind: .control, label: text.text, state: icon.state
            ))
            consumedText.insert(claim.text)
            pairedIcon.insert(claim.icon)
        }

        // Mark pass: a checkbox or radio is named by the text on its right.
        var markClaims: [Claim] = []
        for (iconIndex, icon) in icons.enumerated() where !pairedIcon.contains(iconIndex) && icon.isMark {
            var best: (text: Int, gap: CGFloat)?
            for (textIndex, text) in merged.enumerated() {
                guard text.text.count <= 48, LabelText.isNameworthy(text.text),
                      verticalOverlap(icon.rect, text.rect) >= 0.6 * min(icon.rect.height, text.rect.height)
                else { continue }
                let gap = text.rect.minX - icon.rect.maxX
                guard gap > -2, gap <= 2.5 * icon.rect.height else { continue }
                if best.map({ gap < $0.gap }) ?? true { best = (textIndex, gap) }
            }
            if let best { markClaims.append(Claim(icon: iconIndex, text: best.text, gap: best.gap)) }
        }
        for claim in markClaims.sorted(by: { ($0.gap, $0.icon) < ($1.gap, $1.icon) })
        where !consumedText.contains(claim.text) && !pairedIcon.contains(claim.icon) {
            let icon = icons[claim.icon]
            out.append(GroupedElement(
                rect: icon.rect, kind: .control, label: merged[claim.text].text, state: icon.state
            ))
            consumedText.insert(claim.text)
            pairedIcon.insert(claim.icon)
        }

        // Row pass: a switch far from its label on one line. A text already used by a caption
        // composite is borrowable, since the row's name belongs to the row's toggle too.
        var rowClaims: [Claim] = []
        for (iconIndex, icon) in icons.enumerated() where !pairedIcon.contains(iconIndex) && icon.isToggle {
            var best: (text: Int, gap: CGFloat)?
            for (textIndex, text) in merged.enumerated() {
                guard text.text.count <= 48, LabelText.isNameworthy(text.text),
                      verticalOverlap(icon.rect, text.rect) >= 0.6 * min(icon.rect.height, text.rect.height)
                else { continue }
                let gap = icon.rect.minX - text.rect.maxX
                guard gap > 0, gap <= 45 * icon.rect.height else { continue }
                if best.map({ gap < $0.gap }) ?? true { best = (textIndex, gap) }
            }
            if let best { rowClaims.append(Claim(icon: iconIndex, text: best.text, gap: best.gap)) }
        }
        // One switch per row label: when several claim one text, the rightmost is the row's toggle
        // and the others are shape-passed impostors, demoted to stateless unlabeled icons.
        var demoted = Set<Int>()
        for (_, competing) in Dictionary(grouping: rowClaims, by: \.text) where competing.count > 1 {
            guard let winner = competing.max(by: { icons[$0.icon].rect.minX < icons[$1.icon].rect.minX }) else {
                continue
            }
            for claim in competing where claim.icon != winner.icon { demoted.insert(claim.icon) }
        }
        for claim in rowClaims.sorted(by: { ($0.gap, $0.icon) < ($1.gap, $1.icon) })
        where !pairedIcon.contains(claim.icon) && !demoted.contains(claim.icon) {
            let icon = icons[claim.icon]
            out.append(GroupedElement(
                rect: icon.rect, kind: .control, label: merged[claim.text].text, state: icon.state
            ))
            consumedText.insert(claim.text)
            pairedIcon.insert(claim.icon)
        }

        for (textIndex, text) in merged.enumerated() where !consumedText.contains(textIndex) {
            out.append(GroupedElement(rect: text.rect, kind: .text, label: text.text))
        }
        for (iconIndex, icon) in icons.enumerated() where !pairedIcon.contains(iconIndex) {
            let label = icon.label ?? ""
            out.append(GroupedElement(
                rect       : icon.rect,
                kind       : .icon,
                label      : label,
                isUnlabeled: label.isEmpty,
                state      : demoted.contains(iconIndex) ? nil : icon.state
            ))
        }
        return out
    }

    /// Merges fragments on one baseline with word-sized gaps into one phrase. Never merges across a
    /// column gap (over 0.9 line heights) or across font sizes (height ratio over 1.8).
    public static func mergeLines(_ texts: [TextRun]) -> [TextRun] {
        let runs = texts.sorted {
            $0.rect.midY != $1.rect.midY ? $0.rect.midY < $1.rect.midY : $0.rect.minX < $1.rect.minX
        }
        var used = [Bool](repeating: false, count: runs.count)
        var out: [TextRun] = []
        for i in runs.indices where !used[i] {
            var accumulated = runs[i]
            used[i] = true
            var changed = true
            while changed {
                changed = false
                for j in runs.indices where !used[j] {
                    let a = accumulated.rect, b = runs[j].rect
                    let minHeight = min(a.height, b.height), maxHeight = max(a.height, b.height)
                    guard minHeight > 0, maxHeight / minHeight <= 1.8, abs(a.midY - b.midY) <= 0.5 * minHeight else {
                        continue
                    }
                    let gapRight = b.minX - a.maxX
                    let gapLeft  = a.minX - b.maxX
                    if gapRight >= -2, gapRight <= 0.9 * minHeight {
                        accumulated = TextRun(rect: a.union(b), text: accumulated.text + " " + runs[j].text)
                    } else if gapLeft >= -2, gapLeft <= 0.9 * minHeight {
                        accumulated = TextRun(rect: a.union(b), text: runs[j].text + " " + accumulated.text)
                    } else {
                        continue
                    }
                    used[j] = true
                    changed = true
                }
            }
            out.append(accumulated)
        }
        return out
    }

    // MARK: Switches and marks

    /// Coalesces segments within `gap` pixels of one another into their bounding unions, sorted
    /// top to bottom. A low-contrast control splits into pieces whose union is the real control.
    static func coalesce(segments: [CGRect], gap: CGFloat) -> [CGRect] {
        var parent = Array(segments.indices)
        func find(_ index: Int) -> Int {
            var i = index
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in segments.indices {
            for j in (i + 1)..<segments.count where segments[i].insetBy(dx: -gap, dy: -gap).intersects(segments[j]) {
                parent[find(j)] = find(i)
            }
        }
        var unions: [Int: CGRect] = [:]
        for i in segments.indices {
            let root = find(i)
            unions[root] = unions[root].map { $0.union(segments[i]) } ?? segments[i]
        }
        return unions.values.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// Returns the square-ish coalesced unions: checkbox and radio candidates, whose state lives
    /// inside them. Geometry cannot tell a hollow checkbox from a logo of the same size, so the
    /// caller confirms each candidate with pixels, which also supplies its state.
    public static func markCandidates(
        segments    : [CGRect],
        gap         : CGFloat = 5,
        isMarkShaped: (CGRect) -> Bool
    ) -> [CGRect] {
        coalesce(segments: segments, gap: gap).filter(isMarkShaped)
    }

    /// Detects switches among raw segments: coalesced pill shapes, knob-only squares stacked in a
    /// known pill's column (whose side gives the state), and the unanchored column of two or more
    /// same-size squares sharing a left edge, assumed to be all-off switches for the caller to confirm.
    public static func toggleCandidates(
        segments      : [CGRect],
        gap           : CGFloat = 5,
        isToggleShaped: (CGRect) -> Bool
    ) -> [SwitchCandidate] {
        let unions = coalesce(segments: segments, gap: gap)
        let pills  = unions.filter(isToggleShaped)
        var switches = pills.map { SwitchCandidate(rect: $0, inferredState: nil) }
        let squares = unions.filter { union in
            let aspect = union.width / max(union.height, 1)
            return !pills.contains(union) && aspect >= 0.8 && aspect <= 1.25
                && union.height >= 12 && union.height <= 100
        }
        var unanchored: [CGRect] = []
        for square in squares {
            if let pill = pills.first(where: {
                abs($0.height - square.height) <= 0.25 * $0.height
                    && square.minX >= $0.minX - 4 && square.maxX <= $0.maxX + 4
            }) {
                let placed = CGRect(
                    x: pill.minX, y: square.midY - pill.height / 2, width: pill.width, height: pill.height
                )
                switches.append(SwitchCandidate(rect: placed, inferredState: square.midX < placed.midX ? .off : .on))
            } else {
                unanchored.append(square)
            }
        }
        for square in unanchored {
            let siblings = unanchored.filter {
                abs($0.minX - square.minX) <= 4 && abs($0.height - square.height) <= 0.25 * square.height
            }
            guard siblings.count >= 2 else { continue }
            switches.append(SwitchCandidate(
                rect         : CGRect(
                    x: square.minX, y: square.minY, width: 1.7 * square.height, height: square.height
                ),
                inferredState: nil,
                isAssumed    : true
            ))
        }
        return switches.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
    }

    /// True when a real word (three or more characters) covers a quarter of the box: it is text,
    /// not a switch. Short glyph misreads over switch chrome never veto.
    public static func switchVetoedByText(_ rect: CGRect, runs: [(text: String, box: CGRect)]) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        return runs.contains { run in
            let text = run.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 3, LabelText.isNameworthy(text) else { return false }
            let intersection = run.box.intersection(rect)
            return !intersection.isNull && intersection.width * intersection.height >= 0.25 * rect.width * rect.height
        }
    }

    // MARK: Shape tests

    /// True for a lone circle-like read ("O", "0", "•"): a switch knob or a radio dot seen as a
    /// letter. Such a read is neither text nor a veto. Multi-character runs are never dropped.
    public static func isKnobGlyph(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let character = trimmed.first else { return false }
        return "O0o•◦●○◎◉⚪⬤".contains(character)
    }

    /// True for a segment that is a text glyph a recognizer skipped, a bullet, bracket or
    /// punctuation mark, rather than an icon: small or thin relative to the line height, and on a
    /// baseline with a recognized run within one line height.
    public static func isTextGlyph(_ segment: CGRect, ocrBoxes: [CGRect], lineHeight: CGFloat) -> Bool {
        guard lineHeight > 0, segment.width > 0, segment.height > 0 else { return false }
        let small = max(segment.width, segment.height) <= 0.6 * lineHeight
        let thin  = segment.width <= 0.5 * segment.height && segment.height <= 1.4 * lineHeight
        guard small || thin else { return false }
        return ocrBoxes.contains { box in
            guard verticalOverlap(segment, box) >= 0.5 * segment.height else { return false }
            let horizontalGap = max(box.minX - segment.maxX, segment.minX - box.maxX)
            return horizontalGap <= lineHeight
        }
    }

    /// True for a box with a caption centered directly beneath it, no wider than the box: a
    /// thumbnail in a gallery, which is an icon however large it is.
    public static func hasCaptionBelow(_ box: CGRect, ocrBoxes: [CGRect]) -> Bool {
        guard box.width > 0, box.height > 0 else { return false }
        return ocrBoxes.contains { text in
            let verticalGap = text.minY - box.maxY
            return verticalGap >= -2 && verticalGap <= 0.25 * box.height
                && text.width <= 1.05 * box.width && text.height <= 0.3 * box.height
                && abs(text.midX - box.midX) <= 0.2 * box.width
        }
    }

    /// True when the candidate caption below an icon is the next row of a list: the icon is itself
    /// a labeled box and the caption shares that label's font height and left edge.
    static func isNextListLine(icon: CGRect, caption: CGRect, texts: [TextRun]) -> Bool {
        guard caption.minY - icon.maxY >= -2 else { return false }
        return texts.contains { run in
            let covered = icon.intersection(run.rect)
            guard !covered.isNull, covered.width * covered.height >= 0.6 * icon.width * icon.height else {
                return false
            }
            return run.rect.height >= 0.8 * caption.height && run.rect.height <= 1.25 * caption.height
                && abs(run.rect.minX - caption.minX) <= 0.5 * caption.height
        }
    }

    /// The separation between an icon and a text that could be its caption, smaller meaning a
    /// stronger pair, or nil when the layout is none of: label right, label left, caption centered
    /// beneath. A caption carries a half-pixel penalty so a side label wins a tie.
    static func pairGap(icon: CGRect, text: CGRect) -> CGFloat? {
        // A button's enclosed label must name its own border before a neighboring caption.
        if enclosesButtonLabel(icon: icon, text: text) { return 0 }
        let aligned = verticalOverlap(icon, text) >= 0.5 * min(icon.height, text.height)
        let side = 0.9 * icon.height
        if aligned {
            let gapRight = text.minX - icon.maxX
            if gapRight >= -2, gapRight <= side { return max(0, gapRight) }
            let gapLeft = icon.minX - text.maxX
            if gapLeft >= -2, gapLeft <= side { return max(0, gapLeft) }
        }
        let verticalGap = text.minY - icon.maxY
        if verticalGap >= -2, verticalGap <= 0.7 * icon.height,
           abs(text.midX - icon.midX) <= max(0.6 * icon.width, 0.3 * text.width) {
            return max(0, verticalGap) + 0.5
        }
        return nil
    }

    /// Recognizes a centered label inset in a border of button height. A glyph-sized blob or
    /// text inside a thumbnail does not give its surrounding segment a button's label.
    private static func enclosesButtonLabel(icon: CGRect, text: CGRect) -> Bool {
        icon.contains(text)
            && icon.height >= 1.5 * text.height && icon.height <= 3.5 * text.height
            && abs(icon.midX - text.midX) <= 0.25 * icon.width
            && abs(icon.midY - text.midY) <= 0.25 * icon.height
    }

    private static func verticalOverlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        min(a.maxY, b.maxY) - max(a.minY, b.minY)
    }
}
