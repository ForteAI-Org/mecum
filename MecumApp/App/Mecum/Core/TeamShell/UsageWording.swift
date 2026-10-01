//
//  UsageWording.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import Foundation
import ModelTransports

/// UsageWording is every number and phrase the context ring and the token
/// counter show or speak, and whether each is shown at all, in one place, so
/// what is drawn and what VoiceOver reads cannot drift apart. Numbers and
/// dates follow `calendar`'s locale and time zone; the words are English, as
/// the rest of the app's are.
///
/// The counter counts new tokens only: every input token not read from the
/// cache, and the output. Reasoning is not added, because Claude and Codex
/// both count it inside the output (`ProviderUsage.Tokens`).
nonisolated struct UsageWording {

    let calendar: Calendar

    /// What a reset is told relative to.
    let now     : Date

    init(
        calendar: Calendar = .autoupdatingCurrent,
        now     : Date     = Date()
    ) {
        self.calendar = calendar
        self.now      = now
    }

    private var locale: Locale { calendar.locale ?? .autoupdatingCurrent }

    // MARK: Visibility

    /// The context the ring draws, nil while its fill or its window is unknown, which hides the ring.
    static func ringContext(of usage: WorkerUsage?) -> WorkerUsage.Context? {
        guard let context = usage?.context, context.fraction != nil else { return nil }

        return context
    }

    /// The new tokens the counter shows, nil before the worker's first recorded turn, which hides it.
    static func counter(of usage: WorkerUsage?) -> Int? {
        guard let usage, usage.turns > 0 else { return nil }

        return newTokens(usage.lifetime)
    }

    static func newTokens(_ tokens: ProviderUsage.Tokens) -> Int {
        max(0, tokens.input - tokens.cacheReads) + tokens.output
    }

    /// How full the model's context is, as the ring and the context popover colour it.
    enum ContextLevel: Equatable {

        /// Below 70%: plenty of room, green.
        case roomy

        /// From 70%: filling up, orange.
        case filling

        /// From 90% of the available window: red.
        case full
    }

    static func contextLevel(_ fraction: Double) -> ContextLevel {
        fraction >= 0.9 ? .full : fraction >= 0.7 ? .filling : .roomy
    }

    /// A plan's bar turns amber from 75% of its limit.

    static func isLimitHigh(_ fraction: Double) -> Bool { fraction >= 0.75 }

    // MARK: Numbers

    /// "980", "12K", "1.2M", as the locale abbreviates them, to at most three significant digits.
    func compact(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)).locale(locale))
    }

    /// A count as VoiceOver reads the compact one: "980", "842 thousand", "1.2 million".
    func spoken(_ count: Int) -> String {
        let scales: [(unit: Double, word: String)] = [(1e9, "billion"), (1e6, "million"), (1e3, "thousand")]
        guard let scale = scales.first(where: { Double(count) >= $0.unit }) else { return whole(count) }

        let scaled = Double(count) / scale.unit
        return "\(scaled.formatted(.number.precision(.significantDigits(1...3)).locale(locale))) \(scale.word)"
    }

    /// "142,318".
    func whole(_ count: Int) -> String {
        count.formatted(.number.locale(locale))
    }

    /// "55%".
    func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "55 percent".
    func spokenPercent(_ fraction: Double) -> String {
        "\((fraction * 100).formatted(.number.precision(.fractionLength(0)).locale(locale))) percent"
    }

    // MARK: Context

    /// "55% of context".
    func contextTitle(_ context: WorkerUsage.Context) -> String {
        "\(percent(context.fraction ?? 0)) of context"
    }

    /// "142,318 of 258,400 tokens".
    func contextTokens(_ context: WorkerUsage.Context) -> String {
        "\(whole(context.tokens)) of \(whole(context.window ?? 0)) tokens"
    }

    /// The context popover's row: "55% · 142,318 of 258,400".
    func contextUsed(_ context: WorkerUsage.Context) -> String {
        "\(percent(context.fraction ?? 0)) · \(whole(context.tokens)) of \(whole(context.window ?? 0))"
    }

    /// The ring's tooltip: "55% of context · 142K of 258K".
    func contextTip(_ context: WorkerUsage.Context) -> String {
        "\(contextTitle(context)) · \(compact(context.tokens)) of \(compact(context.window ?? 0))"
    }

    /// The ring's accessibility value: "55 percent, 142,318 of 258,400 tokens".
    func contextSpoken(_ context: WorkerUsage.Context) -> String {
        "\(spokenPercent(context.fraction ?? 0)), \(contextTokens(context))"
    }

    /// The ring's tooltip and accessibility value while the context is compacted.
    static let compacting = "Compacting context…"

    /// Why the context popover's actions wait, said when one is used while the worker is busy.
    static func actionsWait(
        worker      : String,
        isCompacting: Bool
    ) -> String {
        isCompacting ? "Available when compacting finishes." : "Available when \(worker) finishes responding."
    }

    // MARK: Plan

    /// "Claude plan".
    static func plan(_ provider: ModelProvider) -> String { "\(provider.title) plan" }

    /// A limit's window as a person names it: Claude's `five_hour` is "5 hours" and
    /// `seven_day` is "Week", a window of 10,080 minutes is "Week", and any other is
    /// told from its minutes, or from its name when the provider gave none.
    static func windowName(_ limit: ProviderUsage.RateLimit) -> String {
        let named   = ["five_hour": 300, "seven_day": 10_080]
        let minutes = limit.windowMinutes ?? named[limit.window]
        guard let minutes, minutes > 0 else {
            let words = limit.window.replacingOccurrences(
                of  : "_",
                with: " "
            )
            return words.prefix(1).uppercased() + words.dropFirst()
        }

        switch minutes {
        case 10_080: return "Week"
        case 1_440 : return "Day"
        case 60    : return "Hour"
        default    : break
        }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440) days" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) hours" }

        return "\(minutes) minutes"
    }

    /// "resets 17:30" for a reset later today, "resets Friday" within the week,
    /// else "resets 3 Oct". Nil for a reset already past, which would read as the next one.
    func resets(_ date: Date) -> String? {
        guard date > now else { return nil }

        let style = Date.FormatStyle(
            locale  : locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        if calendar.isDate(
            date,
            inSameDayAs: now
        ) {
            return "resets \(date.formatted(style.hour().minute()))"
        }

        let weekAhead = calendar.date(
            byAdding: .day,
            value   : 7,
            to      : calendar.startOfDay(for: now)
        )
        if let weekAhead, date < weekAhead { return "resets \(date.formatted(style.weekday(.wide)))" }

        return "resets \(date.formatted(style.day().month(.abbreviated)))"
    }

    /// "5 hours: 13 percent used, resets 17:30".
    func limitSpoken(_ limit: ProviderUsage.RateLimit) -> String {
        let used = "\(Self.windowName(limit)): \(spokenPercent(limit.usedFraction)) used"
        return limit.resetsAt.flatMap(resets).map { "\(used), \($0)" } ?? used
    }

    // MARK: Popover

    /// The last message's input, cached input and output: "18.2K · 16.1K · 610".
    func lastTurn(_ tokens: ProviderUsage.Tokens) -> String {
        [tokens.input, tokens.cacheReads, tokens.output].map(compact).joined(separator: " · ")
    }

    /// "Last message: 18.2 thousand tokens in, 16.1 thousand cached, 610 out".
    func lastTurnSpoken(_ tokens: ProviderUsage.Tokens) -> String {
        let counts = [tokens.input, tokens.cacheReads, tokens.output].map(spoken)
        return "Last message: \(counts[0]) tokens in, \(counts[1]) cached, \(counts[2]) out"
    }

    /// "Atlas, all time · 12 messages".
    func allTime(
        worker: String,
        turns : Int
    ) -> String {
        "\(worker), all time · \(whole(turns)) \(turns == 1 ? "message" : "messages")"
    }
}
