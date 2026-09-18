//
//  AccessibilityAugmentation.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation

/// AccessibilityAugmentation harvests the elements accessibility exposes cleanly and pixels mangle,
/// and merges them into a pixel-built scene. Pixels build the whole scene and the engine works with
/// no accessibility at all; this only ever adds.
///
/// Three harvests: the rows of tables, lists and outlines (a 30-track list OCR turned to mush while
/// the table held every name); focusable fields and pop-up buttons (a count field reading "1" is
/// "1"); and controls whose state pixels cannot read (an empty checkbox has nothing to segment, a
/// selected radio's dot misreads). A scrolling container clips its children, so a row a toolkit
/// reports at a virtual position outside its container is never emitted: it has no click target.
///
/// Generic over the tree reader, so the walk is decided by tests on a fake tree. The deadline is a
/// closure supplied by the caller: a reusable algorithm does not read the clock itself.
public enum AccessibilityAugmentation {

    /// Bounds on one walk. The deadline is asked before every node; a walk that runs out returns the
    /// rows read so far, which degrades to fewer labels, never to wrong ones.
    public struct Limits: Sendable {
        public var maxDepth: Int
        public var maxTables: Int
        public var maxElements: Int
        public var isPastDeadline: @Sendable () -> Bool

        public init(
            maxDepth      : Int = 10,
            maxTables     : Int = 24,
            maxElements   : Int = 400,
            isPastDeadline: @escaping @Sendable () -> Bool = { false }
        ) {
            self.maxDepth       = maxDepth
            self.maxTables      = maxTables
            self.maxElements    = maxElements
            self.isPastDeadline = isPastDeadline
        }
    }

    /// Roles whose accessibility answer is authoritative over a pixel guess: right state, right role,
    /// a real click target.
    public static let interactiveRoles: Set<String> = [
        "AXCheckBox", "AXRadioButton", "AXComboBox", "AXButton", "AXMenuButton", "AXTextField", "AXPopUpButton",
    ]

    private static let tableRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXGrid"]
    private static let clippingRoles: Set<String> = ["AXScrollArea", "AXList", "AXOutline", "AXTable", "AXGrid"]
    private static let statefulRoles: Set<String> = [
        "AXCheckBox", "AXRadioButton", "AXComboBox", "AXButton", "AXMenuButton",
    ]
    private static let placeholder = "missing value"

    // MARK: Harvest

    /// Walks one window's tree and returns the harvested elements, normalized to `windowFrame`.
    /// Duplicate labels take ordinals ("Track Name", "Track Name #2") so resolution stays unique.
    public static func elements<Reader: AccessibilityTreeReading>(
        under window: Reader.Node,
        windowFrame : CGRect,
        reader      : Reader,
        limits      : Limits = Limits()
    ) -> [SceneElement] {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return [] }
        var out: [SceneElement] = []
        var tables = 0

