//
//  ContextCompactionHostTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import AutomationRuntime
import ChatCore
import Foundation
import ModelTransports
import Testing
@testable import Mecum

/// The Claude session and the Codex thread the fixtures were recorded in, sanitized as they are.
private let claudeSession = "6a1474ca-08f7-4357-b19c-3f154fb27eaa"
private let codexThread   = "01a0d908-f54a-7322-92e6-76acc3b6eab7"

private let opus = ModelSelection(
    provider: .claudeCode,
    model   : "claude-opus-5",
    effort  : .low
)

private let luna = ModelSelection(
    provider: .codex,
    model   : "gpt-5.6-luna",
    effort  : .low
)

/// A recorded fixture: one turn's stdout, or an excerpt of a thread's rollout.
private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/\(name).jsonl")
}

/// A folder of its own for one test, which the test removes.
private func temporaryDirectory() throws -> URL {
    let root = URL.temporaryDirectory.appending(path: "mecum-compaction-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at                         : root,
        withIntermediateDirectories: true
    )
    return root
}

/// A stand-in command line in `root`, which is also the bridge the host asks
/// for: it keeps its arguments, one per line, and what it was sent, then runs `body`.
private func standIn(
    in root: URL,
    _ body : String
) throws -> URL {
    let file = root.appending(path: "agent")
    try Data("""
        #!/bin/sh
        printf '%s\\n' "$@" > '\(root.path)/arguments'
        cat > '\(root.path)/received'
        \(body)

        """.utf8).write(to: file)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: file.path
    )
    return file
}

private func arguments(in root: URL) throws -> [String] {
    try String(
        contentsOf: root.appending(path: "arguments"),
        encoding  : .utf8
    ).split(separator: "\n").map(String.init)
}

