//
//  SceneTargetReference.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 28/09/2026.
//

import Foundation

/// SceneTargetReference reads a target a model copied from a scene line back into what the line
/// shows: the element's label, the value rendered after " = ", and the container rendered in braces.
/// A model reads `Mute {Track 2}` or `stile = Regolare` in the text map and passes it as it reads
/// it; the label alone is what resolution matches, and the container is the panel that told two
/// same-named controls apart. Text that carries none of the rendering's marks is its own label.
///
/// It reverses `SceneRendering`'s element line: label, a control state in brackets, " = value",
/// " [disabled]", " {container}", a " (group#N)" occurrence tag, " ~recalled" and the "  @ x,y"
/// position. Only those marks are read: a label's own parentheses, as in "Save (Recommended)", and
/// brackets that hold no control state stay part of the label, and so does any mark of a label the
/// scene shows.
public struct SceneTargetReference: Sendable, Equatable {

    /// The element's label, as resolution matches it.
    public let label: String

    /// The value the line rendered after " = ", when it rendered one.
    public let value: String?

    /// The container the line rendered in braces, when it rendered one.
    public let container: String?

    public init(label: String, value: String? = nil, container: String? = nil) {
        self.label     = label
        self.value     = value
        self.container = container
    }

    /// Reads `rendered`, a target as a model passed it. `shownLabels` are the labels of the scene the
    /// model read, normalized as `LabelText.normalize` does: reading stops at the first stage whose text
    /// is one of them, so a real label that holds a rendering mark, as "x = y" or "Mix {A}", is kept
    /// whole. Without them every mark is read.
    public init(parsing rendered: String, shownLabels: Set<String> = []) {
        let whole = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = whole
        var value: String?
        var container: String?
        func isShown() -> Bool { shownLabels.contains(LabelText.normalize(text)) }
        let stages: [(inout String) -> Void] = [
            { text in
                if let position = text.range(of: "  @ ", options: .backwards) {
                    text = String(text[..<position.lowerBound])
                }
            },
            { text in Self.dropSuffix(" ~recalled", from: &text) },
            { text in while Self.dropGroup(from: &text) {} },
            { text in container = Self.dropEnclosed(open: " {", close: "}", from: &text) },
            { text in Self.dropSuffix(" [disabled]", from: &text) },
            { text in
                if let equals = text.range(of: " = ", options: .backwards) {
                    let rest = text[equals.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty {
                        value = rest
                        text = String(text[..<equals.lowerBound])
                    }
                }
            },
            { text in
                if let state = Self.dropEnclosed(open: " [", close: "]", from: &text),
                   ControlState(rawValue: state) == nil {
                    text += " [\(state)]"
                }
            },
            { text in
                if let identity = text.range(of: " id:'", options: .backwards), text.hasSuffix("'") {
                    text = String(text[..<identity.lowerBound])
                }
            },
        ]
        for stage in stages where !isShown() { stage(&text) }
        let label = text.trimmingCharacters(in: .whitespaces)
        self.init(label: label.isEmpty ? whole : label, value: value, container: container)
    }

    /// Whether the text read anything beyond its label.
    public var isDecorated: Bool { value != nil || container != nil }

    /// Removes a trailing occurrence tag, " (row#2)" or " (INSERTS A-E#1)", the only parentheses
    /// the rendering adds; a label's own parentheses carry no "#N".
    private static func dropGroup(from text: inout String) -> Bool {
        var probe = text
        guard let inner = dropEnclosed(open: " (", close: ")", from: &probe),
              let hash = inner.lastIndex(of: "#"), inner.index(after: hash) < inner.endIndex,
              inner[inner.index(after: hash)...].allSatisfy(\.isNumber) else { return false }
        text = probe
        return true
    }

    private static func dropSuffix(_ suffix: String, from text: inout String) {
        if text.hasSuffix(suffix) { text.removeLast(suffix.count) }
    }

    /// Removes a trailing `open…close` part and returns what it held, or nil when the text does not
    /// end with one.
    private static func dropEnclosed(open: String, close: String, from text: inout String) -> String? {
        guard text.hasSuffix(close), let start = text.range(of: open, options: .backwards) else { return nil }
        let inner = String(text[start.upperBound..<text.index(text.endIndex, offsetBy: -close.count)])
        guard !inner.isEmpty, !inner.contains(close) else { return nil }
        text = String(text[..<start.lowerBound])
        return inner
    }
}
