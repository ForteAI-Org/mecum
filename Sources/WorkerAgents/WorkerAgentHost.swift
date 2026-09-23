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

/// WorkerAgentHost answers one conversation through a signed-in agent command
/// line, with the same agent, tools and instructions as `mecum chat`.
///
/// It owns what `ChatCommand` composes for a terminal: `AutomationTools` over the
/// session its composer supplies, the router, the loopback MCP host, the connection
/// file (0600, in a 0700 temporary directory), the working directory and the
/// provider runner. The loopback host starts with the first turn and lives
/// until `close`, so each turn's provider child reconnects to the same tools.
///
/// One turn at a time: a second `run` while one is running is refused. The
/// host keeps no provider session of its own: the caller passes the one to
/// resume, and `WorkerTurnRecorder` keeps it on the conversation.
///
/// Stopping follows `ChatSignals`: pause the router, interrupt the provider,
/// then drain the router, close the session and wait for the child to stop,
/// all before `run` throws `CancellationError`. A failed turn is never run
/// again by this type.
@MainActor
public final class WorkerAgentHost {

    private let workingDirectory: URL
    private let bridgeExecutable: URL
    private let tools           : AutomationTools
    private let router          : MCPRouter
    private let host            : LocalMCPHost
    private let provider        = CLIProvider()
    private let agents          : (ModelProvider) throws -> (ChatProvider, URL)

    private var temporary     : URL?
    private var connectionFile: URL?

    /// The running turn's receiver. Non-nil exactly while a turn runs.
    private var onEvent: (@MainActor (WorkerAgentEvent) -> Void)?

    /// Set by `stop` so a stop that lands before the provider starts still stops the turn.
    private var isStopRequested = false

    /// True while a turn runs.
    public var isRunning: Bool { onEvent != nil }

    /// `workingDirectory` is created 0700 on the first turn and must stay the
    /// same across turns: Claude Code finds a session to resume by it.
    /// `bridgeExecutable` is the `mecum` the provider launches as
    /// `mecum mcp-bridge --connection <file>`. `session` is called once, here,
    /// for the desktop the tools drive; the host closes it after a failed or
    /// stopped turn and in `close`, and never builds a seat of its own (§22.3).
    public convenience init(
        workingDirectory: URL,
        bridgeExecutable: URL,
        session         : () -> any AutomationSessionOperating
    ) {
        self.init(workingDirectory: workingDirectory, bridgeExecutable: bridgeExecutable,
                  session: session, agents: Self.agent(for:))
    }

    /// `agents` finds the command line for a provider; a test passes a stand-in.
    init(
        workingDirectory: URL,
        bridgeExecutable: URL,
        session         : () -> any AutomationSessionOperating,
        agents          : @escaping (ModelProvider) throws -> (ChatProvider, URL)
    ) {
        self.workingDirectory = workingDirectory
        self.bridgeExecutable = bridgeExecutable
        self.agents           = agents
        let tools  = AutomationTools(session: session())
        let router = MCPRouter(tools: AutomationTools.definitions) { name, arguments in
            try await tools.call(name, arguments)
        }
        self.tools  = tools
        self.router = router
        self.host   = LocalMCPHost(router: router)
        tools.record = { [weak self] text in self?.onEvent?(.tool(text)) }
    }

    /// The instructions a worker's turn runs with: the base text first, and
    /// the worker's own instructions after it, never instead of it (§6.2).
    public static func instructions(role: String?) -> String {
        guard let role = role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty else {
            return AutomationTools.instructions
        }
        return AutomationTools.instructions + "\n\nYour role:\n" + role
    }

    /// Runs one turn and reports its events in order, then returns when the
    /// provider completed it. Throws `CancellationError` after `stop`, and the
    /// provider's failure otherwise; either way the router is drained and the
    /// session closed first, and nothing is retried.
    ///
    /// `sessionID` is the provider session to resume, or nil for a new one;
    /// the caller answers for it belonging to `selection.provider`.
    /// `inheritedEnvironment` is filtered through the Codex allow-list before
    /// it reaches the child, so no API key does (§7.3).
    public func run(
        prompt              : String,
        selection           : ModelSelection,
        sessionID           : String?,
        role                : String?,
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        onEvent             : @escaping @MainActor (WorkerAgentEvent) -> Void
    ) async throws {
        guard self.onEvent == nil else {
            throw AutomationFailure("This worker is still answering. Wait for it, or stop it first.")
        }
        self.onEvent    = onEvent
        isStopRequested = false
        defer { self.onEvent = nil }

        let (chatProvider, executable) = try agents(selection.provider)
        guard FileManager.default.isExecutableFile(atPath: bridgeExecutable.path) else {
            throw AutomationFailure("Mecum's tool bridge is missing at \(bridgeExecutable.path), so the "
                                    + "worker would answer without its tools. Nothing was sent.")
        }
        let connection = try await start()
        let turn = Self.turn(
            prompt              : prompt,
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
            try await provider.run(turn, executable: executable) { event in onEvent(.provider(event)) }
        } catch {
            router.pause()
            await router.drain()
            await tools.session.close()
            await provider.waitUntilStopped()
            router.resume()
            throw error
        }
    }

    /// Stops the running turn: no further tool call is accepted and the
    /// provider is interrupted. `run` then finishes the cleanup and throws.
    public func stop() {
        guard onEvent != nil else { return }
        isStopRequested = true
        router.pause()
        provider.cancel()
    }

    /// Ends the host: stops any turn, releases the session, closes the
    /// loopback host and removes the connection file's directory. The host
    /// is not used again afterwards. Throws when that directory could not be
    /// removed, after everything else has been released.
    public func close() async throws {
        router.pause()
        provider.cancel()
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
            throw AutomationFailure("\(provider.title) cannot answer: \(reason).")
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
