//
//  CodexUsageTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import CLIProviders
import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// The thread the fixtures were recorded in, sanitized as they are.
private let thread = "01a0d908-f54a-7322-92e6-76acc3b6eab7"

private let luna = ModelSelection(
    provider: .codex,
    model   : "gpt-5.6-luna",
    effort  : .low
)

/// A recorded fixture: one turn's stdout, or an excerpt of the thread's rollout.
private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(name).jsonl")
}

/// What the decoder reports for a recorded turn's stdout.
@MainActor
private func reported(_ name: String) throws -> ProviderUsage {
    var decoder = ProviderEventDecoder(provider: .codex)
    let stdout  = try String(
        contentsOf: fixture(name),
        encoding  : .utf8
    )
    let events  = try stdout.split(separator: "\n").flatMap { try decoder.decode(Data($0.utf8)) }
    let usages  = events.compactMap { event -> ProviderUsage? in
        if case .usage(let usage) = event { usage } else { nil }
    }
    return try #require(usages.first)
}

private func temporaryDirectory() throws -> URL {
    let root = URL.temporaryDirectory.appending(path: "mecum-codex-usage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at                         : root,
        withIntermediateDirectories: true
    )
    return root
}

/// Today's rollout folder, as Codex names it in local time.
private func todaysFolder(in sessions: URL) -> URL {
    let date = Calendar.current.dateComponents(
        [.year, .month, .day],
        from: Date()
    )
    return sessions.appending(
        path         : String(
            format: "%04ld/%02ld/%02ld",
            date.year ?? 0,
            date.month ?? 0,
            date.day ?? 0
        ),
        directoryHint: .isDirectory
    )
}

private func place(
    _ source: URL,
    at file : URL
) throws {
    try FileManager.default.createDirectory(
        at                         : file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
        at: source,
        to: file
    )
}

@MainActor
@Suite("What a Codex turn cost")
struct CodexUsageTests {

