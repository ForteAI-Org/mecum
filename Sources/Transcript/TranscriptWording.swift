//
//  TranscriptWording.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Workspace

/// TranscriptWording is every sentence the transcript shows or speaks, in one
/// place, so what is drawn and what VoiceOver reads cannot drift apart.
public enum TranscriptWording {

    /// How far a message got (§11.5). There is no "read": knowing a backend
    /// accepted a request is not knowing anything read it.
    public static func delivery(_ delivery: MessageDelivery) -> String {
        switch delivery {
        case .savedLocally:  "Saved"
        case .pending:       "Waiting"
        case .sentToBackend: "Sent"
        case .responding:    "Responding"
        case .completed:     "Completed"
        case .interrupted:   "Interrupted"
        }
    }

    public static let interrupted = "Interrupted"

    public static let stopped = "Stopped"

    public static let activityNotShown = "Older activity in this span is not shown"

    /// The caption above the first row of a group. The person's carries only
    /// the time: in a direct conversation the bubble's colour says who wrote it.
    /// A thinking bubble carries only the worker's name: it has no time of its own.
    public static func header(for item: TranscriptItem, workerName: String) -> (name: String?, time: String) {
        if case .thinking = item.kind { return (workerName, "") }
        return (item.authorWorkerID == nil ? nil : workerName, time(item.date))
    }

    public static func thinking(by worker: String) -> String { "\(worker) is thinking" }

    public static func failed(by worker: String) -> String {
        "\(worker) could not finish this answer. Nothing was retried; send again to try once more."
    }

    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: Days

    /// A day separator's label: "Today", "Yesterday", the weekday and date
    /// within `now`'s week, else the full date, in `calendar`'s locale and time zone.
    public static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
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

    /// A tool line's summary: what the turn changed, repeats collapsed, a
    /// failure or a step in progress always named, at most `summaryLimit`
    /// phrases. Steps that only looked are named only when nothing else was done.
    public static func toolSummary(_ steps: [ToolStep], ending: TranscriptItem.TurnEnding?) -> String {
        let groups = collapsed(steps)
        var shown  = groups.filter { $0.step.isEffectful || $0.step.state != .done }
        if shown.isEmpty { shown = groups }
        var parts = shown.prefix(summaryLimit).map { toolStep($0.step, count: $0.count, ending: ending) }
        if shown.count > summaryLimit { parts.append("\(shown.count - summaryLimit) more") }
        guard !parts.isEmpty else { return "Used tools" }
        return parts.enumerated().map { $0 == 0 ? $1 : lowercasedFirst($1) }.joined(separator: " · ")
    }

    /// The phrases a collapsed tool line names before "N more".
    public static let summaryLimit = 3

    /// The expanded line's steps, one short line each, repeats collapsed. A
    /// failed step says what failed.
    public static func toolSteps(_ steps: [ToolStep], ending: TranscriptItem.TurnEnding?)
        -> [(text: String, isFailed: Bool)] {
        collapsed(steps).map { group in
            let isFailed = if case .failed = group.step.state { true } else { false }
            return (toolStep(group.step, count: group.count, ending: ending, withReason: true), isFailed)
        }
    }

    /// One step, done, failed or in progress. A call left without a result is
    /// in progress only while its turn runs: after it ends, it stopped or did not finish.
    public static func toolStep(
        _ step    : ToolStep,
        count     : Int = 1,
        ending    : TranscriptItem.TurnEnding?,
        withReason: Bool = false
    ) -> String {
        let phrase = phrase(step.action)
        let times  = count == 1 ? "" : count == 2 ? " twice" : " \(count) times"
        switch step.state {
        case .done:
            if count > 1, case .observe = step.action { return "Looked" + times }
            return phrase.past + times
        case .failed(let reason):
            let lead = phrase.isKnown ? "Could not \(phrase.base)" : "\(phrase.past) failed"
            return lead + times + (withReason ? ": \(reason)" : "")
        case .pending:
            switch ending {
            case nil:                   return phrase.progressive + times + "…"
            case .stopped?:             return phrase.progressive + times + ", stopped"
            case .failed?, .completed?: return phrase.progressive + times + ", did not finish"
            }
        }
    }

    /// A step's past, base and progressive forms. A tool this build does not
    /// know is named as it is.
    private static func phrase(_ action: ToolStep.Action) -> (past: String, base: String, progressive: String,
                                                              isKnown: Bool) {
        func forms(_ past: String, _ base: String, _ progressive: String, _ object: String) -> (String, String,
                                                                                               String, Bool) {
            ("\(past) \(object)", "\(base) \(object)", "\(progressive) \(object)", true)
        }
        switch action {
        case .status:
            return forms("Checked", "check", "Checking", "what is open")
        case .windows(let app):
            return forms("Listed", "list", "Listing", app.map { "the windows of \($0)" } ?? "the open windows")
        case .open(let app):
            return forms("Opened", "open", "Opening", app)
        case .observe:
            return forms("Looked", "look", "Looking", "at the window")
        case .select(let control, let item):
            return forms("Chose", "choose", "Choosing", "\(item) in \(control)")
        case .close(let app):
            return forms("Closed", "close", "Closing", app ?? "the app")
        case .act(let verb, let target, let section, let value):
            let object = target + (section.map { " in \($0)" } ?? "")
            switch (verb, value) {
            case ("click", _):          return forms("Pressed", "press", "Pressing", object)
            case ("double_click", _):   return forms("Double-clicked", "double-click", "Double-clicking", object)
            case ("right_click", _):    return forms("Right-clicked", "right-click", "Right-clicking", object)
            case ("set_toggle", "on"):  return forms("Turned on", "turn on", "Turning on", object)
            case ("set_toggle", "off"): return forms("Turned off", "turn off", "Turning off", object)
            default:                    return forms("Used", "use", "Using", object)
            }
        case .other(let name):
            return (name, name, name, false)
        }
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

    /// The control on a finished code block.
    public static let copyBlock = "Copy"

    public static func codeBlock(language: String?) -> String {
        language.map { "Code block, \($0)" } ?? "Code block"
    }

    /// A row action as VoiceOver lists it.
    public static func action(_ action: RowAction, in text: PreparedText) -> String {
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
    public static func accessibilityLabel(
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
            let detail = isExpanded ? ": " + toolSteps(steps, ending: ending).map(\.text).joined(separator: "; ") : ""
            return "\(workerName) tools, \(when): \(toolSummary(steps, ending: ending))\(detail)"
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
