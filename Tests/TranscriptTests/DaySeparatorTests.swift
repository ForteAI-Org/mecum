//
//  DaySeparatorTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Testing
@testable import Transcript
import Workspace

/// Day separators: one above the first message of each day, the day changing
/// at 00:00 in the calendar's time zone, named relative to now.
@Suite("Day separators: midnight, two days, relative names, time zones")
struct DaySeparatorTests {

    /// Midnight UTC after the fixture's origin, in fixture seconds: the origin is 06:13:20 UTC.
    private static let midnight: Double = 64_000

    private static func labels(_ items: [TranscriptItem]) -> [String] {
        items.compactMap { if case .daySeparator(let label) = $0.kind { label } else { nil } }
    }

    @Test("23:59:59 and 00:00:00 fall on two days, and each day's first message gets the separator")
    func midnightBoundary() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("Before midnight", at: Self.midnight - 1)
        try await fixture.say("Right at midnight", at: Self.midnight, byWorker: true)
        try await fixture.say("Later that night", at: Self.midnight + 60)

        let items = try await fixture.items(now: TranscriptFixture.at(Self.midnight + 3600))
        #expect(Self.labels(items) == ["Yesterday", "Today"])
        let kinds = items.map { if case .daySeparator = $0.kind { "day" } else { "row" } }
        #expect(kinds == ["day", "row", "day", "row", "row"])
        #expect(items[3].continuesGroup == false, "the separator starts a new group")
        #expect(items[2].id == .day(TranscriptFixture.at(Self.midnight)))
    }

    @Test("The same data gives the same separators, and a later instant renames them only")
    func deterministic() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("One", at: Self.midnight - 10)
        try await fixture.say("Two", at: Self.midnight + 10)
        let now   = TranscriptFixture.at(Self.midnight + 100)
        let first = try await fixture.items(now: now)
        #expect(first == (try await fixture.items(now: now)))

        let weekLater = try await fixture.items(now: TranscriptFixture.at(Self.midnight + 8 * 86_400))
        #expect(weekLater.map(\.id) == first.map(\.id))
        let calendar = TranscriptFixture.calendar()
        let day      = TranscriptFixture.at(Self.midnight - 10)
        let full     = day.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: calendar.locale ?? .current,
                                                      calendar: calendar, timeZone: calendar.timeZone))
        #expect(Self.labels(weekLater).first == full)
    }

    @Test("Within the current week a day is its weekday and date; before it, the full date")
    func weekdayThenFullDate() {
        let calendar = TranscriptFixture.calendar()
        // Saturday 16 May 2026, 12:00 UTC: Wednesday is in the same week, the Saturday before is not.
        let now       = Date(timeIntervalSince1970: 1_778_932_800)
        let wednesday = now.addingTimeInterval(-3 * 86_400)
        let lastWeek  = now.addingTimeInterval(-7 * 86_400)
        let style     = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar,
                                         timeZone: calendar.timeZone)
        #expect(calendar.isDate(wednesday, equalTo: now, toGranularity: .weekOfYear))
        #expect(TranscriptWording.day(wednesday, now: now, calendar: calendar)
            == wednesday.formatted(style.weekday(.wide).day().month(.wide)))
        #expect(TranscriptWording.day(wednesday, now: now, calendar: calendar).hasPrefix("Wednesday"))
        #expect(TranscriptWording.day(lastWeek, now: now, calendar: calendar).contains("2026"))
        #expect(TranscriptWording.day(now, now: now, calendar: calendar) == "Today")
    }

    @Test("A time zone change moves the boundary: the same messages are one day two hours east")
    func timeZoneChange() async throws {
        let fixture = try await TranscriptFixture()
        defer { fixture.discard() }
        try await fixture.say("Late in London", at: Self.midnight - 1800)
        try await fixture.say("Early in London", at: Self.midnight + 1800)
        let now = TranscriptFixture.at(Self.midnight + 7200)

        let utc  = try await fixture.items(now: now, calendar: TranscriptFixture.calendar("UTC"))
        let east = try await fixture.items(now: now, calendar: TranscriptFixture.calendar("Europe/Rome"))
        #expect(Self.labels(utc) == ["Yesterday", "Today"])
        #expect(Self.labels(east) == ["Today"])
        #expect(TranscriptFixture.withoutDays(utc).map(\.id) == TranscriptFixture.withoutDays(east).map(\.id))
    }
}
