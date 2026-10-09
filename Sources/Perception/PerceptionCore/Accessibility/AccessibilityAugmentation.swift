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
            maxDepth      : Int = 32,
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
    /// Web ranges require native field focus: an inactive browser field can report
    /// 0..0 while retaining another DOM selection. Native fields outside web content are unchanged.
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
                  selectedRange: NSRange? = nil,
                  kind: ElementKind = .control) {
            // Chrome reports offscreen controls as one-point edge frames.
            // Such slivers cannot supply a usable position or an observed value.
            let visible = frame.intersection(clip).intersection(windowFrame)
            guard (kind == .text ? staticText.count : out.count) < limits.maxElements,
                  visible.width >= 2, visible.height >= 2,
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
                selectedRange: selectedRange,
                isEnabled: isEnabled,
                container: container
            )
            if kind == .text { staticText.append(element) } else { out.append(element) }
        }

        func walk(_ node: Reader.Node, _ depth: Int, _ clip: CGRect, _ container: String?,
                  column: String? = nil, rowName: String? = nil, insideControl: Bool = false,
                  insideWebContent: Bool = false) {
            guard depth < limits.maxDepth, out.count < limits.maxElements,
                  !limits.isPastDeadline() else { return }
            let role = reader.role(node) ?? ""
            let webContent = insideWebContent || role == "AXWebArea"
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
                             rowName: label, insideControl: insideControl, insideWebContent: webContent)
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
                let rawValue = reader.value(node)
                // An unnamed empty native editor still has a measured role and frame.
                let anonymousHandle = role == "AXTextArea" ? "Text area" : "Text field"
                let handle = column ?? firstText([
                    reader.descriptionText(node), reader.title(node),
                    role == "AXTextArea" ? reader.identifier(node) : nil, rawValue
                ]) ?? (textEntryRoles.contains(role) ? anonymousHandle : nil)
                if let handle, handle.count <= 48, column != nil || rowName != cleanLabel(handle) {
                    emit(frame, role: role, label: handle, state: nil, clip: clip, container: container,
                         value: role == "AXPopUpButton" ? firstText([rawValue, reader.title(node)]) : rawValue,
                         isEnabled: reader.isEnabled(node),
                         selectedRange: textEntryRoles.contains(role)
                            && (!webContent || reader.isFocused(node) == true) ? reader.selectedRange(node) : nil)
                }
            }
            if statefulRoles.contains(role), let frame = reader.frame(node) {
                let title = column ?? firstText([reader.title(node), reader.descriptionText(node)])
                let rawValue = reader.value(node)
                let value = firstText([rawValue])
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
                         value: role == "AXComboBox" ? rawValue : (role == "AXMenuButton" ? value : nil),
                         isEnabled: reader.isEnabled(node),
                         selectedRange: role == "AXComboBox"
                            && (!webContent || reader.isFocused(node) == true) ? reader.selectedRange(node) : nil)
                }
            }
            for child in reader.children(node) {
                walk(child, depth + 1, childClip, childContainer, column: column, rowName: rowName,
                     insideControl: insideControl || interactiveRoles.contains(role) || role == "AXTextArea",
                     insideWebContent: webContent)
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

    /// Merges harvested elements into a pixel-built list. A harvested element is dropped only
    /// when a pixel element already carries the same core label or field value at the same spot. An interactive
    /// harvest upgrades that pixel element in place, keeping its precise position and taking the
    /// authoritative identity, role, state and clean name; a row harvest yields to the pixel element.
    ///
    /// A harvested name is cleaner than a pixel guess over the same widget, so it wins: a static text
    /// takes the label of the pixel text it matches, and a placed non-row, non-field element removes the
    /// unlabeled icons and the lone pixel text it covers. A pixel row that merely contains a harvested
    /// name keeps the rest of its text. Pixels stay wherever accessibility has nothing to say.
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
        var removed = Set<Int>()

        // Pixel elements over the same widget as `element`, other than the one it matched.
        func absorb(_ element: SceneElement, matched: Int?) {
            guard element.role != "AXRow", !textEntryRoles.contains(element.role ?? "") else { return }
            let box = element.bounds
            let label = strippingOrdinal(element.label)
            var captions: [Int] = []
            for index in result.indices where index != matched && !upgraded.contains(index)
                && !removed.contains(index) {
                let pixel = result[index]
                let shared = pixel.bounds.cgRect.intersection(box.cgRect)
                guard !shared.isNull, shared.width * shared.height > 0 else { continue }
                let covered = Double(shared.width * shared.height)
                if pixel.kind == .icon, pixel.isUnlabeled {
                    // A name is not claimed for a glyph inside something much taller than the glyph.
                    if covered > 0.6 * pixel.bounds.area, box.height <= 2.5 * pixel.bounds.height {
                        removed.insert(index)
                    }
                } else if pixel.kind == .text, pixel.role == nil {
                    // A name found as whole words inside a longer pixel row shortens that row.
                    if covered > 0.4 * min(box.area, pixel.bounds.area), label.count >= 2,
                       LabelText.isNameworthy(label), pixel.label.count > label.count,
                       let range = pixel.label.range(of: label, options: [.caseInsensitive, .diacriticInsensitive]),
                       !(pixel.label[..<range.lowerBound].last.map { $0.isLetter || $0.isNumber } ?? false),
                       !(pixel.label[range.upperBound...].first.map { $0.isLetter || $0.isNumber } ?? false) {
                        let before = pixel.label[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                        let after = pixel.label[range.upperBound...].trimmingCharacters(in: .whitespaces)
                        let rest = (before + " " + after).trimmingCharacters(in: .whitespaces)
                        guard LabelText.tokens(rest).contains(where: { $0.count >= 2 }) else {
                            removed.insert(index)
                            continue
                        }
                        // Only one end can be cut from the row's box; a name in the middle keeps it whole.
                        var bounds = pixel.bounds
                        if after.isEmpty, box.x > bounds.x {
                            bounds.width = box.x - bounds.x
                        } else if before.isEmpty, box.maxX < bounds.maxX {
                            bounds.width = bounds.maxX - box.maxX
                            bounds.x = box.maxX
                        }
                        result[index].label = rest
                        result[index].bounds = bounds
                        result[index].id = SceneIdentity.key(
                            kind       : .text,
                            label      : rest,
                            bounds     : bounds,
                            isUnlabeled: false
                        )
                        coreKeys[index] = LabelText.coreKey(strippingOrdinal(rest))
                        valueKeys[index] = LabelText.coreKey(rest)
                    } else if covered > 0.6 * pixel.bounds.area {
                        captions.append(index)
                    }
                }
            }
            // One pixel text inside the widget is its caption, however it was misread.
            if captions.count == 1, box.area <= 8 * result[captions[0]].bounds.area { removed.insert(captions[0]) }
        }

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
                // A static text names the same words more cleanly than a recognizer that fused a glyph into them.
                if !isInteractive, !upgraded.contains(index), element.kind == .text,
                   result[index].kind == .text, result[index].role == nil,
                   result[index].label != strippingOrdinal(element.label) {
                    upgraded.insert(index)
                    result[index].id = element.id
                    result[index].role = element.role
                    result[index].value = element.value
                    result[index].container = element.container
                    result[index].label = element.label
                    coreKeys[index] = core
                    valueKeys[index] = LabelText.coreKey(element.label)
                    continue
                }
                absorb(element, matched: index)
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
                result[index].selectedRange = element.selectedRange
                result[index].isEnabled = element.isEnabled
                result[index].container = element.container
                result[index].label = element.label
                coreKeys[index] = core
                valueKeys[index] = LabelText.coreKey(element.label)
                result[index].isUnlabeled = false
                if result[index].does == nil { result[index].does = element.does }
            } else {
                absorb(element, matched: nil)
                upgraded.insert(result.count)
                result.append(element)
                coreKeys.append(core)
                valueKeys.append(LabelText.coreKey(element.label))
            }
        }
        return result.indices.filter { !removed.contains($0) }.map { result[$0] }
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
