//
//  ToolStep.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// ToolStep is one thing a worker's tools did in a turn, read back from the
/// records the host stores (`AutomationTools.record`): a call `→ name {args}`,
/// then its result `← name {json}` or `← name error: reason`. A batch call is
/// its steps, answered by `← batch step N`. What the worker wrote just before
/// a call, saying what it was about to do, is a note `» text`: the turn's
/// recorder keeps it on the line rather than as a reply. A command line's
/// own web search or page read is recorded the same way, as `web_search` or
/// `web_fetch` (`WebToolRecords`).
///
/// A result is matched to the oldest call of the same tool still waiting, so
/// calls that overlap still pair. A result with no call, as after a capped
/// read or a call rejected before it ran, is a step of its own. An outcome
/// whose status is not a success (`honest_miss`, `ambiguous`, `refused`,
/// `acted_unverified`) failed, with its message as the reason. A record this
/// build cannot read keeps its tool's name.
nonisolated struct ToolStep: Sendable, Hashable {

    enum Action: Sendable, Hashable {
        case status
        case windows(app: String?)

        /// Looked up the applications it can open, matching `query` when there is one.
        case apps(query: String?)

        case open(app: String)
        case observe
        case act(verb: String, target: String, section: String?, value: String?)
        case select(control: String, item: String)

        /// Typed `text` into `field`, over what it held unless `replace` is false.
        case typeText(text: String, field: String, replace: Bool)

        /// Pressed a key or a shortcut, `count` times.
        case key(name: String, modifiers: [String], count: Int)

        /// Turned the wheel `direction`, over `target` or the window.
        case scroll(direction: String, target: String?)

        /// Dragged `source` onto `destination`, or by an offset when it is nil.
        case drag(source: String, destination: String?)

        /// Right-clicked `target` and chose `item` in its contextual menu.
        case contextMenu(target: String, item: String)

        /// Listed or pressed `path` in the application's menu bar.
        case menu(path: String)

        /// Pressed the dialog button titled `button` through accessibility.
        case press(button: String)

        /// Closes the app the session held, when this turn opened it.
        case close(app: String?)

        /// Searched the web, for `query` when the record names it.
        case webSearch(query: String?)

        /// Read a web page on `site`, its address's host without `www.`.
        case webRead(site: String?)

        /// What the worker said it was about to do, in its own words.
        case note(String)

        case other(name: String)
    }

    enum State: Sendable, Hashable {

        /// Called, with no result yet.
        case pending
        case done
        case failed(reason: String)
    }

    let action: Action
    var state: State

    /// True for a step that changes the app, rather than one that only looks.
    var isEffectful: Bool {
        switch action {
        case .status, .windows, .apps, .observe, .webSearch, .webRead, .note: false
        default:                                                              true
        }
    }

    var isNote: Bool {
        if case .note = action { true } else { false }
    }

    /// The mark a note's record starts with.
    static let noteMark = "» "

    /// The record of a note: what the worker wrote before a tool call.
    static func noteRecord(_ text: String) -> String { noteMark + text }

    /// The outcome statuses that mean the step did what it says.
    static let successes: Set<String> = ["found_acted", "acted_noop", "dry_run"]

    /// The tools whose result is an outcome with a status, rather than a reading.
    static let outcomeTools: Set<String> = [
        "act",
        "select",
        "type_text",
        "press_key",
        "scroll",
        "drag",
        "context_menu",
        "menu",
        "press",
    ]

    /// The steps `lines` record, in call order.
    static func steps(from lines: [String]) -> [ToolStep] {
        var steps  : [ToolStep] = []
        var waiting: [String: [Int]] = [:]
        var batch  : [Int] = []
        var dropped: Set<Int> = []
        var lastApp: String?

        for line in lines {
            if line.hasPrefix(noteMark) {
                steps.append(ToolStep(action: .note(String(line.dropFirst(noteMark.count))), state: .done))
                continue
            }
            let isCall = line.hasPrefix("→ ")
            guard isCall || line.hasPrefix("← ") else {
                steps.append(ToolStep(action: .other(name: line), state: .done))
                continue
            }
            let body = line.dropFirst(2)
            let name = String(body.prefix { $0 != " " })
            let rest = body.dropFirst(name.count).drop { $0 == " " }

            if isCall {
                let arguments = object(rest) ?? [:]
                if name == "batch" {
                    let parts = (arguments["steps"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
                    batch = parts.map { part in
                        steps.append(ToolStep(action: action(part["operation"] as? String ?? "act", part,
                                                             lastApp: lastApp), state: .pending))
                        return steps.count - 1
                    }
                    continue
                }
                let made = action(name, arguments, lastApp: lastApp)
                if case .open(let app) = made { lastApp = app }
                waiting[name, default: []].append(steps.count)
                steps.append(ToolStep(action: made, state: .pending))
                continue
            }

            // A result: a batch's step, a batch's end, or one tool's answer.
            if name == "batch", rest.hasPrefix("step ") {
                let number = rest.dropFirst(5).prefix { $0.isNumber }
                let answer = rest.dropFirst(5 + number.count).drop { $0 == " " }
                if let position = Int(number), batch.indices.contains(position - 1) {
                    steps[batch[position - 1]].state = state(of: answer, checksOutcome: true)
                }
                continue
            }
            if name == "batch" {
                // Steps a stopped batch never reached did not happen; a batch refused whole is one failed step.
                let answer    = state(of: rest, checksOutcome: false)
                let unreached = batch.filter { steps[$0].state == .pending }
                if case .failed = answer, unreached.count == batch.count {
                    if let first = batch.first {
                        steps[first].state = answer
                        dropped.formUnion(batch.dropFirst())
                    } else {
                        steps.append(ToolStep(action: .other(name: name), state: answer))
                    }
                } else {
                    dropped.formUnion(unreached)
                }
                batch = []
                continue
            }
            let answer = state(of: rest, checksOutcome: outcomeTools.contains(name))
            if let index = waiting[name]?.first {
                waiting[name]?.removeFirst()
                steps[index].state = answer
            } else {
                steps.append(ToolStep(action: action(name, [:], lastApp: lastApp), state: answer))
            }
        }
        guard !dropped.isEmpty else { return steps }
        return steps.indices.filter { !dropped.contains($0) }.map { steps[$0] }
    }

    // MARK: Reading records

    private static func action(_ name: String, _ arguments: [String: Any], lastApp: String?) -> Action {
        func text(_ key: String) -> String? {
            (arguments[key] as? String).map(shortened)
        }
        switch name {
        case "status":        return .status
        case "windows":       return .windows(app: text("app"))
        case "apps":          return .apps(query: text("query"))
        case "open_session":  return text("app").map(Action.open) ?? .other(name: name)
        case "observe":       return .observe
        case "close_session": return .close(app: lastApp)
        case "select":
            guard let control = text("control"), let item = text("item") else { return .other(name: name) }
            return .select(control: control, item: item)
        case "act":
            guard let target = text("target") else { return .other(name: name) }
            return .act(verb: text("verb") ?? "click", target: target, section: text("section"), value: text("value"))
        case "type_text":
            guard let typed = text("text"), let field = text("target") else { return .other(name: name) }
            return .typeText(
                text   : typed,
                field  : field,
                replace: arguments["replace"] as? Bool ?? true
            )
        case "press_key":
            guard let key = text("key") else { return .other(name: name) }
            return .key(
                name     : key,
                modifiers: arguments["modifiers"] as? [String] ?? [],
                count    : arguments["count"] as? Int ?? 1
            )
        case "scroll":
            guard let direction = text("direction") else { return .other(name: name) }
            return .scroll(
                direction: direction,
                target   : text("target")
            )
        case "drag":
            guard let source = text("from") else { return .other(name: name) }
            return .drag(
                source     : source,
                destination: text("to")
            )
        case "context_menu":
            guard let target = text("target"), let item = text("item") else { return .other(name: name) }
            return .contextMenu(
                target: target,
                item  : item
            )
        case "menu":
            guard let path = text("path") else { return .other(name: name) }
            return .menu(path: path)
        case "press":
            guard let button = text("button") else { return .other(name: name) }
            return .press(button: button)
        case "web_search":
            return .webSearch(query: text("query"))
        case "web_fetch":
            return .webRead(site: (arguments["url"] as? String).map(site))
        default:
            return .other(name: name)
        }
    }

    /// A result's state: an error names its reason, and an act or select
    /// outcome that is not a success fails with its message.
    private static func state(of answer: Substring, checksOutcome: Bool) -> State {
        if answer.hasPrefix("error:") {
            var reason = answer.dropFirst(6).trimmingCharacters(in: .whitespaces)
            // The guidance is for the model, not the reader.
            if reason.hasSuffix(" Observe before any retry.") { reason.removeLast(26) }
            return .failed(reason: shortened(reason, limit: 120))
        }
        guard checksOutcome, let outcome = object(answer), let status = outcome["status"] as? String,
              !successes.contains(status)
        else { return .done }
        let message = outcome["message"] as? String ?? status
        return .failed(reason: shortened(message, limit: 120))
    }

    /// The JSON object a record carries, or nil when it carries none: a
    /// record this build cannot read still becomes a step, by its name.
    private static func object(_ text: Substring) -> [String: Any]? {
        guard text.first == "{" else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        } catch {
            return nil
        }
    }

    /// The host a web address names, without `www.`, or the address itself when it names none.
    private static func site(_ address: String) -> String {
        guard let host = URL(string: address)?.host(), !host.isEmpty else { return shortened(address) }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A value a model chose, cut so a step stays one short line.
    private static func shortened(_ text: String) -> String { shortened(text, limit: 40) }

    private static func shortened(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? flat.prefix(limit - 1) + "…" : flat
    }
}
