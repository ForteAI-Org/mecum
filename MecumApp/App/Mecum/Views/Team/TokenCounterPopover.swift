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
        UsagePopover {
            if let last = usage.lastTurn {
                UsageLastMessage(tokens: last.turn)

                Divider()
            }

            allTime

            if let provider, !usage.rateLimits.isEmpty {
                Divider()

                plan(of: provider)
            }
        }
    }

    // MARK: Sections

    private var allTime: some View {
        let lifetime = usage.lifetime

        return VStack(
            alignment: .leading,
            spacing  : 6
        ) {
            UsageSectionTitle(wording.allTime(
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
            UsageSectionTitle(UsageWording.plan(provider))

            ForEach(
                usage.rateLimits,
                id: \.window
            ) { limit in
                UsageMeter(
                    label   : UsageWording.windowName(limit),
                    value   : limitLine(limit),
                    fraction: limit.usedFraction,
                    fill    : UsageWording.isLimitHigh(limit.usedFraction) ? AnyShapeStyle(.orange)
                        : AnyShapeStyle(.secondary),
                    spoken  : wording.limitSpoken(limit)
                )
            }
        }
    }

    // MARK: Parts

    /// A count of tokens, compact, read as a sentence: "Input: 1.2 million tokens".
    private func row(
        _ label: String,
        count  : Int
    ) -> some View {
        UsageRow(
            label : label,
            value : wording.compact(count),
            spoken: "\(label): \(wording.spoken(count)) tokens"
        )
    }

    /// "13% · resets 17:30", or the share alone without a reset to come.
    private func limitLine(_ limit: ProviderUsage.RateLimit) -> String {
        let used = wording.percent(limit.usedFraction)
        return limit.resetsAt.flatMap(wording.resets).map { "\(used) · \($0)" } ?? used
    }

    /// Each model's new tokens, most first.
    private var models: [(model: String, count: Int)] {
        usage.byModel
            .map { (model: $0.key, count: UsageWording.newTokens($0.value)) }
            .sorted { $0.count > $1.count }
    }
}
