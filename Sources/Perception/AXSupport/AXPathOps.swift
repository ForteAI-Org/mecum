import Foundation
import CoreGraphics
import LocatorCore

/// Outcome of a path replay, with enough detail to debug a deep failure instead of a bare `nil`.
public enum AXReplayOutcome<Element> {
    case resolved(Element)
    /// No child of the required `role` existed at path step `depth` (descent diverged or the tree changed).
    case noCandidates(depth: Int, role: String)
    /// Reached the leaf's level but no same-role candidate satisfied the captured leaf attrs.
    case leafAttrMismatch(depth: Int)
    case emptyPath

    /// Shift reported depths so they line up with the ORIGINAL path indices after a prefix was peeled off.
    public func offsettingDepth(by n: Int) -> AXReplayOutcome {
        switch self {
        case .noCandidates(let d, let r): return .noCandidates(depth: d + n, role: r)
        case .leafAttrMismatch(let d): return .leafAttrMismatch(depth: d + n)
        case .resolved, .emptyPath: return self
        }
    }

    public var element: Element? {
        if case .resolved(let e) = self { return e }
        return nil
    }
}

/// Pure AX-tree algorithms, generic over an ``AXTreeReading`` so they run identically against the
/// live `AXUIElement` tree and against a fake test tree.
///
/// Design notes carried from the spec:
/// - A path step's `index` is the index among **same-role** siblings (not absolute child index) —
///   far more stable across reordering.
/// - Capture stores both `title` and `descriptionText`; matching accepts a hit if **either** matches
///   (Logic Pro leaves `title` empty and labels via `kAXDescriptionAttribute`; Pro Tools is mixed).
/// - On replay, candidate selection prefers an identity match (identifier → title → description) and
///   only falls back to `index`, so descent survives same-role reordering at every level. At the leaf,
///   if the index-selected element's attrs mismatch, we search the same-role siblings for an attr match.
public enum AXPathOps {

    public static let windowRole = "AXWindow"

    // MARK: Capture

    /// Walk leaf → window, emitting one step per hop, returned root(window) → leaf.
    public static func capturePath<R: AXTreeReading>(from leaf: R.Element, reader: R) -> [AXPathStep] {
        var steps: [AXPathStep] = []
        var current: R.Element? = leaf
        var guardDepth = 0
        while let node = current, guardDepth < 256 {
            guardDepth += 1
            let role = reader.role(node) ?? "AXUnknown"
            steps.append(AXPathStep(
                role: role,
                title: reader.title(node),
                identifier: reader.identifier(node),
                descriptionText: reader.descriptionText(node),
                index: sameRoleSiblingIndex(of: node, reader: reader),
                siblingContext: siblingContext(of: node, reader: reader)
            ))
            if role == windowRole { break }   // window is the top of the path
            current = reader.parent(node)
        }
        return steps.reversed()
    }

    /// Index of `node` among its parent's children of the **same role**. `nil` if no parent.
    public static func sameRoleSiblingIndex<R: AXTreeReading>(of node: R.Element, reader: R) -> Int? {
        guard let parent = reader.parent(node) else { return nil }
        let role = reader.role(node)
        let sameRole = reader.children(parent).filter { reader.role($0) == role }
        return sameRole.firstIndex { reader.isEqual($0, node) }
    }

    /// Titles of the immediately-adjacent siblings (in full child order), to disambiguate after reorder.
    public static func siblingContext<R: AXTreeReading>(of node: R.Element, reader: R) -> SiblingContext? {
        guard let parent = reader.parent(node) else { return nil }
        let siblings = reader.children(parent)
        guard let i = siblings.firstIndex(where: { reader.isEqual($0, node) }) else { return nil }
        let prev = i > 0 ? reader.title(siblings[i - 1]) : nil
        let next = i < siblings.count - 1 ? reader.title(siblings[i + 1]) : nil
        guard prev != nil || next != nil else { return nil }
        return SiblingContext(prevTitle: prev, nextTitle: next)
    }

    /// Snapshot the leaf's matchable attributes.
    public static func leafAttrs<R: AXTreeReading>(of e: R.Element, reader: R) -> AXLeafAttrs {
        AXLeafAttrs(
            role: reader.role(e) ?? "AXUnknown",
            title: reader.title(e),
            descriptionText: reader.descriptionText(e),
            enabled: reader.enabled(e),
            actions: reader.actions(e)
        )
    }

    // MARK: Replay

