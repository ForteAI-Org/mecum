//
//  SystemBubble.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import ModelTransports
import SeatBroker
import SwiftUI

/// Runtime output. Plain text, an observation (image plus collapsible scene
/// text), a single action report (before and after), or a planner run.
struct SystemBubble: View {

    let message: ChatMessage

    private let imageHeight: CGFloat = 240

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 10
        ) {
            if message.runStatus != nil {
                runHeader
            } else if let observation = message.observation {
                SceneImageView(observation: observation)
                    .frame(height: imageHeight)
                if let timing = observation.timing {
                    Text("Perceived in \(timing.summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DisclosureGroup("Scene text · \(observation.elements.count) elements") {
                    Text(message.text)
                        .font(.system(
                            .caption,
                            design: .monospaced
                        ))
                        .textSelection(.enabled)
                        .padding(
                            .top,
                            4
                        )
                }
                .font(.caption.weight(.medium))
            } else if !message.text.isEmpty {
                Text(message.text)
                    .font(message.text.contains("\n")
                        ? .system(
                            .callout,
                            design: .monospaced
                        )
                        : .body)
                    .textSelection(.enabled)
            }

            if let report = message.report {
                HStack(spacing: 8) {
                    labeled("Before") { SceneImageView(observation: report.before) }
                    // No after-frame is a reading that could not be taken, not
                    // a blank one: the line beside it says what is known.
                    if let after = report.after {
                        labeled("After") { SceneImageView(observation: after) }
                    } else {
                        labeled("After") {
                            Text("not perceived")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: imageHeight + 18)
                footer("\(report.eventCount) input event\(report.eventCount == 1 ? "" : "s") · \(report.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
            }

            if message.runStatus != nil {
                if message.isRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Watch the live monitor while the agent works.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 32)
                } else if let final = message.finalObservation {
                    labeled("Last frame the agent saw") { SceneImageView(observation: final) }
                        .frame(height: imageHeight + 18)
                }
                if !message.reports.isEmpty { reportList }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.callout.weight(.medium))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .background(
            .quaternary,
            in: RoundedRectangle(
                cornerRadius: 18,
                style       : .continuous
            )
        )
        .frame(
            maxWidth : 760,
            alignment: .leading
        )
    }

    private var runHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: message.isRunning ? "brain.head.profile" : "checkmark.seal.fill")
                .foregroundStyle(message.isRunning ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
            Text(message.runStatus ?? "")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var reportList: some View {
        VStack(
            alignment: .leading,
            spacing  : 4
        ) {
            Text("Verified actions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(
                Array(message.reports.enumerated()),
                id: \.element.id
            ) { index, report in
                HStack(
                    alignment: .firstTextBaseline,
                    spacing  : 6
                ) {
                    // Green is the verified effect and nothing else: a scene
                    // that merely changed used to get the same tick.
                    Image(systemName: report.verification.outcome.symbol)
                        .foregroundStyle(report.verification.outcome.isVerified ? .green : .orange)
                    Text("\(index + 1). \(report.action.verb) \(report.action.targetDescription) \(report.targetLabel)")
                        .font(.caption.weight(.medium))
                    Text(report.verification.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Under the line rather than beside it: a note is a sentence,
                // and a refused menu names every title it was offered instead.
                if let note = report.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(
                            .leading,
                            20
                        )
                }
            }
        }
        .textSelection(.enabled)
    }

    private func labeled<Content: View>(
        _ title             : String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(
            alignment: .leading,
            spacing  : 4
        ) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