    @Test func aTurnIsTheSessionTotalLessTheOneBeforeInTheSameSession() throws {
        let one = WorkerAgentHost.turnUsage(
            try reported("codex-turn1"),
            selection: luna,
            session  : thread,
            lastUsage: nil,
            rollout  : nil
        )
        let two = WorkerAgentHost.turnUsage(
            try reported("codex-compact"),
            selection: luna,
            session  : thread,
            lastUsage: one,
            rollout  : nil
        )
        #expect(one.turn.input == 16344)
        #expect(one.sessionTotal == one.turn)
        // The rollout's own count for the second call agrees: 16357 in, 16128 of it cached, 39 out.
        #expect(two.turn == ProviderUsage.Tokens(
            input      : 16357,
            cacheReads : 16128,
            cacheWrites: 0,
            output     : 39,
            reasoning  : 32
        ))
        #expect(two.sessionTotal?.input == 32701)
        #expect(two.model == "gpt-5.6-luna")

        let otherSession = WorkerAgentHost.turnUsage(
            try reported("codex-compact"),
            selection: luna,
            session  : "another-thread",
            lastUsage: one,
            rollout  : nil
        )
        #expect(otherSession.turn.input == 32701, "another session's total is not taken away")
    }

    @Test func theRolloutsLastTokenCountGivesTheContextTheWindowAndTheLimits() throws {
        let reading = try #require(CodexRollout.reading(of: fixture("codex-rollout-excerpt")))
        #expect(reading.contextTokens == 16554 + 5)
        #expect(reading.contextWindow == 258_400)
        #expect(reading.rateLimits == [
            ProviderUsage.RateLimit(
                window       : "primary",
                usedFraction : 0.18,
                resetsAt     : Date(timeIntervalSince1970: 1_790_751_282),
                windowMinutes: 10080
            ),
        ])
    }

    @Test func aMissingOrGarbledRolloutGivesNothing() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let garbled = root.appending(path: "rollout-garbled.jsonl")
        try Data([0xFF, 0x00, 0x7B, 0x0A, 0x22]).write(to: garbled)
        #expect(CodexRollout.reading(of: garbled) == nil)
        #expect(CodexRollout.reading(of: root.appending(path: "missing.jsonl")) == nil)
        let noCount = #"{"type":"event_msg","payload":{"type":"agent_message"}}"#
        #expect(CodexRollout.reading(from: Data(noCount.utf8)) == nil)
        #expect(CodexRollout.file(
            of: thread,
            in: root.appending(path: "no-sessions")
        ) == nil)
    }

    @Test func theRolloutIsFoundTodayAndInAnEarlierFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = root.appending(path: "sessions")
        let earlier  = sessions.appending(path: "2026/08/01/rollout-2026-08-01T10-00-00-\(thread).jsonl")
        try place(
            fixture("codex-rollout-excerpt"),
            at: earlier
        )
        #expect(CodexRollout.file(
            of: thread,
            in: sessions
        )?.lastPathComponent == earlier.lastPathComponent)

        let today = todaysFolder(in: sessions).appending(path: "rollout-2026-09-25T16-47-18-\(thread).jsonl")
        try place(
            fixture("codex-rollout-excerpt"),
            at: today
        )
        #expect(CodexRollout.file(
            of: thread,
            in: sessions
        )?.resolvingSymlinksInPath() == today.resolvingSymlinksInPath())
        #expect(CodexRollout.sessions(environment: ["CODEX_HOME": root.path]).lastPathComponent == "sessions")
        #expect(CodexRollout.sessions(environment: ["HOME": "/Users/someone"]).path == "/Users/someone/.codex/sessions")
    }

    /// Two turns of one thread through the host, with a stand-in for Codex that
    /// prints the recorded stdout and a `CODEX_HOME` holding the recorded rollout.
    @Test func aTurnThroughTheHostIsCountedFromTheLastAndReadFromTheRollout() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let stdout  = root.appending(path: "stdout.jsonl")
        let standIn = root.appending(path: "agent")
        try Data("#!/bin/sh\n/bin/cat >/dev/null\n/bin/cat '\(stdout.path)'\n".utf8).write(to: standIn)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: standIn.path
        )
        // The window is changed in this copy, so only a read of this `CODEX_HOME` can report it.
        let home    = root.appending(path: "codex")
        let rollout = todaysFolder(in: home.appending(path: "sessions")).appending(path: "rollout-x-\(thread).jsonl")
        try FileManager.default.createDirectory(
            at                         : rollout.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            String(
                contentsOf: fixture("codex-rollout-excerpt"),
                encoding  : .utf8
            ).replacingOccurrences(
                of  : "258400",
                with: "111111"
            ).utf8
        ).write(to: rollout)

        let host = WorkerAgentHost(
            workingDirectory: root.appending(path: "work"),
            bridgeExecutable: standIn,
            session         : { DesktopUnavailableSession() },
            agents          : { _ in (.codex, standIn) }
        )
        var usages: [TurnUsage] = []
        for (turn, name) in ["codex-turn1", "codex-compact"].enumerated() {
            try? FileManager.default.removeItem(at: stdout)
            try FileManager.default.copyItem(
                at: fixture(name),
                to: stdout
            )
            try await host.run(
                prompt              : "Say ok.",
                selection           : luna,
                sessionID           : turn == 0 ? nil : thread,
                role                : nil,
                lastUsage           : usages.last,
                inheritedEnvironment: ["CODEX_HOME": home.path]
            ) { event in
                if case .usage(let usage) = event { usages.append(usage) }
                if case .provider(.usage) = event { Issue.record("The provider's own usage was passed on.") }
            }
        }
        try await host.close()

        #expect(usages.map(\.turn.input) == [16344, 16357])
        #expect(usages.map(\.session) == [thread, thread])
        let last = try #require(usages.last)
        #expect(last.contextTokens == 16559)
        #expect(last.contextWindow == 111_111)
        #expect(last.rateLimits.map(\.windowMinutes) == [10080])
        #expect(last.provider == .codex)
    }
}
