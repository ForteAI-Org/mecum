//
//  SceneChanges.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 06/10/2026.
//

import Foundation

/// SceneChanges writes what changed between two scenes of one window, for a reader that holds the
/// first: each element added in full, each removed one short, each changed one with its earlier
/// values, under the section it is in now, and the header facts that moved.
///
/// Elements are matched by identity, never by line. A labeled element is its id (kind and normalized
/// label); among duplicates the same role pairs first, then the nearest place, and a caption that
/// grouping turned into a control, or back, in place is the same element of another kind. An
/// unlabeled element, whose id is only a grid cell, is the nearest one of its kind within `nearby`.
/// What the reader neither sees differently nor targets with is no change: a new order, a move within
/// `nearby`, a learned group tag, panels that moved within `nearby`, or a section renamed or redrawn
/// around an element that stayed as it was. An element now in another section while its old section
/// is still there has changed, because a target names its section. The lines are `text()`'s own, so
/// the reader keeps one vocabulary.
///
/// Pure and deterministic over two scenes. `SceneDifference` names one event's effect for memory;
/// this is the reader's update, and it lives beside the renderer whose lines it repeats.
public enum SceneChanges {

    /// How far an element or a panel edge may move, in window-normalized units on either axis, and
    /// still be where it was: twice the hundredth a position is printed to, so it barely shows.
    static let nearby = 0.02

    /// The changes from `before` to `after`, or the one line that says there are none. `revision` is
    /// the number the reader knows `before` by.
    public static func text(from before: SceneSnapshot, to after: SceneSnapshot, since revision: Int) -> String {
        var header: [String] = []
        if before.header() != after.header() { header.append(after.header()) }
        if before.viewportPixelSize != after.viewportPixelSize {
            header.append("viewport: \(after.viewportPixelSize.width)x\(after.viewportPixelSize.height)\n")
        }
        let sectionsChanged = !sameLayout(before, after)
        let sectionNames = Set(after.sections.map(\.name))

        var reported: [Line] = []
        var matchedBefore = Set<Int>()
        var matchedAfter  = Set<Int>()
        for (old, new) in pairs(before.elements, after.elements) {
            matchedBefore.insert(old)
            matchedAfter.insert(new)
            let was = earlier(before.elements[old], after.elements[new], sections: sectionNames)
            guard !was.isEmpty else { continue }
            reported.append(Line(
                section: placed(after.elements[new].section, in: after),
                bounds : after.elements[new].bounds,
                text   : "~ " + line(after.elements[new]) + "  (was " + was.joined(separator: ", ") + ")"
            ))
        }
        for (index, element) in after.elements.enumerated() where !matchedAfter.contains(index) {
            reported.append(Line(
                section: placed(element.section, in: after),
                bounds : element.bounds,
                text   : "+ " + line(element)
            ))
        }
        for (index, element) in before.elements.enumerated() where !matchedBefore.contains(index) {
            reported.append(Line(
                section: after.section(at: element.bounds.center)?.name,
                bounds : element.bounds,
                text   : "- " + short(element)
            ))
        }

        var body: [String] = []
        let groups = Dictionary(grouping: reported, by: \.section)
        func append(_ lines: [Line]) {
            let ordered = SceneSnapshot.readingOrder(
                lines,
                rowTolerance: after.rowTolerance,
                bounds      : \.bounds,
                tieBreak    : \.text
            )
            body += ordered.map { "  " + $0.text + "\n" }
        }
        if after.sections.isEmpty {
            if sectionsChanged { body.append("elements (\(after.elements.count)):\n") }
            append(groups[String?.none] ?? [])
        } else {
            for section in after.sectionsInReadingOrder {
                let lines = groups[section.name] ?? []
                guard sectionsChanged || !lines.isEmpty else { continue }
                let count = after.elements.filter { $0.section == section.name }.count
                body.append(after.sectionLine(section, count: count))
                append(lines)
            }
            if let loose = groups[String?.none], !loose.isEmpty {
                body.append("Unsectioned: \(after.elements.filter { $0.section == nil }.count) elements\n")
                append(loose)
            }
        }
        if before.commands != after.commands {
            body.append(after.commands.isEmpty ? "commands: none\n" : after.commandsLine())
        }
        guard !header.isEmpty || !body.isEmpty else { return "Unchanged since revision \(revision)." }
        let opening = "Changes since revision \(revision): + added, - removed, ~ changed (was earlier values), "
            + "each under its section line; the rest is unchanged.\n"
        return (opening + header.joined() + body.joined()).trimmingCharacters(in: .newlines)
    }

    /// One reported element: the section it is listed under, nil for none, and where it is.
    private struct Line {
        let section: String?
        let bounds: NormalizedRect
        let text: String
    }

