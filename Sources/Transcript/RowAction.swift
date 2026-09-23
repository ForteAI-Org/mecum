//
//  RowAction.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

/// RowAction is something a row does only when asked: copy one of its code
/// blocks or open one of its links (§12.4, §12.5).
///
/// Every action is reachable from the keyboard: Left and Right move through a
/// focused row's actions in reading order, Return or Space runs the focused
/// one. VoiceOver lists the same actions on the row.
public enum RowAction: Sendable, Hashable {

    /// Copies the code of the block at `index` in the row's blocks.
    case copyBlock(index: Int)

    /// Opens `destination`, whose text is `range` in the block at `block`.
    case openLink(destination: String, block: Int, range: NSRange)

    /// The row's actions, in reading order: a finished code block's Copy
    /// sits at its top, and a link's runs, destination included, are one action.
    public static func actions(in text: PreparedText) -> [RowAction] {
        var actions: [RowAction] = []
        for (index, block) in text.blocks.enumerated() {
            if block.isCompleteCode { actions.append(.copyBlock(index: index)) }
            var open: (destination: String, range: NSRange)?
            for run in block.runs {
                if let link = run.link, let current = open, current.destination == link,
                   NSMaxRange(current.range) == run.range.location {
                    open = (link, NSUnionRange(current.range, run.range))
                    continue
                }
                if let current = open {
                    actions.append(.openLink(destination: current.destination, block: index, range: current.range))
                }
                open = run.link.map { ($0, run.range) }
            }
            if let current = open {
                actions.append(.openLink(destination: current.destination, block: index, range: current.range))
            }
        }
        return actions
    }

    /// The URL a link may open, or nil. Only web and mail links open; any
    /// other scheme a model wrote, such as `file` or `javascript`, stays text.
    public static func openableURL(_ destination: String) -> URL? {
        guard let url = URL(string: destination), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        return url
    }
}
