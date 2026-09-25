//
//  WorkerAgentHost.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import Foundation
import LocalMCP
import ModelTransports

/// WorkerAgentHost answers one conversation, through a signed-in agent command
/// line with the same agent, tools and instructions as `mecum chat`, or through
/// Mecum's own loop over a model provider's transport (`ModelToolLoop`), with
/// the same tools. `WorkerAnswer` decides which, per turn, from the frozen
/// selection's provider.
///
/// It owns what `ChatCommand` composes for a terminal: `AutomationTools` over the
/// session its composer supplies, the router, the loopback MCP host, the connection
/// file (0600, in a 0700 temporary directory), the working directory and the
/// provider runner. The loopback host starts with the first command line turn
/// and lives until `close`, so each turn's provider child reconnects to the same
/// tools; a loop turn calls the tools directly and starts none of it.
///
/// One turn at a time: a second `run` while one is running is refused. The
/// host keeps no provider session of its own: the caller passes the one to
/// resume, and `WorkerTurnRecorder` keeps it on the conversation. A loop turn
/// has none, and remembers through the history the caller passes.
///
/// Stopping follows `ChatSignals`: pause the router, interrupt the provider,
/// then drain the router, close the session and wait for the child to stop,
/// all before `run` throws `CancellationError`. A loop turn stops the same way:
/// no new tool call, the model's stream cancelled, a call in flight finished,
/// then the session closed. A failed turn is never run again by this type.
@MainActor
final class WorkerAgentHost {

    private let workingDirectory: URL
    private let bridgeExecutable: URL
    private let tools           : AutomationTools
    private let router          : MCPRouter
    private let host            : LocalMCPHost
    private let provider        = CLIProvider()
    private let agents          : (ModelProvider) throws -> (ChatProvider, URL)
    private let transports      : (ModelSelection) -> any ModelTransport

    private var temporary     : URL?
    private var connectionFile: URL?

    /// The running loop turn's loop. Non-nil exactly while a loop turn runs.
    private var loop: ModelToolLoop?

    /// `close` calls waiting for the running loop turn to end, resumed as it ends.
    private var loopEndWaiters: [CheckedContinuation<Void, Never>] = []

    /// The running turn's receiver. Non-nil exactly while a turn runs.
    private var onEvent: (@MainActor (WorkerAgentEvent) -> Void)?

    /// Set by `stop` so a stop that lands before the provider starts still stops the turn.
    private var isStopRequested = false

    /// The provider session the running turn reported, if it reported one.
    private var reportedSession: String?

    /// True while a turn runs.
    var isRunning: Bool { onEvent != nil }

    /// `workingDirectory` is created 0700 on the first turn and must stay the
    /// same across turns: Claude Code finds a session to resume by it.
    /// `bridgeExecutable` is the helper the provider launches as
    /// `mecum-bridge mcp-bridge --connection <file>`, the arguments `mecum`
    /// takes for the same bridge. `session` is called once, here,
    /// for the desktop the tools drive; the host closes it after a failed or
    /// stopped turn and in `close`, and never builds a seat of its own (§22.3).
    /// `transports` makes the transport a loop turn talks through, once per
    /// turn, so it reads the connection settings as they are then.
    convenience init(
        workingDirectory: URL,
        bridgeExecutable: URL,
        session         : () -> any AutomationSessionOperating,
        transports      : @escaping (ModelSelection) -> any ModelTransport = { $0.transport() }
    ) {
        self.init(
            workingDirectory: workingDirectory,
            bridgeExecutable: bridgeExecutable,
            session         : session,
            agents          : Self.agent(for:),
            transports      : transports
        )
    }

    /// `agents` finds the command line for a provider; a test passes a stand-in,
    /// and a stand-in transport through `transports`.
    init(
        workingDirectory: URL,
        bridgeExecutable: URL,
        session         : () -> any AutomationSessionOperating,
        agents          : @escaping (ModelProvider) throws -> (ChatProvider, URL),
        transports      : @escaping (ModelSelection) -> any ModelTransport = { $0.transport() }
    ) {
        self.workingDirectory = workingDirectory
        self.bridgeExecutable = bridgeExecutable
        self.agents           = agents
        self.transports       = transports
        let tools  = AutomationTools(session: session())
        let router = MCPRouter(tools: AutomationTools.definitions) { name, arguments in
            try await tools.call(name, arguments)
        }
        self.tools  = tools
        self.router = router
        self.host   = LocalMCPHost(router: router)
        tools.record = { [weak self] text in self?.onEvent?(.tool(text)) }
    }

    /// What this app adds to the command line's text: its `open_session` launches an installed
    /// application, which the base text, written around `windows`, does not say.
    static let appInstructions = "In this app, open_session also opens an installed application that is "
        + "not running yet; you do not need to find it with windows first."