    /// The pairs of indices, before and after, that are one element, closest first. A labeled element
    /// pairs with its own id, the same role first; failing that, with its label read as another kind
    /// within `nearby`, which is grouping that fused or split a caption. An unlabeled element pairs
    /// only with its kind within `nearby`.
    private static func pairs(_ before: [SceneElement], _ after: [SceneElement]) -> [(Int, Int)] {
        let byIdentity = Dictionary(grouping: after.indices, by: { identity(after[$0]) })
        let byLabel = Dictionary(
            grouping: after.indices.filter { !isPositional(after[$0]) },
            by      : { LabelText.normalize(after[$0].label) }
        )
        var candidates: [(rank: Int, distance: Double, old: Int, new: Int)] = []
        for (old, element) in before.enumerated() {
            func distance(to new: Int) -> (dx: Double, dy: Double) {
                (abs(element.bounds.midX - after[new].bounds.midX), abs(element.bounds.midY - after[new].bounds.midY))
            }
            for new in byIdentity[identity(element)] ?? [] {
                let (dx, dy) = distance(to: new)
                if isPositional(element), dx > nearby || dy > nearby { continue }
                candidates.append((element.role == after[new].role ? 0 : 1, dx + dy, old, new))
            }
            guard !isPositional(element) else { continue }
            for new in byLabel[LabelText.normalize(element.label)] ?? [] where after[new].kind != element.kind {
                let (dx, dy) = distance(to: new)
                if dx <= nearby, dy <= nearby { candidates.append((2, dx + dy, old, new)) }
            }
        }
        candidates.sort { ($0.rank, $0.distance, $0.old, $0.new) < ($1.rank, $1.distance, $1.old, $1.new) }
        var takenBefore = Set<Int>()
        var takenAfter  = Set<Int>()
        var pairs: [(Int, Int)] = []
        for candidate in candidates where !takenBefore.contains(candidate.old) && !takenAfter.contains(candidate.new) {
            takenBefore.insert(candidate.old)
            takenAfter.insert(candidate.new)
            pairs.append((candidate.old, candidate.new))
        }
        return pairs
    }

    /// What one element is across two readings: its id, or its kind when the id is only a place.
    private static func identity(_ element: SceneElement) -> String {
        isPositional(element) ? "@" + element.kind.rawValue : element.id
    }

    /// True when the element's id is a grid cell (`SceneIdentity`) and names no thing.
    private static func isPositional(_ element: SceneElement) -> Bool {
        element.isUnlabeled || element.id.hasPrefix("?|@")
    }

    /// The earlier values of everything the reader sees or targets differently in `new`, in line
    /// order, then its section; empty when it is the same element in the same place. A group tag is
    /// left out, since no target names it, and so is a section no longer among `sections`: a renamed
    /// or redrawn panel is reported once, in its own line.
    private static func earlier(_ old: SceneElement, _ new: SceneElement, sections: Set<String>) -> [String] {
        var was: [String] = []
        if tag(old) != tag(new) { was.append("[\(tag(old))]") }
        if old.label != new.label { was.append("label \(String(reflecting: old.label))") }
        if shownID(old) != shownID(new) { was.append(shownID(old).map { "id:'\($0)'" } ?? "no id") }
        if old.state != new.state { was.append(old.state.map { "[\($0.rawValue)]" } ?? "no state") }
        if shownValue(old) != shownValue(new) {
            was.append(shownValue(old).map { "= \(String(reflecting: $0))" } ?? "no value")
        }
        let oldRange = SceneElement.validRange(old.selectedRange, value: old.value)
        if oldRange != SceneElement.validRange(new.selectedRange, value: new.value) {
            was.append(oldRange.map { "selection \($0.location)..\($0.location + $0.length)" } ?? "no selection")
        }
        if (old.isEnabled == false) != (new.isEnabled == false) {
            was.append(old.isEnabled == false ? "[disabled]" : "enabled")
        }
        if old.container != new.container { was.append(old.container.map { "{\($0)}" } ?? "no container") }
        if old.does != new.does { was.append(old.does.map { ": \($0)" } ?? "no learned effect") }
        if abs(old.bounds.midX - new.bounds.midX) > nearby || abs(old.bounds.midY - new.bounds.midY) > nearby {
            was.append(String(format: "@ %.2f,%.2f", old.bounds.x, old.bounds.y))
        }
        if let section = old.section, section != new.section, sections.contains(section) {
            was.append("in \(section)")
        }
        return was
    }

    /// `text()`'s line for one element, without its indent and line break.
    private static func line(_ element: SceneElement) -> String {
        String(SceneSnapshot.elementLine(element, indent: "").dropLast())
    }

    /// A removed element as the reader can still tell it apart: its tag, label, shown id and place.
    private static func short(_ element: SceneElement) -> String {
        let identity = shownID(element).map { " id:'\($0)'" } ?? ""
        let position = String(format: "%.2f,%.2f", element.bounds.x, element.bounds.y)
        return "[\(tag(element))] \(element.label)\(identity)  @ \(position)"
    }

    /// The tag `text()` prints: `field` for text entry, a kind with `?` when unlabeled, else the kind.
    private static func tag(_ element: SceneElement) -> String {
        if AccessibilityAugmentation.textEntryRoles.contains(element.role ?? "") { return "field" }
        return element.isUnlabeled ? "\(element.kind.rawValue)?" : element.kind.rawValue
    }

    /// The id `text()` prints, which a target can name: an unlabeled element's or a field's.
    private static func shownID(_ element: SceneElement) -> String? {
        element.isUnlabeled || tag(element) == "field" ? element.id : nil
    }

    /// The value `text()` prints: none when it repeats the label.
    private static func shownValue(_ element: SceneElement) -> String? {
        element.value == element.label ? nil : element.value
    }

    /// The section an element is listed under in `scene`: its own, when the scene prints that one.
    private static func placed(_ section: String?, in scene: SceneSnapshot) -> String? {
        guard let section, scene.sections.contains(where: { $0.name == section }) else { return nil }
        return section
    }

    /// True when both scenes have the same sections in the same order, with the same scroll notes and
    /// bounds within `nearby`: a panel edge that moves less is the seam's jitter, not a new layout.
    private static func sameLayout(_ before: SceneSnapshot, _ after: SceneSnapshot) -> Bool {
        let old = before.sectionsInReadingOrder
        let new = after.sectionsInReadingOrder
        guard old.count == new.count else { return false }
        return zip(old, new).allSatisfy { old, new in
            old.name == new.name
                && old.verticalScrollNote == new.verticalScrollNote
                && old.horizontalScrollNote == new.horizontalScrollNote
                && zip(old.bounds.array, new.bounds.array).allSatisfy { abs($0 - $1) <= nearby }
        }
    }
}