    /// Replay a captured path starting at `root` (the application element). Returns the live element,
    /// or `nil` if the path can't be resolved. `leafAttrs`, when supplied, gates leaf acceptance and
    /// drives the same-role cousin search on mismatch.
    public static func replayPath<R: AXTreeReading>(
        _ path: [AXPathStep],
        root: R.Element,
        leafAttrs: AXLeafAttrs? = nil,
        reader: R
    ) -> R.Element? {
        replayPathDiagnostic(path, root: root, leafAttrs: leafAttrs, reader: reader).element
    }

    /// Replay, reporting *where* it failed (which step, why) for debuggability on deep trees.
    public static func replayPathDiagnostic<R: AXTreeReading>(
        _ path: [AXPathStep],
        root: R.Element,
        leafAttrs: AXLeafAttrs? = nil,
        reader: R
    ) -> AXReplayOutcome<R.Element> {
        guard !path.isEmpty else { return .emptyPath }
        var current = root
        for (i, step) in path.enumerated() {
            let candidates = reader.children(current).filter { reader.role($0) == step.role }
            guard !candidates.isEmpty else { return .noCandidates(depth: i, role: step.role) }
            let isLeaf = (i == path.count - 1)

            if isLeaf, let attrs = leafAttrs {
                if let picked = selectCandidate(candidates, step: step, reader: reader),
                   leafMatches(picked, attrs: attrs, reader: reader) {
                    return .resolved(picked)
                }
                // index/identity pick didn't satisfy attrs → scan same-role siblings for an attr match.
                if let alt = candidates.first(where: { leafMatches($0, attrs: attrs, reader: reader) }) {
                    return .resolved(alt)
                }
                return .leafAttrMismatch(depth: i)
            }

            guard let next = selectCandidate(candidates, step: step, reader: reader) else {
                return .noCandidates(depth: i, role: step.role)
            }
            current = next
        }
        return .resolved(current)
    }

    /// Pick the best candidate for a step: identity match first (identifier → title → description),
    /// then same-role index, then first.
    public static func selectCandidate<R: AXTreeReading>(_ candidates: [R.Element], step: AXPathStep, reader: R) -> R.Element? {
        if let id = step.identifier, let m = candidates.first(where: { reader.identifier($0) == id }) { return m }
        if let t = step.title, !t.isEmpty, let m = candidates.first(where: { reader.title($0) == t }) { return m }
        if let d = step.descriptionText, !d.isEmpty, let m = candidates.first(where: { reader.descriptionText($0) == d }) { return m }
        if let idx = step.index, idx >= 0, idx < candidates.count { return candidates[idx] }
        return candidates.first
    }

    /// A leaf matches if the role agrees and — when the captured descriptor carried any identity
    /// signal — *either* the title or the description matches. Role-only (no captured labels) passes.
    public static func leafMatches<R: AXTreeReading>(_ e: R.Element, attrs: AXLeafAttrs, reader: R) -> Bool {
        guard reader.role(e) == attrs.role else { return false }
        var anySignal = false
        var anyMatch = false
        if let t = attrs.title, !t.isEmpty {
            anySignal = true
            if reader.title(e) == t { anyMatch = true }
        }
        if let d = attrs.descriptionText, !d.isEmpty {
            anySignal = true
            if reader.descriptionText(e) == d { anyMatch = true }
        }
        return anySignal ? anyMatch : true
    }

    // MARK: Opaque-group detection

    /// True when `e` looks like an opaque GPU-painted canvas (Pro Tools/Blender): an `AXGroup`/`AXWindow`
    /// with empty title+description, no useful children, and a frame covering ~all of the window. The
    /// builder then sets `ax.available = false` and falls through to the CV path.
    public static func isOpaqueGroup<R: AXTreeReading>(_ e: R.Element, windowFrame: CGRect, reader: R) -> Bool {
        let role = reader.role(e)
        guard role == "AXGroup" || role == windowRole else { return false }
        guard (reader.title(e) ?? "").isEmpty, (reader.descriptionText(e) ?? "").isEmpty else { return false }
        let hasUsefulChildren = reader.children(e).contains { child in
            !(reader.title(child) ?? "").isEmpty || !(reader.descriptionText(child) ?? "").isEmpty
        }
        guard !hasUsefulChildren else { return false }
        guard let f = reader.frame(e) else { return true }
        let windowArea = max(windowFrame.width * windowFrame.height, 1)
        return (f.width * f.height) / windowArea >= 0.9
    }
}
