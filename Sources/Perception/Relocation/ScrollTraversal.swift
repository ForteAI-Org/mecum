import Foundation
import CoreGraphics
import LocatorCore

/// Evidence for a bounded sweep/jump. A dead initial burst says nothing about later movement.
/// Keep the selected pane's geometry for this window, because scrolling changes section headers.
public enum ScrollTraversal {
    public enum Mode: Sendable { case sweep, top, bottom }
    public enum Stop: String, Sendable {
        case unchanged = "no further movement observed"
        case budget = "step limit reached"
        case unverified = "could not verify a scroll or read its viewport"
        case windowChanged = "window changed during traversal"
        case cancelled = "cancelled"
    }

    public struct Result: Sendable {
        public var moved = false
        public var paneProven = false
        public var directionVerified = false
        public fileprivate(set) var traversalMoved = false
        public var labels: Set<String> = []
        public var firstStop: Stop = .budget
        public var finalStop: Stop = .budget
        public var scene: SceneSnapshot?

        public func finished(_ mode: Mode) -> Bool {
            paneProven && directionVerified && finalStop == .unchanged
                && (mode != .sweep || (firstStop == .unchanged && traversalMoved))
        }

        public func message(mode: Mode, pane: String) -> String {
            let shown = mode == .sweep ? labels.sorted() : Array(labels.sorted().prefix(20))
            let inventory = shown.joined(separator: " · ")
            let task = mode == .sweep ? "sweep" : "scroll to \(mode == .top ? "top" : "bottom")"
            let verdict: String
            if finished(mode) {
                verdict = mode == .sweep ? "swept \(pane) top→bottom" : "\(pane) is now at the \(mode == .top ? "top" : "bottom")"
            } else {
                let reason = !directionVerified ? "wheel direction not verified for this app"
                    : finalStop == .unchanged && (!paneProven || (mode == .sweep && !traversalMoved))
                    ? "no traversal movement verified; an end stop, an unresponsive target, and a non-scrolling pane remain indistinguishable"
                    : (mode == .sweep && firstStop != .unchanged ? firstStop : finalStop).rawValue
                verdict = "incomplete \(task) in \(pane): \(reason)"
            }
            // Even reaching both ends does not prove exhaustive enumeration: OCR can miss labels,
            // and wheel bursts may skip rows. Never call this EVERYTHING or a count of all items.
            let scope = mode == .sweep ? "Observed labels" : "Current viewport labels"
            let clipped = shown.count < labels.count ? "; showing \(shown.count)" : ""
            return verdict + ". \(scope) in this pane (\(labels.count)\(clipped); not an exhaustive item count): " + inventory
        }
    }

    public static func labels(in scene: SceneSnapshot, pane: CGRect) -> Set<String> {
        Set(scene.elements.compactMap { e in
            guard e.unlabeled != true, e.pos.count == 4,
                  e.pos.allSatisfy({ $0.isFinite }), e.pos[2] > 0, e.pos[3] > 0,
                  pane.contains(CGPoint(x: e.pos[0] + e.pos[2] / 2, y: e.pos[1] + e.pos[3] / 2))
            else { return nil }
            let label = e.label.trimmingCharacters(in: .whitespacesAndNewlines)
            // Numeric row names (bus "30", track "808") are meaningful. Reject only non-name glyphs.
            return label.contains(where: { $0.isLetter || $0.isNumber }) ? label : nil
        })
    }

    public static func run(mode: Mode, initial: PaneScroller.Outcome, paneProven: Bool, directionVerified: Bool,
                           pane: CGRect, window: SceneSnapshot, firstLimit: Int = 10, downLimit: Int = 14,
                           scroll: (Int) async -> PaneScroller.Outcome,
                           read: () async -> SceneSnapshot?) async -> Result {
        var result = Result()
        result.moved = initial.verified && initial.moved
        result.paneProven = paneProven || result.moved
        result.directionVerified = directionVerified

        func collect() async -> Stop? {
            result.scene = nil
            guard let scene = await read() else { return .unverified }
            guard scene.bundleID == window.bundleID, scene.windowTitle == window.windowTitle,
                  scene.viewportPx == window.viewportPx else { return .windowChanged }
            result.scene = scene
            let visible = labels(in: scene, pane: pane)
            if mode == .sweep { result.labels.formUnion(visible) }
            else { result.labels = visible }
            return nil
        }

        func leg(ticks: Int, limit: Int) async -> Stop {
            for _ in 0..<max(0, limit) {
                if Task.isCancelled { return .cancelled }
                let outcome = await scroll(ticks)
                guard outcome.verified else { result.scene = nil; return .unverified }
                // A changed dialog/window is not evidence about the pane we were asked to learn.
                if let problem = await collect() { return problem }
                result.moved = result.moved || outcome.moved
                result.traversalMoved = result.traversalMoved || outcome.moved
                result.paneProven = result.paneProven || outcome.moved
                if !outcome.moved { return .unchanged }
            }
            return .budget
        }

        if let problem = await collect() {
            result.firstStop = problem; result.finalStop = problem
            return result
        }
        result.firstStop = await leg(ticks: mode == .bottom ? 6 : -6, limit: firstLimit)
        result.finalStop = result.firstStop
        // A budget permits returning downward with a PARTIAL inventory; lost perception does not.
        if mode == .sweep, result.firstStop == .unchanged || result.firstStop == .budget {
            // Reading needs overlap. Live 120-row TextEdit fixture: a standard burst, even at one
            // line/event, jumped rows 001–030 → 057–085. The caller uses the already measured
            // four-event calibration cadence for this one-line reading leg, not the travel burst.
            result.finalStop = await leg(ticks: 1, limit: downLimit)
        }
        return result
    }
}
