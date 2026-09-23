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
    public static func header(for item: TranscriptItem, workerName: String) -> (name: String?, time: String) {
        (item.authorWorkerID == nil ? nil : workerName, time(item.date))
    }

    /// A tool run's counts: calls are `→` lines, results `←` lines, and a
    /// result that carries ` error:` needs attention. A call with no result is
    /// running only while the turn is: after it ends, it stopped or did not finish.
    public static func toolSummary(_ lines: [String], ending: TranscriptItem.TurnEnding?) -> String {
        let calls     = lines.filter { $0.hasPrefix("→") }.count
        let results   = lines.filter { $0.hasPrefix("←") }
        let attention = results.filter { $0.contains(" error:") }.count
        let completed = results.count - attention
        let unanswered = max(0, calls - results.count)

        var parts: [String] = []
        if completed > 0 { parts.append(completed == 1 ? "1 tool call completed" : "\(completed) tool calls completed") }
        if attention > 0 { parts.append(attention == 1 ? "1 needs attention" : "\(attention) need attention") }
        if unanswered > 0 {
            switch ending {
            case .none:                  parts.append("\(unanswered) running")
            case .stopped:               parts.append("\(unanswered) stopped")
            case .failed?, .completed?:  parts.append("\(unanswered) did not finish")
            }
        }
        if parts.isEmpty { parts.append(lines.count == 1 ? "1 tool record" : "\(lines.count) tool records") }
        return parts.joined(separator: ", ")
    }

    public static func started(by worker: String) -> String { "\(worker) started working" }

    public static let completed = "Finished"

    public static func failed(by worker: String) -> String {
        "\(worker) could not finish this answer. Nothing was retried; send again to try once more."
    }

    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

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
            let detail = isExpanded ? ": " + lines.joined(separator: "; ") : ""
            return "\(workerName) tools, \(when): \(toolSummary(lines, ending: ending))\(detail)"
        case .executionStarted:
            return "\(started(by: workerName)), \(when)"
        case .executionCompleted:
            return "\(completed), \(when)"
        case .executionFailed(let reason):
            return "\(failed(by: workerName)) \(reason), \(when)"
        case .executionInterrupted(let note):
            return "\(stopped), \(when): \(note)"
        case .activityNotShown:
            return activityNotShown
        }
    }
}
