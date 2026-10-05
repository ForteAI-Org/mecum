//
//  CallText.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore

/// CallText is how the command line writes the living memory's typed values for a person: a call's
/// arguments, its result and its observed effect, an event's identity and times, a sample's quality.
/// One line per value, every field named, texts quoted with their escapes so a separator inside one
/// is visible as such. Nothing is inferred: an absent value is written as absent (`unknown`, `none`,
/// `not recorded`), never as zero or as success.
///
/// Typed texts and element labels are local content: `detail` writes them, otherwise their length.
nonisolated enum CallText {

    static func quoted(_ text: String) -> String { String(reflecting: text) }

    private static func content(_ text: String, detail: Bool) -> String {
        detail ? quoted(text) : "<\(text.count) characters>"
    }

    private static func points(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    /// A call's arguments, as decoded.
    static func request(_ request: AgentCallRequest, detail: Bool = false) -> String {
        func section(_ name: String?) -> String { name.map { " section=\(quoted($0))" } ?? "" }
        switch request {
            case .status:
                return "status"
            case .windows(let app):
                return "windows" + (app.map { " app=\(quoted($0))" } ?? "")
            case .apps(let query):
                return "apps" + (query.map { " query=\(quoted($0))" } ?? "")
            case .openSession(let app, let window):
                return "open_session app=\(quoted(app))" + (window.map { " window=\(quoted($0))" } ?? "")
            case .observe:
                return "observe"
            case .act(let target, let verb, let value, let name):
                return "act target=\(quoted(target)) verb=\(verb.rawValue)"
                    + (value.map { " value=\($0.rawValue)" } ?? "") + section(name)
            case .select(let control, let item):
                return "select control=\(quoted(control)) item=\(quoted(item))"
            case .typeText(let target, let text, let name, let replace):
                return "type_text target=\(quoted(target)) text=\(content(text, detail: detail)) replace=\(replace)" + section(name)
            case .pressKey(let key, let modifiers, let count):
                return "press_key key=\(key.word) modifiers=[\(modifiers.map(\.rawValue).joined(separator: ","))] count=\(count)"
            case .scroll(let direction, let lines, let target, let name):
                return "scroll direction=\(direction.rawValue) lines=\(lines)"
                    + (target.map { " target=\(quoted($0))" } ?? "") + section(name)
            case .drag(let from, .target(let to), let name):
                return "drag from=\(quoted(from)) to=\(quoted(to))" + section(name)
            case .drag(let from, .offset(let dx, let dy), let name):
                return "drag from=\(quoted(from)) dx=\(points(dx)) dy=\(points(dy))" + section(name)
            case .contextMenu(let target, let item, let name):
                return "context_menu target=\(quoted(target)) item=\(quoted(item))" + section(name)
            case .batch:
                return "batch"
            case .closeSession:
                return "close_session"
        }
    }

    /// A call's result, as stored.
    static func result(_ result: AgentCallResult?, detail: Bool = false) -> String {
        guard let result else { return "none recorded" }
        switch result {
            case .outcome(let kind, let message):
                return "\(kind.rawValue): \(quoted(message))"
            case .batch(let stopped, let attempted, let verified):
                return "batch \(stopped ? "stopped" : "completed"), \(attempted) attempted, \(verified) verified"
            case .closed(let message):
                return "closed: \(quoted(message))"
            case .error(let message):
                return "error: \(quoted(message))"
            case .status(let status):
                return "status session=\(status.sessionID.map(quoted) ?? "none") screenRecording=\(status.screenRecording) "
                    + "accessibility=\(status.accessibility) postEvent=\(status.postEvent)"
            case .listing(let listing):
                let apps = listing.applications.map { app in
                    let windows = app.windows.map { window in
                        "#\(window.number)" + (detail ? " " + (window.title.map(quoted) ?? "untitled") : "")
                    }
                    return "\(quoted(app.name)) \(app.bundleID)" + (windows.isEmpty ? "" : " [\(windows.joined(separator: ", "))]")
                }
                return "\(listing.kind.rawValue) \(listing.applications.count) listed, \(listing.hiddenCount) more not listed"
                    + (apps.isEmpty ? "" : ": " + apps.joined(separator: "; "))
            case .observation(let observation):
                return "observation session=\(observation.sessionID) revision=\(observation.sessionRevision) "
                    + "at=\(calendar(observation.observedAtMS)) sample=\(observation.sample.eventID)/\(observation.sample.phase.rawValue)"
        }
    }

    /// An observed effect, as its typed parts.
    static func effect(_ effect: ObservedEffect?, detail: Bool = false) -> String {
        guard let effect else { return "none recorded" }
        var parts = [effect.kind]
        if let title = effect.title { parts.append("title=" + content(title, detail: detail)) }
        if let before = effect.stateBefore { parts.append("before=\(before.rawValue)") }
        if let after = effect.stateAfter { parts.append("after=\(after.rawValue)") }
        if !effect.labels.isEmpty {
            parts.append(detail ? "labels=[\(effect.labels.map(quoted).joined(separator: ", "))]"
                                : "labels=<\(effect.labels.count)>")
        }
        return parts.joined(separator: " ")
    }

    /// A calendar instant of a fact: its milliseconds since 1970 as stored, and the same in ISO 8601.
    static func calendar(_ milliseconds: Int64?) -> String {
        guard let milliseconds else { return "not recorded" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return "\(milliseconds) (\(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))))"
    }

    /// A call's state, said as what it means: a state that is not terminal is not a conclusion.
    static func status(_ status: AgentCallStatus) -> String {
        switch status {
            case .planned : "planned (never started: no effect recorded)"
            case .started : "started (no terminal state recorded: its outcome is unknown)"
            default       : status.rawValue
        }
    }

    /// One call on one line: its tool and arguments, its state, its result and its duration.
    static func line(_ call: AgentCall, detail: Bool = false) -> String {
        let duration = call.durationMS.map { "\($0) ms" } ?? "no duration"
        return "\(request(call.request, detail: detail)) · \(status(call.progress.status)) · "
            + "\(result(call.progress.result, detail: detail)) · \(duration)"
    }

    /// A sample's quality and shape.
    static func sample(_ sample: CaptureSample, detail: Bool = false) -> String {
        let quality = sample.quality
        var line = "\(sample.key.phase.rawValue)#\(sample.key.ordinal): \(quality.completeness.rawValue), surface \(sample.surface.rawValue), "
            + "\(sample.elements.count) elements, revision \(sample.sessionRevision.map(String.init) ?? "none")"
        func said(_ value: Bool?, _ yes: String, _ no: String) -> String { value.map { $0 ? yes : no } ?? "unknown" }
        line += ", walk \(said(quality.walkCompleted, "completed", "incomplete")), window \(said(quality.windowFound, "found", "not found"))"
        if detail {
            line += ", title " + (sample.windowTitle.map(quoted) ?? "none")
            line += ", labels [" + sample.elements.map { quoted($0.label) }.joined(separator: ", ") + "]"
        }
        return line
    }
}