private func received(in root: URL) throws -> String {
    try String(
        contentsOf: root.appending(path: "received"),
        encoding  : .utf8
    )
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

@MainActor
@Suite("Compacting a worker's context through its host")
struct ContextCompactionHostTests {

    private func host(
        in root: URL,
        agent  : URL,
        as chat: ChatProvider
    ) -> WorkerAgentHost {
        WorkerAgentHost(
            workingDirectory: root.appending(path: "work"),
            bridgeExecutable: agent,
            session         : { DesktopUnavailableSession() },
            agents          : { _ in (chat, agent) }
        )
    }

    @Test func claudeCompactsOnlyWithSlashCommandsOnAndSucceedsOnTheBoundary() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try standIn(
            in: root,
            "cat '\(fixture("claude-compact-plain").path)'"
        )
        let host  = host(
            in   : root,
            agent: agent,
            as   : .claude
        )

        let done = try await host.compact(
            selection: opus,
            sessionID: claudeSession,
            role     : nil,
            trigger  : .manual
        )
        try await host.close()

        #expect(done.compaction == ContextCompaction(
            provider     : .claudeCode,
            trigger      : .manual,
            preTokens    : 3561,
            postTokens   : 1395,
            contextWindow: 1_000_000,
            summary      : nil
        ))
        #expect(done.usage == nil, "a compaction that reports no tokens records no turn")
        #expect(try received(in: root) == "/compact")
        let sent = try arguments(in: root)
        #expect(!sent.contains("--disable-slash-commands"))
        let resume = try #require(sent.firstIndex(of: "--resume"))
        #expect(sent[resume + 1] == claudeSession)
        #expect(!host.isRunning)
    }

    @Test func claudeFailsWhenTheCommandIsNotAvailable() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = try standIn(
            in: root,
            "cat '\(fixture("claude-compact-disabled").path)'"
        )
        let host  = host(
            in   : root,
            agent: agent,
            as   : .claude
        )

        do {
            _ = try await host.compact(
                selection: opus,
                sessionID: claudeSession,
                role     : nil,
                trigger  : .automatic
            )
            Issue.record("A refused /compact counted as a compaction.")
        } catch let failure as AutomationFailure {
            #expect(failure.description == "/compact isn't available in this environment.")
        }
        await #expect(throws: AutomationFailure.self) {
            _ = try await host.compact(
                selection: opus,
                sessionID: nil,
                role     : nil,
                trigger  : .manual
            )
        }
        try await host.close()
    }

    /// The stand-in writes a compaction into the rollout as Codex does, then
    /// prints the low-limit turn's recorded stdout.
    @Test func codexSucceedsOnANewCompactedLineAndItsTurnIsCounted() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home    = root.appending(path: "codex")
        let rollout = todaysFolder(in: home.appending(path: "sessions"))
            .appending(path: "rollout-x-\(codexThread).jsonl")
        try FileManager.default.createDirectory(
            at                         : rollout.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: fixture("codex-rollout-excerpt"),
            to: rollout
        )
        let agent = try standIn(
            in: root,
            """
            /usr/bin/python3 - <<'PY'
            import datetime, json
            now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3] + 'Z'
            count = {"type": "token_count", "rate_limits": None, "info": {"model_context_window": 258400,
                     "last_token_usage": {"input_tokens": 1200, "output_tokens": 5}}}
            with open('\(rollout.path)', 'a') as file:
                file.write(json.dumps({"timestamp": now, "type": "compacted", "payload": {"message": ""}}) + "\\n")
                file.write(json.dumps({"timestamp": now, "type": "event_msg", "payload": count}) + "\\n")
            PY
            cat '\(fixture("codex-lowlimit").path)'
            """
        )
        let host      = host(
            in   : root,
            agent: agent,
            as   : .codex
        )
        let before    = TurnUsage(
            provider     : .codex,
            model        : "gpt-5.6-luna",
            session      : codexThread,
            turn         : ProviderUsage.Tokens(input: 16357),
            sessionTotal : ProviderUsage.Tokens(
                input     : 32701,
                cacheReads: 27904,
                output    : 44,
                reasoning : 32
            ),
            contextTokens: 16396,
            contextWindow: 258_400,
            rateLimits   : []
        )

        let done = try await host.compact(
            selection           : luna,
            sessionID           : codexThread,
            role                : nil,
            trigger             : .automatic,
            lastUsage           : before,
            inheritedEnvironment: ["CODEX_HOME": home.path]
        )
        try await host.close()

        #expect(done.compaction == ContextCompaction(
            provider     : .codex,
            trigger      : .automatic,
            preTokens    : 16396,
            postTokens   : 1205,
            contextWindow: 258_400,
            summary      : nil
        ))
        let usage = try #require(done.usage)
        #expect(usage.turn == ProviderUsage.Tokens(
            input     : 49255 - 32701,
            cacheReads: 34944 - 27904,
            output    : 49 - 44
        ))
        #expect(usage.sessionTotal?.input == 49255)
        #expect(usage.contextTokens == 1205)
        #expect(try received(in: root) == WorkerAgentHost.codexCompactionPrompt)
        let sent  = try arguments(in: root)
        let limit = try #require(sent.firstIndex(of: "model_auto_compact_token_limit=1000"))
        #expect(sent[limit - 1] == "-c")
        #expect(sent.suffix(3) == ["resume", codexThread, "-"])
    }

    /// The rollout's only compaction is the recorded one, from before the turn began.
    @Test func codexFailsWhenTheRolloutShowsNoCompactionSinceTheTurnBegan() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home    = root.appending(path: "codex")
        let rollout = todaysFolder(in: home.appending(path: "sessions"))
            .appending(path: "rollout-x-\(codexThread).jsonl")
        try FileManager.default.createDirectory(
            at                         : rollout.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: fixture("codex-rollout-excerpt"),
            to: rollout
        )
        let agent = try standIn(
            in: root,
            "cat '\(fixture("codex-lowlimit").path)'"
        )
        let host  = host(
            in   : root,
            agent: agent,
            as   : .codex
        )

        do {
            _ = try await host.compact(
                selection           : luna,
                sessionID           : codexThread,
                role                : nil,
                trigger             : .manual,
                inheritedEnvironment: ["CODEX_HOME": home.path]
            )
            Issue.record("A Codex turn that did not compact counted as a compaction.")
        } catch let failure as AutomationFailure {
            #expect(failure.description == "Codex answered without compacting the conversation.")
        }
        try await host.close()
    }

    @Test func aStopDuringACompactionEndsItAndItsChild() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appending(path: "pid")
        let agent   = try standIn(
            in: root,
            """
            echo $$ > '\(pidFile.path).tmp' && mv '\(pidFile.path).tmp' '\(pidFile.path)'
            exec /bin/sleep 600
            """
        )
        let host    = host(
            in   : root,
            agent: agent,
            as   : .claude
        )
        let compaction = Task {
            try await host.compact(
                selection: opus,
                sessionID: claudeSession,
                role     : nil,
                trigger  : .manual
            )
        }

        var pid: pid_t?
        for _ in 0..<400 where pid == nil {
            try await Task.sleep(for: .milliseconds(25))
            // The stand-in moves the file into place whole, so existing means complete.
            guard FileManager.default.fileExists(atPath: pidFile.path) else { continue }
            pid = pid_t(try String(
                contentsOf: pidFile,
                encoding  : .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let child = try #require(pid)
        #expect(host.isRunning)

        host.stop()
        await #expect(throws: CancellationError.self) { _ = try await compaction.value }
        #expect(!host.isRunning)
        #expect(kill(child, 0) == -1 && errno == ESRCH)
        try await host.close()
    }
}
