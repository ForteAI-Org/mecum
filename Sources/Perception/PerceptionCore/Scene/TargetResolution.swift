//
//  TargetResolution.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation

/// TargetResolution finds the one element a target string names, or says precisely why it cannot.
///
/// An id must identify one target. A label must be unique after three tolerant tiers: exact, display
/// annotations stripped, then the junk-free core. Facets of one widget on one row collapse to one
/// target; the same name in two rows stays ambiguous, because those are two places.
extension SceneSnapshot {

    /// How a target string resolved against this scene.
    public enum Resolution: Sendable, Equatable {
        case found(SceneElement)
        /// This many elements share the name; the caller must add a section or an id.
        case ambiguous(Int)
        case none
    }

    /// Resolves an action target. `preferStateful` narrows a shared name to the elements carrying
    /// state, which is what a toggle verb wants. `section` restricts the search to one panel.
    /// `preferNativeControls` distinguishes a click target from a plain-text caption only when
    /// accessibility supplies an interactive role. Multiple matching controls remain ambiguous.
    /// `preferTextEntry` narrows shared IDs and labels to native text fields; two fields still refuse.
    public func resolve(
        target: String,
        preferStateful: Bool = false,
        section: String? = nil,
        preferNativeControls: Bool = false,
        preferTextEntry: Bool = false
    ) -> Resolution {
        let resolvedSection = section.flatMap { resolveSection(named: $0)?.name }
        func inSection(_ element: SceneElement) -> Bool {
            guard let section, !section.isEmpty else { return true }
            return element.section?.caseInsensitiveCompare(resolvedSection ?? section) == .orderedSame
                || (resolvedSection == nil && element.container?.caseInsensitiveCompare(section) == .orderedSame)
        }
        func preferringTextEntry(_ candidates: [SceneElement]) -> [SceneElement] {
            guard preferTextEntry, candidates.count > 1 else { return candidates }
            let fields = candidates.filter {
                $0.kind == .control && AccessibilityAugmentation.textEntryRoles.contains($0.role ?? "")
            }
            return fields.isEmpty ? candidates : fields
        }
        let byID = Self.collapseSameRow(preferringTextEntry(elements.filter { $0.id == target && inSection($0) }))
        if byID.count > 1 { return .ambiguous(byID.count) }
        if let match = byID.first { return .found(match) }

        let cleaned = LabelText.strippingDisplayAnnotations(target)
        let bare = Self.plain(target)
        var byLabel = elements.filter {
            inSection($0) && Self.plain($0.label).caseInsensitiveCompare(bare) == .orderedSame
        }
        if byLabel.isEmpty, cleaned != target {
            byLabel = elements.filter {
                inSection($0)
                    && Self.plain(LabelText.strippingDisplayAnnotations($0.label))
                        .caseInsensitiveCompare(Self.plain(cleaned)) == .orderedSame
            }
        }
        // The scene prints a control as "label = value": that copy names the element with both.
        if byLabel.isEmpty, let separator = cleaned.range(of: " = ") {
            let label = LabelText.withoutBidiControls(String(cleaned[..<separator.lowerBound]))
            let value = LabelText.withoutBidiControls(String(cleaned[separator.upperBound...]))
            byLabel = elements.filter {
                inSection($0)
                    && LabelText.withoutBidiControls($0.label).caseInsensitiveCompare(label) == .orderedSame
                    && $0.value.map(LabelText.withoutBidiControls)?.caseInsensitiveCompare(value) == .orderedSame
            }
        }
        if byLabel.isEmpty {
            let want = LabelText.coreKey(cleaned)
            if !want.isEmpty {
                byLabel = elements.filter { inSection($0) && LabelText.coreKey($0.label) == want }
            }
        }
        if byLabel.isEmpty {
            let valueKey = LabelText.coreKey(cleaned)
            byLabel = elements.filter {
                inSection($0) && !valueKey.isEmpty && $0.value.map(LabelText.coreKey) == valueKey
                    && AccessibilityAugmentation.interactiveRoles.contains($0.role ?? "")
            }
        }
        byLabel = preferringTextEntry(byLabel)
        if preferStateful, byLabel.count > 1 {
            let stateful = byLabel.filter { $0.state != nil }
            if !stateful.isEmpty { byLabel = stateful }
        }
        if preferNativeControls, byLabel.count > 1 {
            let controls = byLabel.filter {
                $0.kind == .control && AccessibilityAugmentation.interactiveRoles.contains($0.role ?? "")
            }
            let onlyControlsAndCaptions = byLabel.allSatisfy {
                ($0.kind == .control && AccessibilityAugmentation.interactiveRoles.contains($0.role ?? ""))
                    || ($0.kind == .text && ($0.role == nil || $0.role == "AXStaticText"))
            }
            if !controls.isEmpty, onlyControlsAndCaptions { byLabel = controls }
        }
        // A copied "{context}" names the element's own context among same-named ones.
        if byLabel.count > 1, let context = LabelText.displayContext(target) {
            let inContext = byLabel.filter { $0.container?.caseInsensitiveCompare(context) == .orderedSame }
            if !inContext.isEmpty { byLabel = inContext }
        }
        byLabel = Self.collapseSameRow(byLabel)
        if byLabel.count == 1 { return .found(byLabel[0]) }
        return byLabel.isEmpty ? .none : .ambiguous(byLabel.count)
    }