    /// What a model that cannot call tools is told instead of the tools' text.
    static let textOnlyInstructions = "You are Mecum's assistant. You have no tools in this conversation "
        + "and cannot see or use apps on this Mac."

    /// The instructions a worker's turn runs with: the base text first, then
    /// the app's line, and the worker's own instructions after them, never
    /// instead of them (§6.2). A model without tools gets `textOnlyInstructions`
    /// as its base, which names no tool.
    static func instructions(
        role    : String?,
        hasTools: Bool = true
    ) -> String {
        let base = hasTools ? AutomationTools.instructions + "\n" + appInstructions : textOnlyInstructions
        guard let role = role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty else {
            return base
        }
        return base + "\n\nYour role:\n" + role
    }

    /// Runs one turn and reports its events in order, then returns when the
    /// provider completed it. Throws `CancellationError` after `stop`, and the
    /// provider's failure otherwise; either way the router is drained and the
    /// session closed first, and nothing is retried.
    ///
    /// `sessionID` is the provider session to resume, or nil for a new one;
    /// the caller answers for it belonging to `selection.provider`. A loop turn
    /// ignores it and is sent `history` instead, the conversation before
    /// `prompt`; a command line turn ignores `history`.
    /// `inheritedEnvironment` is filtered through the Codex allow-list before
    /// it reaches the child, so no API key does (§7.3).
    func run(
        prompt              : String,
        selection           : ModelSelection,
        sessionID           : String?,
        role                : String?,
        history             : [TurnMessage] = [],
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        onEvent             : @escaping @MainActor (WorkerAgentEvent) -> Void
    ) async throws {
        guard self.onEvent == nil else {
            throw AutomationFailure("This worker is still responding. Wait for it to finish or stop the response.")
        }
        self.onEvent    = onEvent
        isStopRequested = false
        defer { self.onEvent = nil }

        if WorkerAnswer(provider: selection.provider) == .modelLoop {
            let loop  = ModelToolLoop { [tools] name, arguments in try await tools.call(name, arguments) }
            self.loop = loop
            defer {
                self.loop = nil
                let waiters    = loopEndWaiters
                loopEndWaiters = []
                for waiter in waiters { waiter.resume() }
            }
            do {
                try await loop.run(
                    transport: transports(selection),
                    role     : role,
                    history  : history,
                    prompt   : prompt,
                    onEvent  : onEvent
                )
            } catch {
                // The loop ends only after a tool call in flight has finished, so no action is cut short.
                await tools.session.close()
                throw error
            }
            return
        }

        let (chatProvider, executable) = try agents(selection.provider)
        guard FileManager.default.isExecutableFile(atPath: bridgeExecutable.path) else {
            throw AutomationFailure("Mecum is missing a required support component. The message was not sent. "
                                    + "Details: \(bridgeExecutable.path)")
        }
        let connection = try await start()
        // Codex keeps the instructions a session began with and ignores new ones when it resumes,
        // so a session that began with others is given the current ones once, ahead of the message.
        let instructions = Self.instructions(role: role)
        var message      = prompt
        if chatProvider == .codex, let sessionID, deliveredInstructions(to: sessionID) != instructions {
            message = Self.changedInstructions(instructions) + prompt
        }
        reportedSession = nil
        let turn = Self.turn(
            prompt              : message,
            provider            : chatProvider,
            selection           : selection,
            sessionID           : sessionID,
            role                : role,
            bridgeExecutable    : bridgeExecutable,
            connectionFile      : connection,
            workingDirectory    : workingDirectory,
            inheritedEnvironment: inheritedEnvironment
        )
        do {
            // A stop during `start` found no child to interrupt; it ends the turn here instead.
            if isStopRequested { throw CancellationError() }
            try await provider.run(turn, executable: executable, onStart: { onEvent(.processStarted($0)) }) { event in
                if case .session(let id) = event { self.reportedSession = id }
                onEvent(.provider(event))
            }
            if chatProvider == .codex, let session = reportedSession ?? sessionID {
                record(instructions, deliveredTo: session)
            }
        } catch {
            router.pause()
            await router.drain()
            await tools.session.close()
            await provider.waitUntilStopped()
            router.resume()
            throw error
        }
    }

    /// What a resumed Codex session is told when it began with other instructions.
    static func changedInstructions(_ instructions: String) -> String {
        "Your instructions changed since this conversation began. These replace the earlier ones in "
            + "full:\n\n\(instructions)\n\nThe person's message:\n\n"
    }

    /// Which instructions the worker's Codex session last received, kept beside its working folder's
    /// other files: one session per worker, and a record lost costs one more reminder.
    private struct DeliveredInstructions: Codable {
        let session     : String
        let instructions: String
    }

    private var instructionRecord: URL { workingDirectory.appending(path: "codex-instructions.json") }

