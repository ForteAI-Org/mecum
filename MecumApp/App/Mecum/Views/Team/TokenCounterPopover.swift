//
//  TokenCounterPopover.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import ModelTransports
import SwiftUI

/// TokenCounterPopover is where the worker's tokens went, in sections apart
/// by hairlines: its last message, its whole life with the new tokens of each
/// model when it used more than one, and its provider's plan limits, when the
/// provider reported any. It shows tokens and shares only, never money.
struct TokenCounterPopover: View {

    let workerName: String

    /// The provider the worker answers with now, whose limits `usage` holds.
    let provider  : ModelProvider?

    let usage     : WorkerUsage

    private let wording = UsageWording()

    var body: some View {
        VStack(
            alignment: .leading,
            spacing  : 12
        ) {
            if let last = usage.lastTurn {
                lastMessage(last.turn)

                Divider()
            }

            allTime

            if let provider, !usage.rateLimits.isEmpty {
                Divider()

                plan(of: provider)
            }
        }
        .font(.callout)
        .padding(16)
        .frame(
            width    : 280,
            alignment: .leading
        )
    }

    // MARK: Sections

    private func lastMessage(_ tokens: ProviderUsage.Tokens) -> some View {
        VStack(
            alignment: .leading,
            spacing  : 6
        ) {
            title("Last message")

            HStack {
                Text("In · cached · out")
                    .foregroundStyle(.secondary)

                Spacer()

                Text(wording.lastTurn(tokens))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(wording.lastTurnSpoken(tokens))
        }
    }

    private var allTime: some View {
        let lifetime = usage.lifetime

        return VStack(
            alignment: .leading,
            spacing  : 6
        ) {
            title(wording.allTime(
                worker: workerName,
                turns : usage.turns
            ))

            row(
                "Input",
                count: lifetime.input
            )
            row(
                "From cache",
                count: lifetime.cacheReads
            )
            row(
                "Output",
                count: lifetime.output
            )
            if lifetime.reasoning > 0 {
                row(
                    "Reasoning",
                    count: lifetime.reasoning
                )
            }

            if usage.byModel.count > 1 {
                Text("New tokens by model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(
                        .top,
                        4
                    )

                ForEach(
                    models,
                    id: \.model
                ) { entry in
                    row(
                        entry.model,
                        count: entry.count
                    )
                }
            }
        }
    }

    private func plan(of provider: ModelProvider) -> some View {
        VStack(
            alignment: .leading,
            spacing  : 10
        ) {
            title(UsageWording.plan(provider))

            ForEach(
                usage.rateLimits,
                id: \.window
            ) { limit in
                VStack(
                    alignment: .leading,
                    spacing  : 5
                ) {
                    HStack {
                        Text(UsageWording.windowName(limit))

                        Spacer()

                        Text(limitLine(limit))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    bar(limit.usedFraction)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(wording.limitSpoken(limit))
            }
        }
    }

    // MARK: Parts

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }

    /// A count of tokens, compact, read as a sentence: "Input: 1.2 million tokens".
    private func row(
        _ label: String,
        count  : Int
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(wording.compact(count))
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(wording.spoken(count)) tokens")
    }

    /// "13% · resets 17:30", or the share alone without a reset to come.
    private func limitLine(_ limit: ProviderUsage.RateLimit) -> String {
        let used = wording.percent(limit.usedFraction)
        return limit.resetsAt.flatMap(wording.resets).map { "\(used) · \($0)" } ?? used
    }

    /// A thin bar of the limit's share, grey, amber once it is high (`UsageWording.isLimitHigh`).
    private func bar(_ fraction: Double) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(UsageWording.isLimitHigh(fraction) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .scaleEffect(
                        x     : min(max(fraction, 0), 1),
                        y     : 1,
                        anchor: .leading
                    )
            }
            .frame(height: 3)
            .clipShape(Capsule())
    }

    /// Each model's new tokens, most first.
    private var models: [(model: String, count: Int)] {
        usage.byModel
            .map { (model: $0.key, count: UsageWording.newTokens($0.value)) }
            .sorted { $0.count > $1.count }
    }
}
