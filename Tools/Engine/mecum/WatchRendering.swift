import Foundation
import InteractionListener
import InteractionObservation
import PerceptionCore

/// WatchRendering keeps JSON output machine readable and text diagnostics explicit about timing.
enum WatchRendering {
    static func raw(_ event: InteractionEvent) -> String {
        if event.kind == .focus { return "focus pid=\(event.processID) (application activated)" }
        if let gap = event.gap {
            return "gap sequences \(gap.firstSequence)-\(gap.lastSequence) lost: \(gap.lostCritical) clicks/focus, \(gap.lostCoalescible) hovers/scrolls"
        }
        let owner = event.window.map { "window #\($0.number) \"\(clean($0.title ?? ""))\" layer=\($0.layer)" } ?? "no window"
        let delta = event.kind == .scroll ? " dx=\(event.deltaX) dy=\(event.deltaY)pt" : ""
        return "\(event.kind.rawValue) pid=\(event.processID) \(owner) @\(Int(event.point.x)),\(Int(event.point.y))\(delta)"
    }

    static func text(_ report: InteractionReport) -> String {
        var line = "\(clean(report.app)) | \(raw(report.event))"
        guard report.event.kind != .focus, report.event.kind != .gap else { return line }
        let before = report.before
        line += "\n  BEFORE: \(before.status)"
        if let element = before.element { line += " \(describe(element))" }
        if let age = before.sceneAgeMilliseconds { line += " age=\(Int(age))ms" }
        if let name = before.nameResolution { line += " name=\(name)" }
        if let section = before.section { line += " section=\"\(clean(section))\"" }
        line += "\n  AFTER: \(clean(report.afterStatus))"
        if let element = report.afterElement { line += " \(describe(element))" }
        if let observation = report.observation {
            line += "\n  OBSERVATION: \(observation.status) (causality unverified)"
            if let title = observation.windowTitle { line += " window=\"\(clean(title))\"" }
            if !observation.appeared.isEmpty { line += " appeared=\(observation.appeared.map(clean).joined(separator: " | "))" }
            if !observation.disappeared.isEmpty { line += " disappeared=\(observation.disappeared.map(clean).joined(separator: " | "))" }
            if !observation.stateChanges.isEmpty { line += " states=\(observation.stateChanges.map(clean).joined(separator: " | "))" }
        }
        if let ax = report.accessibility {
            line += "\n  AX: \(ax.status) \(ax.role ?? "?") \"\(clean(ax.label ?? ""))\""
            if let source = ax.labelSource { line += " name_source=\(source)" }
        }
        if before.status == "ambiguous" {
            line += "\n  candidates: " + before.candidates.map(describe).joined(separator: " | ")
        }
        return line
    }

    /// The listener's stop line: what its queue published, coalesced and lost. The tap never blocks.
    static func counters(observed: UInt64, _ queue: InputQueueCounters) -> String {
        "counters: observed \(observed), queued \(queue.published), coalesced \(queue.coalescedHovers) hovers "
            + "\(queue.aggregatedScrolls) scrolls, lost \(queue.lostCritical) clicks/focus "
            + "\(queue.lostCoalescible) hovers/scrolls in \(queue.gaps) gaps"
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func describe(_ element: SceneElement) -> String {
        let source = element.role == nil ? "pixels" : "AX+scene"
        return "\"\(clean(element.label))\" [\(element.kind.rawValue), \(source), \(element.role ?? "no AX role")] id=\(element.id)"
    }

    private static func clean(_ value: String) -> String {
        String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(240))
    }
}