    /// The instructions `session` last received, nil when this host never recorded any for it.
    private func deliveredInstructions(to session: String) -> String? {
        guard let data   = try? Data(contentsOf: instructionRecord),
              let record = try? JSONDecoder().decode(DeliveredInstructions.self, from: data),
              record.session == session
        else { return nil }
        return record.instructions
    }

    /// Records what `session` received. A write that fails only means the next turn reminds it again.
    private func record(_ instructions: String, deliveredTo session: String) {
        let record = DeliveredInstructions(session: session, instructions: instructions)
        try? JSONEncoder().encode(record).write(to: instructionRecord, options: .atomic)
    }

    /// Stops the running turn: no further tool call is accepted and the
    /// provider is interrupted. `run` then finishes the cleanup and throws.
    func stop() {
        guard onEvent != nil else { return }
        isStopRequested = true
        // A loop turn has no router or child to stop, and a paused router would refuse
        // the next command line turn.
        if let loop {
            loop.stop()
            return
        }
        router.pause()
        provider.cancel()
    }

    /// Ends the host: stops any turn, releases the session, closes the
    /// loopback host and removes the connection file's directory. The host
    /// is not used again afterwards. Throws when that directory could not be
    /// removed, after everything else has been released.
    func close() async throws {
        loop?.stop()
        router.pause()
        provider.cancel()
        // A loop turn's call in flight finishes before the session is closed, as the router's does.
        // The wait ignores cancellation: the stopped turn always ends and resumes it.
        if loop != nil { await withCheckedContinuation { loopEndWaiters.append($0) } }
        await router.drain()
        await tools.session.close()
        await provider.waitUntilStopped()
        host.stop()
        connectionFile = nil
        guard let temporary else { return }
        self.temporary = nil
        try FileManager.default.removeItem(at: temporary)
    }

    /// The turn exactly as the provider receives it. The effort is passed only
    /// when the model offers it, since `ModelSelection` is the one authority
    /// for which levels exist.
    static func turn(
        prompt              : String,
        provider            : ChatProvider,
        selection           : ModelSelection,
        sessionID           : String?,
        role                : String?,
        bridgeExecutable    : URL,
        connectionFile      : URL,
        workingDirectory    : URL,
        inheritedEnvironment: [String: String]
    ) -> ProviderTurn {
        let efforts = ModelSelection.supportedEfforts(provider: selection.provider, model: selection.model)
        return ProviderTurn(
            provider        : provider,
            model           : selection.model.isEmpty ? nil : selection.model,
            sessionID       : sessionID,
            prompt          : prompt,
            instructions    : instructions(role: role),
            bridgeExecutable: bridgeExecutable.path,
            connectionFile  : connectionFile.path,
            workingDirectory: workingDirectory.path,
            effort          : efforts.contains(selection.effort) ? selection.effort.rawValue : nil,
            environment     : CodexCLIClient.environment(from: inheritedEnvironment)
        )
    }

    /// The command line that answers for `provider`, found at its install
    /// location rather than on `PATH`.
    private static func agent(for provider: ModelProvider) throws -> (ChatProvider, URL) {
        switch (provider, WorkerAnswer(provider: provider)) {
        case (_, .notYet(let reason)):
            throw AutomationFailure("\(provider.title) can’t respond in this version. Details: \(reason).")
        case (_, .modelLoop):
            throw AutomationFailure("\(provider.title) responds through Mecum’s own loop and has no command line.")
        case (.claudeCode, .agent):
            return (.claude, try ClaudeCLIClient.executableURL())
        case (.codex, .agent):
            return (.codex, try CodexCLIClient.executableURL())
        case (.anthropic, .agent), (.gemini, .agent), (.ollama, .agent):
            throw AutomationFailure("\(provider.title) is marked as an agent, and this host has no command "
                                    + "line for it.")
        }
    }

    /// Starts the loopback host and writes its connection file, once. A start
    /// that fails part way releases what it made, so a later turn starts clean.
    private func start() async throws -> URL {
        if let connectionFile { return connectionFile }
        let files = FileManager.default
        do {
            try files.createDirectory(at: workingDirectory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let directory = files.temporaryDirectory.appendingPathComponent("mecum-worker-\(UUID().uuidString)")
            try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            temporary = directory
            let endpoint = try await host.start()
            let file = directory.appendingPathComponent("connection.json")
            try JSONEncoder().encode(endpoint).write(to: file, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            connectionFile = file
            return file
        } catch let primary {
            host.stop()
            if let temporary {
                self.temporary = nil
                do { try files.removeItem(at: temporary) }
                catch { throw AutomationFailure("The tool host did not start (\(primary)), and its temporary "
                                                + "directory could not be removed: \(temporary.path)") }
            }
            throw primary
        }
    }
}
