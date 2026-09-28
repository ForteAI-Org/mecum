//
//  ConversationQueueStrip.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 28/09/2026.
//

import SwiftUI

/// ConversationQueueStrip is the strip of messages sent while the worker
/// answers, joined above the composer's pill: a clock, the queued message it
/// shows on one line, and at its trailing end a pager when more than one is
/// queued, Send Now, and ×.
///
/// The message it shows is the one that goes next. The pager moves to the
/// next one, and after the last to the first; a click on the text takes the
/// message back into the draft to be edited; × removes it from the queue.
struct ConversationQueueStrip: View {

    /// Never empty: the composer shows the strip only while something is queued.
    let queue: [QueuedMessage]

    /// The position in `queue` of the message shown.
    let shown: Int

    /// A turn or compaction runs, so Send Now stops it first.
    let isAnswering: Bool

    /// Whether this strip is the composer's top one; see `ComposerStrip`.
    var roundsTop = true

    let next   : () -> Void
    let sendNow: () -> Void
    let edit   : () -> Void
    let remove : () -> Void

    var body: some View {
        let message = queue[min(shown, queue.count - 1)]
        return ComposerStrip(
            symbol           : "clock",
            title            : nil,
            text             : message.excerpt,
            accessibilityText: "Queued message \(shown + 1) of \(queue.count): \(message.excerpt)",
            roundsTop        : roundsTop,
            open             : edit
        ) {
            HStack(spacing: 2) {
                if queue.count > 1 { pager }
                sendNowButton
                ComposerStripCancelButton(
                    help  : "Remove this message from the queue.",
                    label : "Remove Queued Message",
                    action: remove
                )
            }
        }
        .help("Edit this queued message.")
    }

    /// "2/3 ›": where the strip stands in the queue, and a click to the next one.
    private var pager: some View {
        Button(action: next) {
            HStack(spacing: 2) {
                Text("\(shown + 1)/\(queue.count)")
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(
                        size  : 8,
                        weight: .bold
                    ))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(
                .horizontal,
                6
            )
            .frame(height: 18)
            .background(
                .fill.secondary,
                in: Capsule()
            )
            .frame(height: ComposerStrip<EmptyView>.controlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(
            .trailing,
            4
        )
        .help("Show the next queued message.")
        .accessibilityLabel("Next queued message")
    }

    /// A small round arrow in the accent, the composer's Send in miniature.
    private var sendNowButton: some View {
        Button(action: sendNow) {
            Image(systemName: "arrow.up")
                .font(.system(
                    size  : 10,
                    weight: .bold
                ))
                .foregroundStyle(.tint)
                .frame(
                    width : 20,
                    height: 20
                )
                .background(
                    Color.accentColor.opacity(0.16),
                    in: Circle()
                )
                .frame(
                    width : ComposerStrip<EmptyView>.controlHeight,
                    height: ComposerStrip<EmptyView>.controlHeight
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isAnswering ? "Stop the response and send this message now." : "Send this message now.")
        .accessibilityLabel("Send Now")
    }
}