        func emit(_ frame: CGRect, role: String, label: String, state: ControlState?, clip: CGRect) {
            guard let bounds = AccessibilityFrameTrust.normalized(frame, in: windowFrame),
                  clip.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return }
            out.append(SceneElement(
                id    : SceneIdentity.key(kind: .control, label: label, bounds: bounds, isUnlabeled: false),
                kind  : .control,
                label : label,
                bounds: bounds,
                role  : role,
                state : state
            ))
        }

        func walk(_ node: Reader.Node, _ depth: Int, _ clip: CGRect) {
            guard depth < limits.maxDepth, tables < limits.maxTables, out.count < limits.maxElements,
                  !limits.isPastDeadline() else { return }
            let role = reader.role(node) ?? ""
            // A scrolling container tightens the clip and prunes a subtree entirely outside it. A plain
            // group also tightens (some toolkits scroll in groups) but is never trusted to prune.
            var childClip = clip
            if clippingRoles.contains(role), let frame = reader.frame(node), frame.width >= 8, frame.height >= 8 {
                let inner = clip.intersection(frame)
                guard !inner.isNull, inner.width >= 8, inner.height >= 8 else { return }
                childClip = inner
            } else if role == "AXGroup", let frame = reader.frame(node), frame.width >= 8, frame.height >= 8 {
                let inner = clip.intersection(frame)
                if !inner.isNull, inner.width >= 8, inner.height >= 8 { childClip = inner }
            }
            if tableRoles.contains(role) {
                tables += 1
                for row in reader.children(node) where reader.role(row) == "AXRow" {
                    if limits.isPastDeadline() { break }
                    if let rowFrame = reader.frame(row), rowFrame.height > 0, !childClip.intersects(rowFrame) {
                        continue
                    }
                    guard let named = deepestNamed(row, reader: reader, isPastDeadline: limits.isPastDeadline) else {
                        continue
                    }
                    let label = cleanLabel(named.name)
                    guard label.count >= 2, label.count <= 48 else { continue }
                    emit(named.frame, role: "AXRow", label: label, state: nil, clip: childClip)
                }
                return
            }
            if role == "AXTextField" || role == "AXPopUpButton", let frame = reader.frame(node) {
                let handle = firstText([reader.descriptionText(node), reader.title(node), reader.value(node)])
                if let handle, handle.count <= 48 { emit(frame, role: role, label: handle, state: nil, clip: clip) }
            }
            if statefulRoles.contains(role), let frame = reader.frame(node) {
                let title = firstText([reader.title(node), reader.descriptionText(node)])
                let value = firstText([reader.value(node)])
                var state: ControlState?
                if role == "AXCheckBox" || role == "AXRadioButton" {
                    switch reader.numericValue(node) {
                        case 1 : state = .on
                        case 0 : state = .off
                        case 2 : state = .mixed
                        default: break
                    }
                }
                if let label = title ?? value, label.count <= 48 {
                    emit(frame, role: role, label: label, state: state, clip: clip)
                }
            }
            for child in reader.children(node) { walk(child, depth + 1, childClip) }
        }
        walk(window, 0, windowFrame)

        var seen: [String: Int] = [:]
        for index in out.indices {
            let count = (seen[out[index].label] ?? 0) + 1
            seen[out[index].label] = count
            if count > 1 { out[index].label += " #\(count)" }
        }
        return out
    }

    // MARK: Merge

    /// Merges harvested elements into a pixel-built list. Additive: a harvested element is dropped only
    /// when a pixel element already carries the same core label at the same spot. An interactive
    /// harvest upgrades that pixel element in place, keeping its precise position and taking the
    /// authoritative role, state and clean name; a row harvest yields to the pixel element. Pixels
    /// are never removed.
    ///
    /// A harvested element is final once placed, whether it upgraded a pixel element or was appended
    /// as its own. Some toolkits expose one visual control twice (a panel tab is a radio button
    /// carrying the state and a combo box carrying the same title); the second facet matches the
    /// first and is redundant, so it is skipped rather than allowed to overwrite the state the first
    /// one brought. Measured live on Premiere's tab strip, both ways.
    public static func merge(pixels: [SceneElement], accessibility: [SceneElement]) -> [SceneElement] {
        guard !accessibility.isEmpty else { return pixels }
        var result = pixels
        var upgraded = Set<Int>()
        for element in accessibility {
            let core = LabelText.coreKey(strippingOrdinal(element.label))
            let isInteractive = interactiveRoles.contains(element.role ?? "")
            let match = core.isEmpty ? nil : result.firstIndex { existing in
                guard LabelText.coreKey(strippingOrdinal(existing.label)) == core else { return false }
                let center = existing.bounds.center
                let box = element.bounds
                let inside = center.x >= box.x - 0.01 && center.x <= box.maxX + 0.01
                    && center.y >= box.y - 0.01 && center.y <= box.maxY + 0.01
                let close = abs(center.x - box.midX) < 0.08 && abs(center.y - box.midY) < 0.04
                return inside || close
            }
            if let index = match {
                guard isInteractive, !upgraded.contains(index) else { continue }
                upgraded.insert(index)
                result[index].kind = .control
                result[index].role = element.role
                result[index].state = element.state
                result[index].label = element.label
                result[index].isUnlabeled = false
                if result[index].does == nil { result[index].does = element.does }
            } else {
                upgraded.insert(result.count)
                result.append(element)
            }
        }
        return result
    }

    // MARK: Names

    /// The most specific human name inside a row's subtree, with that node's frame. Some toolkits bury
    /// a row's name in a grandchild whose value reads "Audio 13 - Audio Track ".
    static func deepestNamed<Reader: AccessibilityTreeReading>(
        _ row         : Reader.Node,
        reader        : Reader,
        isPastDeadline: () -> Bool
    ) -> (name: String, frame: CGRect)? {
        let rowFrame = reader.frame(row)
        var best: (name: String, frame: CGRect)?
        func visit(_ node: Reader.Node, _ depth: Int) {
            if isPastDeadline() { return }
            for candidate in [reader.value(node), reader.title(node), reader.descriptionText(node)] {
                guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty, text != placeholder else { continue }
                let lower = text.lowercased()
                guard lower != "cell", lower != "button", lower != "row" else { continue }
                if text.count > (best?.name.count ?? 0), let frame = reader.frame(node) ?? rowFrame {
                    best = (text, frame)
                }
            }
            if depth < 4 { for child in reader.children(node) { visit(child, depth + 1) } }
        }
        visit(row, 0)
        return best
    }

    /// Trims the role suffix and state prefix some toolkits append ("Audio 13 - Audio Track ",
    /// "Shown. Audio 13") down to the name a person says.
    static func cleanLabel(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if let dash = text.range(of: " - ") { text = String(text[..<dash.lowerBound]) }
        for prefix in ["Shown. ", "Hidden. "] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Drops a trailing " #N" ordinal so a pixel label and its harvested twin still core-match.
    static func strippingOrdinal(_ label: String) -> String {
        guard let hash = label.range(of: " #", options: .backwards),
              hash.upperBound < label.endIndex,
              label[hash.upperBound...].allSatisfy(\.isNumber) else { return label }
        return String(label[..<hash.lowerBound])
    }

    private static func firstText(_ candidates: [String?]) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != placeholder }
    }
}
