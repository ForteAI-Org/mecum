import AgentTurn
import AutomationRuntime
import ChatCore
import Darwin
import FileConversations
import Foundation
import ModelTransports
import SeatBroker
import SeatDriving

/// ChatCommand composes the terminal chat: the options, the conversation and its leases, the provider,
/// the desktop (one `SeatBroker` for this process and one `BrokeredAutomationSession` for the chat, the
/// app's way to the computer) and the `ChatHost` that drives them through the turn core the app's worker
/// runs with (`AgentTurnHost`), with the signals that stop it. Provider processes may exit between turns;
/// the desktop belongs to this process until release or shutdown.
enum ChatCommand {
    static func run(arguments: [String]) async throws {
        let options = try ChatOptions(arguments: arguments)
        if options.help { print(ChatOptions.usage); return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mecum", isDirectory: true)
        let history = options.historyDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? support.appendingPathComponent("Conversations", isDirectory: true)
        let store = try ConversationStore(directory: history)
        let saved = try store.list()
        if options.list {
            for item in saved { print("\(item.id.uuidString)  \(item.provider.rawValue)  \(item.model ?? "default")  \(item.title)") }
            if saved.isEmpty { print("No saved conversations.") }
            return
        }
        let interactive = isatty(STDIN_FILENO) != 0 && !options.once
        var conversation: Conversation?
        if let requested = options.resume {
            if requested == "last" {
                guard let last = saved.first else { throw ChatMenu.problem("No saved conversations.") }
                conversation = last
            } else {
                guard let id = UUID(uuidString: requested) else { throw ChatMenu.problem("--resume expects a UUID or last.") }
                conversation = try store.load(id)
            }
        } else if interactive && options.prompt == nil {
            conversation = try await ChatMenu.choose(saved)
        }
        if let existing = conversation {
            if let provider = options.provider, provider != existing.provider {
                throw ChatMenu.problem("A saved conversation belongs to \(existing.provider.rawValue). Start a new chat to change providers.")
            }
            if options.hasModelOption { conversation?.model = options.model }
        } else {
            let provider: ChatProvider
            if let selected = options.provider { provider = selected }
            else if interactive { provider = try await ChatMenu.provider() }
            else { throw ChatMenu.problem("Use --provider claude|codex for noninteractive chat.") }
            let model: String?
            if options.hasModelOption { model = options.model }
            else if interactive { model = try await ChatMenu.model(provider) }
            else { model = nil }
            conversation = Conversation(provider: provider, model: model)
        }
        guard let selected = conversation, let executable = ChatMenu.executable(selected.provider.rawValue) else {
            throw ChatMenu.problem("The selected provider CLI is not installed or is missing from PATH.")
        }
        // An effort the command line does not take for this model is refused here, before the first turn.
        if let effort = options.effort,
           let refusal = AgentTurnHost.effortRefusal(effort, commandLine: selected.provider, model: selected.model) {
            throw ChatMenu.problem(refusal)
        }
        let lease = try store.lease(selected.id)
        // One CLI chat host at a time owns the Driver. Provider turn subprocesses share that owner.
        let hostStore = try ConversationStore(directory: support.appendingPathComponent("ChatHost"))
        let hostLease = try hostStore.lease(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
        defer { withExtendedLifetime((lease, hostLease)) {} }
        let transcript = ChatTranscript(conversation: selected, store: store)
        try transcript.save()
        let knowledge = options.knowledgeDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? support.appendingPathComponent("Knowledge", isDirectory: true)
        // The living memory of the Knowledge directory, the app's and the vertical commands' too: one
        // memory.sqlite under it, opened now so its state is said before the first turn, closed by the host.
        let memory   = MemoryService(directory: knowledge)
        let workerID = UUID()
        // The desktop is the app's: the broker carries the research opt-in as its configuration, and the
        // session waits in its queue under an id stable for this chat (§22.3). Nothing opens a seat apart.
        let broker = SeatBroker(configuration: SeatBrokerConfiguration(allowUnvalidatedBuild: options.allowUnvalidated))
        if options.allowUnvalidated { print("seat: research opt-in for an unvalidated macOS build") }
        let desktop = BrokeredAutomationSession(
            broker            : broker,
            workerID          : workerID,
            memory            : memory,
            allowsDestructive : options.allowDestructive
        )
        if let folder = options.selectDiagnostics {
            let directory = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
            desktop.selectionDiagnostics = SelectionDiagnostics(directory: directory)
            print("select diagnostics: writing each select's images and diagnosis under \(directory.path)")
        }
        // The turn core (tools, router, loopback host, connection file, provider child) is the host's,
        // started on the first turn; the broker and its queue stay this command's.
        let host = ChatHost(
            broker          : broker,
            desktop         : desktop,
            transcript      : transcript,
            memory          : memory,
            workerID        : workerID,
            executable      : executable,
            bridgeExecutable: executablePath,
            workingDirectory: history.appendingPathComponent("ProviderWorkspace", isDirectory: true),
            role            : options.role,
            effort          : options.effort,
            allowsWebSearch : options.webSearch
        )
        let stopped = "\nStopped; conversation saved. Resume with --resume \(selected.id.uuidString)"
        let signals = TerminalSignals { _ in
            // The provider is interrupted now; the exit waits for the cleanup, the host's one task.
            let cleanup = host.stop()
            Task { @MainActor in
                await cleanup.value
                print(stopped)
                exit(130)
            }
        }
        defer { signals.stop() }
        print("\nMecum chat · \(selected.provider.displayName) · \(selected.model ?? "provider default")")
        print("Conversation: \(selected.id.uuidString)")
        print(await memory.ready().sentence)
        // The invocation's turn configuration, which a saved conversation does not keep.
        print("Turns: effort \(options.effort?.rawValue ?? "provider default") · web search "
              + "\(options.webSearch ? "on" : "off") · role \(options.role == nil ? "none" : "set")")
        if !selected.entries.isEmpty {
            print("Resuming saved context; application state will be observed again.")
            for entry in selected.entries.filter({ $0.kind == .user || $0.kind == .assistant }).suffix(4) {
                print("\(entry.kind.rawValue) › \(entry.text.prefix(400))")
            }
        }
        print("/help for commands. Ctrl+C stops and releases the Seat.\n")
        do {
            try await host.run(prompt: options.prompt, interactive: interactive, once: options.once) {
                await ChatMenu.read("You › ")
            }
        } catch is ChatStopped {
            // The signal's own task may print and exit first; whichever runs first ends the process.
            print(stopped)
            exit(130)
        }
    }

    private static var executablePath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
