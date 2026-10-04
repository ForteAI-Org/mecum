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
            maxDepth      : Int = 16,
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
        "AXCheckBox", "AXRadioButton", "AXComboBox", "AXButton", "AXMenuButton", "AXTextField", "AXTextArea", "AXPopUpButton",
    ]

    /// Native roles that accept text. A pixel-inferred control does not establish this fact.
    public static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    private static let tableRoles: Set<String> = ["AXTable", "AXOutline", "AXList", "AXGrid"]
    private static let clippingRoles: Set<String> = ["AXScrollArea", "AXList", "AXOutline", "AXTable", "AXGrid"]
    private static let statefulRoles: Set<String> = [
        "AXCheckBox", "AXRadioButton", "AXComboBox", "AXButton", "AXMenuButton",
    ]
    private static let placeholder = "missing value"

    // MARK: Harvest

    /// Walks one window's tree and returns the harvested elements, normalized to `windowFrame`.
    /// Preserves named container paths, field values and availability. Short native static values
    /// fill OCR gaps as text, after controls have taken their share of the element budget.
    /// Duplicate labels within the same container take ordinals; labels in different containers
    /// remain independently addressable.
    public static func elements<Reader: AccessibilityTreeReading>(
        under window: Reader.Node,
        windowFrame : CGRect,
        reader      : Reader,
        limits      : Limits = Limits()
    ) -> [SceneElement] {
        guard windowFrame.width > 0, windowFrame.height > 0 else { return [] }
        var out: [SceneElement] = []
        var staticText: [SceneElement] = []
        var tables = 0

        func emit(_ frame: CGRect, role: String, label: String, state: ControlState?, clip: CGRect,
                  container: String?, value: String? = nil, isEnabled: Bool? = nil,
                  kind: ElementKind = .control) {
            guard (kind == .text ? staticText.count : out.count) < limits.maxElements,
                  let bounds = AccessibilityFrameTrust.normalized(frame, in: windowFrame),
                  clip.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return }
            let element = SceneElement(
                id    : SceneIdentity.key(kind: kind, label: label, bounds: bounds, isUnlabeled: false),
                kind  : kind,
                label : label,
                bounds: bounds,
                role  : role,
                state : state,
                value : value,
                isEnabled: isEnabled,
                container: container
            )
            if kind == .text { staticText.append(element) } else { out.append(element) }
        }

        func walk(_ node: Reader.Node, _ depth: Int, _ clip: CGRect, _ container: String?,
                  column: String? = nil, rowName: String? = nil, insideControl: Bool = false) {
            guard depth < limits.maxDepth, out.count < limits.maxElements,
                  !limits.isPastDeadline() else { return }
            let role = reader.role(node) ?? ""
            var childContainer = container
            if role == "AXGroup" || tableRoles.contains(role),
               let name = firstText([reader.title(node), reader.descriptionText(node)]),
               !name.hasPrefix("UI_"), name.count <= 80 {
                let clean = cleanLabel(name)
                childContainer = container.map { $0 + " / " + clean } ?? clean
            }
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
                guard tables < limits.maxTables else { return }
                tables += 1
                let children = reader.children(node)
                let columns = children.filter { reader.role($0) == "AXColumn" }.map {
                    firstText([reader.title($0), reader.descriptionText($0)])
                }
                for row in children where reader.role(row) == "AXRow" {
                    if out.count >= limits.maxElements || limits.isPastDeadline() { break }
                    if let rowFrame = reader.frame(row), rowFrame.height > 0, !childClip.intersects(rowFrame) {
                        continue
                    }
                    guard let named = deepestNamed(row, reader: reader, isPastDeadline: limits.isPastDeadline) else {
                        continue
                    }
                    let label = cleanLabel(named.name)
                    guard label.count >= 2, label.count <= 48 else { continue }
                    emit(named.frame, role: "AXRow", label: label, state: nil, clip: childClip,
                         container: childContainer, isEnabled: reader.isEnabled(row))
                    let owner = childContainer.map { $0 + " / " + label } ?? label
                    let cells = reader.children(row)
                    // Only use column order when the table exposes a complete cell-to-column map.
                    // Otherwise traverse the controls with their own labels and row context.
                    let aligned = cells.count == columns.count && cells.allSatisfy { reader.role($0) == "AXCell" }
                    for (index, cell) in cells.enumerated() {
                        walk(cell, depth + 2, childClip, owner, column: aligned ? columns[index] : nil,
                             rowName: label, insideControl: insideControl)
                    }
                }
                return
            }
            if role == "AXStaticText", !insideControl, let frame = reader.frame(node) {
                let value = reader.value(node)
                if let label = firstText([value, reader.title(node)]), label.count <= 48,
                   rowName != cleanLabel(label) {
                    emit(frame, role: role, label: label, state: nil, clip: clip, container: container,
                         value: value, kind: .text)
                }
            }
            if role == "AXTextField" || role == "AXTextArea" || role == "AXPopUpButton", let frame = reader.frame(node) {
                let handle = column ?? firstText([
                    reader.descriptionText(node), reader.title(node),
                    role == "AXTextArea" ? reader.identifier(node) : nil, reader.value(node)
                ])
                if let handle, handle.count <= 48, column != nil || rowName != cleanLabel(handle) {
                    emit(frame, role: role, label: handle, state: nil, clip: clip, container: container,
                         value: firstText([reader.value(node), role == "AXPopUpButton" ? reader.title(node) : nil]),
                         isEnabled: reader.isEnabled(node))
                }
            }
            if statefulRoles.contains(role), let frame = reader.frame(node) {
                let title = column ?? firstText([reader.title(node), reader.descriptionText(node)])
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
                if let label = title ?? value, label.count <= 48, column != nil || rowName != cleanLabel(label) {
                    emit(frame, role: role, label: label, state: state, clip: clip, container: container,
                         value: role == "AXComboBox" || role == "AXMenuButton" ? value : nil,
                         isEnabled: reader.isEnabled(node))
                }
            }
            for child in reader.children(node) {
                walk(child, depth + 1, childClip, childContainer, column: column, rowName: rowName,
                     insideControl: insideControl || interactiveRoles.contains(role) || role == "AXTextArea")
            }
        }
        walk(window, 0, windowFrame, nil)
        out.append(contentsOf: staticText.prefix(max(0, limits.maxElements - out.count)))

        var seen: [String: Int] = [:]
        for index in out.indices {
            let key = out[index].kind.rawValue + "\n" + (out[index].container ?? "") + "\n" + out[index].label
            let count = (seen[key] ?? 0) + 1
            seen[key] = count
            if count > 1 { out[index].label += " #\(count)" }
        }
        return out
    }

    // MARK: Merge

    /// Merges harvested elements into a pixel-built list. Additive: a harvested element is dropped only
    /// when a pixel element already carries the same core label or field value at the same spot. An interactive
    /// harvest upgrades that pixel element in place, keeping its precise position and taking the
    /// authoritative identity, role, state and clean name; a row harvest yields to the pixel element. Pixels
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
        // Normalize once per label, then update alongside upgrades and appends. Re-tokenizing
        // every candidate for every native element makes dense scenes needlessly quadratic in text work.
        var coreKeys = pixels.map { LabelText.coreKey(strippingOrdinal($0.label)) }
        var valueKeys = pixels.map { LabelText.coreKey($0.label) }
        var upgraded = Set<Int>()
        for element in accessibility {
            let core = LabelText.coreKey(strippingOrdinal(element.label))
            let isInteractive = interactiveRoles.contains(element.role ?? "")
            // Duplicate evidence must overlap the same widget. Window-relative distance thresholds
            // collapse neighboring mixer buttons and bind dense list rows to the preceding row.
            var match = core.isEmpty ? nil : result.indices
                .filter { coreKeys[$0] == core }
                .map { ($0, overlap(result[$0].bounds, element.bounds)) }
                .filter { $0.1 > 0.6 }
                .max { $0.1 < $1.1 }?.0
            if match == nil, let value = element.value,
               ["AXTextField", "AXPopUpButton", "AXComboBox", "AXMenuButton"].contains(element.role ?? "") {
                let valueKey = LabelText.coreKey(value)
                let candidates = result.indices.filter {
                    result[$0].role == nil && result[$0].kind == .text && !valueKey.isEmpty
                        && valueKeys[$0] == valueKey
                        && overlap(result[$0].bounds, element.bounds) > 0.6
                }
                if candidates.count == 1 { match = candidates.first }
            }
            if let index = match {
                if result[index].container == nil { result[index].container = element.container }
                if result[index].isEnabled == nil { result[index].isEnabled = element.isEnabled }
                if result[index].value == nil { result[index].value = element.value }
                guard isInteractive, !upgraded.contains(index) else { continue }
                upgraded.insert(index)
                result[index].kind = .control
                result[index].id = element.id
                result[index].role = element.role
                result[index].state = element.state
                result[index].value = element.value
                result[index].isEnabled = element.isEnabled
                result[index].container = element.container
                result[index].label = element.label
                coreKeys[index] = core
                valueKeys[index] = LabelText.coreKey(element.label)
                result[index].isUnlabeled = false
                if result[index].does == nil { result[index].does = element.does }
            } else {
                upgraded.insert(result.count)
                result.append(element)
                coreKeys.append(core)
                valueKeys.append(LabelText.coreKey(element.label))
            }
        }
        return result
    }

    private static func overlap(_ first: NormalizedRect, _ second: NormalizedRect) -> Double {
        let intersection = first.cgRect.intersection(second.cgRect)
        let smaller = min(first.area, second.area)
        guard !intersection.isNull, smaller > 0 else { return 0 }
        return Double(intersection.width * intersection.height) / smaller
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
        let roleSuffix = " - Audio Track"
        if text.hasSuffix(roleSuffix) { text = String(text.dropLast(roleSuffix.count)) }
        for prefix in ["Shown. ", "Hidden. ", "Selected. ", "Active. ", "Inactive. "] where text.hasPrefix(prefix) {
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