    /// A label as compared: without bidi controls, and without the leading bullet a recognizer
    /// reads into a list row ("• carla_video_bn").
    private static func plain(_ label: String) -> String {
        let text = LabelText.withoutBidiControls(label)
        guard text.hasPrefix("\u{2022}") else { return text }
        return String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Resolves a section name exactly, or a decorative bar by role when exactly one bar matches.
    /// Content and sidebar names are never broadened: those may identify different panes.
    public func resolveSection(named query: String) -> SceneSection? {
        let exact = sections.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
        if exact.count == 1 { return exact[0] }
        func barRole(_ name: String) -> String? {
            let lower = name.lowercased()
            return ["top bar", "bottom bar"].first {
                lower == $0 || (lower.hasPrefix($0 + " (") && lower.hasSuffix(")"))
            }
        }
        guard let role = barRole(query) else { return nil }
        let matches = sections.filter { barRole($0.name) == role || $0.name.lowercased().hasPrefix(role + " #") }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The elements a target matches by label, for a disambiguation message that lists them.
    public func candidates(target: String) -> [SceneElement] {
        let identified = elements.filter { $0.id == target }
        if !identified.isEmpty { return identified }
        let exact = elements.filter { $0.label.caseInsensitiveCompare(target) == .orderedSame }
        if !exact.isEmpty { return exact }
        let cleaned = LabelText.strippingDisplayAnnotations(target)
        return elements.filter {
            LabelText.strippingDisplayAnnotations($0.label).caseInsensitiveCompare(cleaned) == .orderedSame
        }
    }

    /// One line listing each candidate's section (or exact id when unsectioned) and position.
    public func disambiguation(target: String, limit: Int = 6) -> String {
        candidates(target: target).prefix(limit).map { element in
            let position = String(format: "@%.2f,%.2f", element.bounds.x, element.bounds.y)
            let selector = (element.container ?? element.section).map { "section:'\($0)'" } ?? "id:'\(element.id)'"
            let role = element.role.map { " role:'\($0)'" } ?? ""
            return "\(selector) label:'\(element.label)'\(role) \(position)"
        }.joined(separator: " OR ")
    }

    /// Fuzzy search of the scene for a goal phrase, best first. Whole-token hits count 1, substring
    /// hits of four characters or more count 0.7, controls outrank prose. `stopwords` are the
    /// filler a caller strips from a spoken goal. Callers act only on a unique top scorer.
    public func grep(goal: String, stopwords: Set<String> = [], limit: Int = 5)
        -> [(element: SceneElement, score: Double)] {
        let content = LabelText.tokens(goal).filter { !stopwords.contains($0) }
        let query = (content.isEmpty ? LabelText.tokens(goal) : content)
            .map(LabelText.normalize)
            .filter { !$0.isEmpty }
        guard !query.isEmpty else { return [] }
        var scored: [(SceneElement, Double)] = []
        for element in elements where !element.isUnlabeled {
            let labelTokens = LabelText.tokens(element.label).map(LabelText.normalize)
            guard !labelTokens.isEmpty else { continue }
            var hits = 0.0
            for token in query {
                if labelTokens.contains(token) { hits += 1 }
                else if token.count >= 4, labelTokens.contains(where: { $0.contains(token) }) { hits += 0.7 }
            }
            guard hits > 0 else { continue }
            var score = hits / Double(query.count)
            if element.kind == .control { score += 0.1 }
            scored.append((element, score))
        }
        return Array(scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.label.count < $1.0.label.count }
            .prefix(limit))
    }

    /// Collapses the facets of one widget on one row (a row's text and its switch, an icon and its
    /// label, two detections of one button at nearly the same box) to the single actionable one.
    /// Duplicates in different rows are two real places and stay as they are.
    static func collapseSameRow(_ candidates: [SceneElement]) -> [SceneElement] {
        guard let first = candidates.first, candidates.count > 1 else { return candidates }
        let firstBox = first.bounds.cgRect
        func overlapFraction(_ box: CGRect) -> Double {
            let intersection = box.intersection(firstBox)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
            let smaller = min(box.width * box.height, firstBox.width * firstBox.height)
            return Double(intersection.width * intersection.height) / max(Double(smaller), 1e-9)
        }
        let overlappingDuplicates = candidates.dropFirst().allSatisfy { overlapFraction($0.bounds.cgRect) > 0.6 }
        if !overlappingDuplicates {
            let sameRow = candidates.dropFirst().allSatisfy { element in
                let box = element.bounds.cgRect
                let overlap = min(box.maxY, firstBox.maxY) - max(box.minY, firstBox.minY)
                return overlap > 0.5 * min(box.height, firstBox.height)
            }
            guard sameRow else { return candidates }
            // Two elements of one kind on one row are separate targets: two anonymous toolbar icons.
            guard Set(candidates.map(\.kind)).count == candidates.count else { return candidates }
        }
        func rank(_ element: SceneElement) -> Int {
            if element.state != nil { return 0 }
            switch element.kind {
                case .control: return 1
                case .icon   : return 2
                default      : return 3
            }
        }
        let ranked = candidates.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.bounds.x < b.bounds.x
        }
        return Array(ranked.prefix(1))
    }
}
