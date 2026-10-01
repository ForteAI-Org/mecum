import Foundation
import InteractionListener
import InteractionObservation
import PerceptionCore

/// WatcherEntry is a bounded display record. It keeps names and attribution, never a screenshot.
struct WatcherEntry: Identifiable, Encodable {
    let id = UUID()
    let time: Date
    let title: String
    let window: String
    let input: String
    let before: String
    let after: String
    let accessibility: String
    let change: String?

    init(_ report: InteractionReport) {
        func text(_ value: String) -> String {
            String(value.unicodeScalars.prefix(600).map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
                .joined().prefix(600))
        }
        let event = report.event
        time = event.timestamp
        let action: String = switch event.kind {
        case .click: "Click"
        case .rightClick: "Right click"
        case .scroll: "Scroll"
        case .hover: "Hover"
        case .focus: "App activated"
        case .gap: "Input gap"
        }
        title = "\(action) · \(text(report.app))"
        window = event.window.map { "\(text($0.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled")) · window \($0.number)" }
            ?? (event.kind == .focus ? "Application activation" : "Window unresolved")
        var inputDetails = "Recipient PID \(event.processID) · sequence \(event.sequence)"
        if let source = event.sourceProcessID { inputDetails += " · source PID \(source)" }
        if event.kind != .focus && event.kind != .gap {
            inputDetails += " · point \(event.point.x), \(event.point.y)"
        }
        if event.kind == .scroll { inputDetails += " · scroll \(event.deltaX), \(event.deltaY) pt" }
        input = inputDetails
        if let gap = event.gap {
            before = "Missing sequences \(gap.firstSequence)–\(gap.lastSequence): \(gap.lostCritical) clicks/focus, \(gap.lostCoalescible) hover/scroll."
        } else {
            var detail = report.before.element.map { text($0.label) + " [" + ($0.role ?? "pixels") + "] · " } ?? ""
            detail += report.before.status
            if let age = report.before.sceneAgeMilliseconds { detail += " · \(Int(age)) ms old" }
            if let name = report.before.nameResolution { detail += " · name: \(name)" }
            if let section = report.before.section { detail += " · section: \(text(section))" }
            if report.before.status == "ambiguous" {
                detail += " · candidates: " + report.before.candidates.prefix(8).map { text($0.label) }.joined(separator: ", ")
            }
            before = text(detail)
        }
        after = text((report.afterElement.map { $0.label + " · " } ?? "") + report.afterStatus)
        accessibility = report.accessibility.map {
            text([ $0.label, $0.role, $0.status, $0.labelSource ].compactMap { $0 }.joined(separator: " · "))
        } ?? "Not read"
        change = report.observation.map {
            text("Observed consistently; cause unverified. " + ($0.windowTitle.map { "Window: \($0). " } ?? "")
                + "Appeared: " + $0.appeared.prefix(8).joined(separator: ", ")
                + " · Disappeared: " + $0.disappeared.prefix(8).joined(separator: ", ")
                + " · State: " + $0.stateChanges.prefix(8).joined(separator: ", "))
        }
    }
}
