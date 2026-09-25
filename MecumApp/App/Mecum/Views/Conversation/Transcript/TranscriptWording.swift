//
//  TranscriptWording.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import ModelTransports

/// TranscriptWording is every sentence the transcript shows or speaks, in one
/// place, so what is drawn and what VoiceOver reads cannot drift apart.
nonisolated enum TranscriptWording {

    /// How far a message got (§11.5). There is no "read": knowing a backend
    /// accepted a request is not knowing anything read it.
    static func delivery(_ delivery: MessageDelivery) -> String {
        switch delivery {
        case .savedLocally:  "Saved"
        case .pending:       "Waiting"
        case .sentToBackend: "Sent"
        case .responding:    "Responding"
        case .completed:     "Completed"
        case .interrupted:   "Stopped"
        }
    }

    static let interrupted = "Stopped"

    static let stopped = "Stopped"

    static let activityNotShown = "Some earlier activity is hidden"

    /// The caption above the first row of a group. The person's carries only
    /// the time: in a direct conversation the bubble's colour says who wrote it.
    /// A thinking bubble carries only the worker's name: it has no time of its own.
    static func header(for item: TranscriptItem, workerName: String) -> (name: String?, time: String) {
        if case .thinking = item.kind { return (workerName, "") }
        return (item.authorWorkerID == nil ? nil : workerName, time(item.date))
    }

    static func thinking(by worker: String) -> String { "\(worker) is preparing a response" }

    static func failed(by worker: String) -> String {
        "\(worker) couldn’t finish the response. Send your message again to retry."
    }

    /// A failure card for a turn whose command line is signed out: what happened, then how to sign
    /// in again. Nil for a provider that is not a command line.
    static func signedOut(
        _ provider: ModelProvider,
        worker    : String
    ) -> (headline: String, steps: String)? {
        guard let steps = SignInFailure.steps(for: provider) else { return nil }

        return (
            "\(SignInFailure.name(of: provider)) is signed out, so \(worker) couldn’t respond.",
            "\(steps) Then send your message again."
        )
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Days

    /// A day separator's label: "Today", "Yesterday", the weekday and date
    /// within `now`'s week, else the full date, in `calendar`'s locale and time zone.
    static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let locale = calendar.locale ?? .autoupdatingCurrent
        if date < now, calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            return date.formatted(style.weekday(.wide).day().month(.wide))
        }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar,
                                               timeZone: calendar.timeZone))
    }

    // MARK: Tools

    /// A tool line's summary: what the turn did or is doing, repeats collapsed, at
    /// most `summaryLimit` phrases. A step that failed is left out, so a problem the
    /// worker got past leaves no trace here, and a turn that did nothing else names
    /// what it tried. Steps that only looked are named only when nothing else was
    /// done, and the worker's notes never.
    static func toolSummary(_ steps: [ToolStep], ending: TranscriptItem.TurnEnding?) -> String {
        let groups = collapsed(steps.filter { !$0.isNote })
        let kept   = groups.filter { !isFailed($0.step) }
        var shown  = kept.filter { $0.step.isEffectful || $0.step.state == .pending }
        if shown.isEmpty { shown = groups.filter { $0.step.isEffectful } }
        if shown.isEmpty { shown = kept + groups.filter { isFailed($0.step) } }
        var parts = shown.prefix(summaryLimit).map { toolStep($0.step, count: $0.count, ending: ending) }
        if shown.count > summaryLimit { parts.append("\(shown.count - summaryLimit) more") }
        guard !parts.isEmpty else { return "Performed actions" }
        return parts.enumerated().map { $0 == 0 ? $1 : lowercasedFirst($1) }.joined(separator: " · ")
    }

    /// The phrases a collapsed tool line names before "N more", so it stays one short line.
    static let summaryLimit = 2

    /// The longest a label a model chose is shown in a step, so a step stays one short line.
    static let labelLimit = 24

    /// The opened line's steps, one short line each, repeats collapsed, without
    /// the worker's notes. A step that failed says what was tried and not why:
    /// a turn that failed says so on its own card.
    static func toolSteps(_ steps: [ToolStep], ending: TranscriptItem.TurnEnding?) -> [String] {
        collapsed(steps.filter { !$0.isNote }).map { toolStep($0.step, count: $0.count, ending: ending) }
    }

    /// One step, done, tried or in progress. A call left without a result is
    /// in progress only while its turn runs: after it ends, it stopped or did not finish.
    static func toolStep(
        _ step: ToolStep,
        count : Int = 1,
        ending: TranscriptItem.TurnEnding?
    ) -> String {
        let phrase = phrase(step.action)
        let times  = count == 1 ? "" : count == 2 ? " twice" : " \(count) times"
        switch step.state {
        case .done:
            if count > 1, case .observe = step.action { return "Looked" + times }
            return phrase.past + times
        case .failed:
            return "Tried to \(phrase.base)" + times
        case .pending:
            switch ending {
            case nil:                   return phrase.progressive + times + "…"
            case .stopped?:             return phrase.progressive + times + ", stopped"
            case .failed?, .completed?: return phrase.progressive + times + ", did not finish"
            }
        }
    }

    /// A step's past, base and progressive forms, each label a model chose cut
    /// to `labelLimit`. A tool this build does not know is named as it is.
    private static func phrase(_ action: ToolStep.Action) -> (past: String, base: String, progressive: String) {
        func forms(
            _ past       : String,
            _ base       : String,
            _ progressive: String,
            _ object     : String
        ) -> (String, String, String) {
            ("\(past) \(object)", "\(base) \(object)", "\(progressive) \(object)")
        }
        switch action {
        case .status:
            return forms("Checked", "check", "Checking", "open apps")
        case .windows(let app):
            return forms("Checked", "check", "Checking", app.map { "\(label($0))’s open windows" } ?? "open windows")
        case .apps(let query):
            return forms("Looked up", "look up", "Looking up", query.map { "“\(label($0))”" } ?? "apps")
        case .open(let app):
            return forms("Opened", "open", "Opening", label(app))
        case .observe:
            return forms("Viewed", "view", "Viewing", "the window")
        case .select(let control, let item):
            return forms("Selected", "select", "Selecting", "\(label(item)) in \(label(control))")
        case .close(let app):
            return forms("Closed", "close", "Closing", app.map(label) ?? "the app")
        case .act(let verb, let target, let section, let value):
            // The element and where it sits are one label, as the perception names it.
            let object = label(target + (section.map { " in \($0)" } ?? ""))
            switch (verb, value) {
            case ("click", _):          return forms("Pressed", "press", "Pressing", object)
            case ("double_click", _):   return forms("Double-clicked", "double-click", "Double-clicking", object)
            case ("triple_click", _):   return forms("Triple-clicked", "triple-click", "Triple-clicking", object)
            case ("right_click", _):    return forms("Right-clicked", "right-click", "Right-clicking", object)
            case ("set_toggle", "on"):  return forms("Turned on", "turn on", "Turning on", object)
            case ("set_toggle", "off"): return forms("Turned off", "turn off", "Turning off", object)
            default:                    return forms("Used", "use", "Using", object)
            }
        case .typeText(let text, let field, let replace):
            return replace
                ? forms("Typed", "type", "Typing", "“\(label(text))” into \(label(field))")
                : forms("Added", "add", "Adding", "“\(label(text))” to \(label(field))")
        case .key(let name, let modifiers, let count):
            let key   = keyName(
                name,
                modifiers: modifiers
            )
            let times = count > 1 ? " \(count) times" : ""
            return forms("Pressed", "press", "Pressing", key + times)
        case .scroll(let direction, let target):
            return forms("Scrolled", "scroll", "Scrolling", "\(direction) in \(target.map(label) ?? "the window")")
        case .drag(let source, let destination):
            return forms("Dragged", "drag", "Dragging", label(source) + (destination.map { " to \(label($0))" } ?? ""))
        case .contextMenu(let target, let item):
            return forms("Selected", "select", "Selecting", "\(label(item)) from \(label(target))’s menu")
        case .note(let text):
            return (text, text, text)
        case .other(let name):
            return (name, name, name)
        }
    }

    /// `text` cut to `labelLimit` characters at most, the last an ellipsis.
    private static func label(_ text: String) -> String {
        guard text.count > labelLimit else { return text }
        return text.prefix(labelLimit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func isFailed(_ step: ToolStep) -> Bool {
        if case .failed = step.state { true } else { false }
    }

    /// A key as a Mac prints it: Return or ↓ alone, ⌘⇧N with modifiers held.
    private static func keyName(
        _ name   : String,
        modifiers: [String]
    ) -> String {
        let glyphs = [("ctrl", "⌃"), ("opt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
            .filter { modifiers.contains($0.0) }
            .map(\.1)
            .joined()
        let arrows = ["left": "←", "right": "→", "up": "↑", "down": "↓"]
        if let arrow = arrows[name] {
            return glyphs + arrow
        }
        if name.count == 1 {
            return glyphs + name.uppercased()
        }
        return glyphs + name.capitalized
    }

    /// Consecutive equal steps, as one step and how many times it happened.
    private static func collapsed(_ steps: [ToolStep]) -> [(step: ToolStep, count: Int)] {
        var groups: [(step: ToolStep, count: Int)] = []
        for step in steps {
            if let last = groups.last, last.step == step {
                groups[groups.count - 1].count += 1
            } else {
                groups.append((step, 1))
            }
        }
        return groups
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }

    // MARK: Code

    static func codeBlock(language: String?) -> String {
        language.map { "Code block, \($0)" } ?? "Code block"
    }

    /// A row action as VoiceOver lists it.
    static func action(_ action: RowAction, in text: PreparedText) -> String {
        switch action {
        case .copyBlock(let index):
            guard text.blocks.indices.contains(index), case .code(let language, _) = text.blocks[index].kind
            else { return "Copy code block" }
            return language.map { "Copy \($0) code block" } ?? "Copy code block"
        case .openLink(let destination, _, _):
            let shown = URL(string: destination).map(MarkdownRendering.shownDestination) ?? destination
            return "Open link to \(shown)"
        }
    }

    /// The whole row as VoiceOver reads it: author, time, content, state.
    /// `content` is the rendered text, without the Markdown that produced it.
    static func accessibilityLabel(
        for item  : TranscriptItem,
        workerName: String,
        content   : String? = nil
    ) -> String {
        let when = time(item.date)
        switch item.kind {
        case .personMessage(let text, let delivery, _):
            return "You, \(when): \(content ?? text). \(self.delivery(delivery))"
        case .workerReply(let text, let isInterrupted):
            return "\(workerName), \(when): \(content ?? text)" + (isInterrupted ? ". \(interrupted)" : "")
        case .toolRun(let lines, let isExpanded, let ending):
            let steps  = ToolStep.steps(from: lines)
            let detail = isExpanded ? ": " + toolSteps(steps, ending: ending).joined(separator: "; ") : ""
            return "\(workerName)’s activity, \(when): \(toolSummary(steps, ending: ending))\(detail)"
        case .thinking:
            return thinking(by: workerName)
        case .daySeparator(let label):
            return label
        case .executionFailed(let reason):
            return "\(failed(by: workerName)) \(reason), \(when)"
        case .executionInterrupted(let note):
            return "\(stopped), \(when): \(note)"
        case .activityNotShown:
            return activityNotShown
        }
    }
}
