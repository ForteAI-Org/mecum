//
//  UsageWordingTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import AgentTurn
import ChatCore
import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// A calendar in `locale`, in Rome's time zone, so the phrases do not follow this Mac's settings.
private func calendar(_ locale: String) -> Calendar {
    var calendar      = Calendar(identifier: .gregorian)
    calendar.locale   = Locale(identifier: locale)
    calendar.timeZone = TimeZone(identifier: "Europe/Rome") ?? .gmt
    return calendar
}

/// A turn on Codex that leaves `context` of `window` in the context.
private func turn(
    context: Int?,
    window : Int?
) -> TurnUsage {
    TurnUsage(
        provider     : .codex,
        model        : "gpt-5.6-luna",
        session      : "session",
        turn         : ProviderUsage.Tokens(
            input : 100,
            output: 10
        ),
        sessionTotal : nil,
        contextTokens: context,
        contextWindow: window,
        rateLimits   : []
    )
}

@Suite("The context ring's and the token counter's numbers and phrases")
struct UsageWordingTests {

    private let english = UsageWording(calendar: calendar("en_US"))

    @Test("Counts are compact as the locale abbreviates them, and spoken in words")
    func compactNumbers() {
        #expect([980, 12_000, 842_000, 1_200_000].map(english.compact) == ["980", "12K", "842K", "1.2M"])
        #expect([18_200, 16_100, 610].map(english.compact) == ["18.2K", "16.1K", "610"])
        // Italian writes millions as "Mln", after a no-break space.
        #expect(UsageWording(calendar: calendar("it_IT")).compact(1_200_000) == "1,2\u{00A0}Mln")
        #expect([980, 842_000, 1_200_000].map(english.spoken) == ["980", "842 thousand", "1.2 million"])
    }

    @Test("New tokens leave out cache reads, and count cache writes and output")
    func newTokensExcludeCacheReads() {
        // Claude's first turn in ticket 1's fixture: all of its input was written to the cache.
        let written = ProviderUsage.Tokens(
            input      : 3557,
            cacheWrites: 3555,
            output     : 4
        )
        #expect(UsageWording.newTokens(written) == 3557 + 4)

        let read = ProviderUsage.Tokens(
            input     : 3600,
            cacheReads: 3555,
            output    : 40,
            reasoning : 12
        )
        #expect(UsageWording.newTokens(read) == 3600 - 3555 + 40, "reasoning is already in the output")
    }

    @Test("A limit's window is named for a person, from its name or its minutes")
    func windowNames() {
        func name(
            _ window: String,
            minutes : Int? = nil
        ) -> String {
            UsageWording.windowName(ProviderUsage.RateLimit(
                window       : window,
                usedFraction : 0.5,
                windowMinutes: minutes
            ))
        }

        #expect(name("five_hour") == "5 hours")
        #expect(name("seven_day") == "Week")
        #expect(name(
            "primary",
            minutes: 10_080
        ) == "Week")
        #expect(name(
            "primary",
            minutes: 300
        ) == "5 hours")
        #expect(name("seven_day_opus") == "Seven day opus")
        #expect(UsageWording.plan(.claudeCode) == "Claude plan")
    }

    @Test("A reset later today is its time, within the week its weekday, later its date, and a past one nothing")
    func resetPhrases() throws {
        let rome    = calendar("en_GB")
        let now     = try #require(rome.date(from: DateComponents(
            year  : 2026,
            month : 9,
            day   : 25,
            hour  : 10
        )))
        let wording = UsageWording(
            calendar: rome,
            now     : now
        )

        #expect(wording.resets(now.addingTimeInterval(7.5 * 3_600)) == "resets 17:30")
        #expect(wording.resets(now.addingTimeInterval(3 * 86_400)) == "resets Monday")
        #expect(wording.resets(now.addingTimeInterval(10 * 86_400)) == "resets 5 Oct")
        #expect(wording.resets(now.addingTimeInterval(-60)) == nil)
    }

    @Test("The ring is green, orange from 70% and red from 90%; a plan's bar is amber from 75%")
    func thresholds() {
        #expect(UsageWording.contextLevel(0.69) == .roomy)
        #expect(UsageWording.contextLevel(0.7) == .filling)
        #expect(UsageWording.contextLevel(0.89) == .filling)
        #expect(UsageWording.contextLevel(0.9) == .full)
        #expect(!UsageWording.isLimitHigh(0.74))
        #expect(UsageWording.isLimitHigh(0.75))
    }

    @Test("The context reads as a share and as tokens, in the popover, the tooltip and to VoiceOver")
    func contextPhrases() {
        let context = WorkerUsage.Context(
            tokens: 142_318,
            window: 258_400
        )

        #expect(english.contextTitle(context) == "55% of context")
        #expect(english.contextTokens(context) == "142,318 of 258,400 tokens")
        #expect(english.contextUsed(context) == "55% · 142,318 of 258,400")
        #expect(english.contextTip(context) == "55% of context · 142K of 258K")
        #expect(english.contextSpoken(context) == "55 percent, 142,318 of 258,400 tokens")
    }

    @Test("No usage shows neither the counter nor the ring, and a context without a window shows no ring")
    func visibility() {
        #expect(UsageWording.counter(of: nil) == nil)
        #expect(UsageWording.ringContext(of: nil) == nil)

        let none = WorkerUsage(
            turns     : [],
            provider  : .codex,
            rateLimits: []
        )
        #expect(UsageWording.counter(of: none) == nil)
        #expect(UsageWording.ringContext(of: none) == nil)

        let unwindowed = WorkerUsage(
            turns     : [turn(
                context: 3_000,
                window : nil
            )],
            provider  : .codex,
            rateLimits: []
        )
        #expect(UsageWording.counter(of: unwindowed) == 110, "the counter needs only a turn")
        #expect(UsageWording.ringContext(of: unwindowed) == nil)

        let windowed = WorkerUsage(
            turns     : [turn(
                context: 3_000,
                window : 258_400
            )],
            provider  : .codex,
            rateLimits: []
        )
        #expect(UsageWording.ringContext(of: windowed)?.tokens == 3_000)
    }
}
