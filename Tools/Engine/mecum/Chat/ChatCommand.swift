import AutomationMCP
import AutomationRuntime
import ChatCore
import CLIProviders
import Darwin
import FileConversations
import Foundation
import LocalMCP
import Memory
import PrivateSymbols
import SQLiteLivingMemory

/// ChatCommand composes the terminal, provider adapter, transcript store and one ephemeral MCP host.
/// Provider processes may exit between turns; the Seat belongs to this process until release or shutdown.
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
        let lease = try store.lease(selected.id)
        // One CLI chat host at a time owns the Driver. Provider turn subprocesses share that owner.
        let hostStore = try ConversationStore(directory: support.appendingPathComponent("ChatHost"))
        let hostLease = try hostStore.lease(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
        defer { withExtendedLifetime((lease, hostLease)) {} }
        let transcript = ChatTranscript(conversation: selected, store: store)
        try transcript.save()
        let knowledge = options.knowledgeDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? support.appendingPathComponent("Knowledge", isDirectory: true)
        // One living memory for the whole chat, open before any Seat and after every /release. A store
        // that cannot be opened is reported and left untouched; the chat then acts without learning.
        let livingMemory: SQLiteLivingMemoryStore?
        do {
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)
            livingMemory = try SQLiteLivingMemoryStore(file: file)
        } catch {
            print("memory: living memory unavailable, this chat will not learn (\(error))")
            livingMemory = nil
        }
        let tools = ChatTools(session: AutomationSession(knowledgeDirectory: knowledge,
                                                        allowsDestructive: options.allowDestructive,
                                                        livingMemory: livingMemory))
        tools.record = { text in
            print("  \(text.prefix(240))")
            try transcript.append(.tool, text)
        }
        // Each turn consults recall as data, collects typed tool events, and writes its one memory event
        // once the turn has ended and drained. A failed write is shown and kept; the action is not redone.
        let cycle = TurnCycle(tools: tools, livingMemory: livingMemory)
        let report: (TurnCycle.End?) -> Void = { end in
            guard let outcome = end?.recording, let notice = outcome.notice else { return }
            print(notice)
            guard case .failed = outcome else { return }
            do { try transcript.append(.tool, notice) }
            catch { fputs("mecum: transcript save failed: \(error)\n", stderr) }
        }
        if options.allowUnvalidated {
            FacilityGate.researchOptInForUnvalidatedBuilds = true
            print("seat: research opt-in for an unvalidated macOS build")
        }
        let router = MCPRouter(tools: ChatTools.definitions, instructions: ChatInstructions.standard) { name, arguments in
            try await tools.call(name, arguments)
        }
        let host = LocalMCPHost(router: router)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: temporary) }
            catch { fputs("mecum: could not remove temporary chat configuration: \(error)\n", stderr) }
        }
        let connectionFile = temporary.appendingPathComponent("connection.json")
        let working = history.appendingPathComponent("ProviderWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let endpoint = try await host.start()
        defer { host.stop() }
        try JSONEncoder().encode(endpoint).write(to: connectionFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: connectionFile.path)
        let provider = CLIProvider()
        tools.onStalled = { _ in
            router.pause()
            provider.cancel()
        }
        var shutdown: Task<Void, Never>?
        let signals = ChatSignals {
            router.pause()
            provider.cancel()
            shutdown = Task {
                await router.drain()
                report(await cycle.end(.interrupted))
                await tools.session.close()
                do { try await tools.closeBrowser() }
                catch { fputs("mecum: browser cleanup failed: \(error)\n", stderr) }
                await provider.waitUntilStopped()
                do { try transcript.append(.interrupted, "Interrupted. Inspect the current app state before continuing.") }
                catch { fputs("mecum: transcript save failed: \(error)\n", stderr) }
                host.stop()
                do { try FileManager.default.removeItem(at: temporary) }
                catch { fputs("mecum: temporary cleanup failed: \(error)\n", stderr) }
                print("\nStopped; conversation saved. Resume with --resume \(selected.id.uuidString)")
                exit(130)
            }
        }
        defer { signals.stop() }
        print("\nMecum chat · \(selected.provider.displayName) · \(selected.model ?? "provider default")")
        print("Conversation: \(selected.id.uuidString)")
        if !selected.entries.isEmpty {
            print("Resuming saved context; application state will be observed again.")
            for entry in selected.entries.filter({ $0.kind == .user || $0.kind == .assistant }).suffix(4) {
                print("\(entry.kind.rawValue) › \(entry.text.prefix(400))")
            }
        }
        print("/help for commands. Ctrl+C stops and releases the Seat.\n")
        var next = options.prompt
        do {
            while true {
                let line: String?
                if let pending = next { line = pending; next = nil }
                else if interactive { line = await ChatMenu.read("You › ") }
                else { break }
                guard let line else { break }
                let message = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if message.isEmpty { continue }
                if message == "/quit" || message == "/exit" { break }
                if message == "/help" { print(ChatOptions.usage); continue }
                if message == "/model" {
                    transcript.conversation.model = try await ChatMenu.model(selected.provider)
                    try transcript.save()
                    continue
                }
                if message == "/release" {
                    await tools.session.close()
                    do { try await tools.closeBrowser() }
                    catch { fputs("mecum: browser cleanup failed: \(error)\n", stderr) }
                    try transcript.append(.tool, "User released the Seat. Any previous session ID is now stale.")
                    print("Seat released.")
                    continue
                }
                if message == "/status" {
                    let result = try await tools.call("status", .object([:]))
                    print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
                    continue
                }
                if message.hasPrefix("/") { print("Unknown command. Use /help."); continue }
                try transcript.append(.user, message)
                let start = try await cycle.begin(message, sessionIsOpen: tools.session.id != nil)
                let memory = start.memory
                if let failure = memory?.failure {
                    print("memory: the living memory could not be read; this turn has no memory context (\(failure))")
                }
                if let failure = memory?.decisionFailure {
                    print("memory: the recall decision was not saved (\(failure))")
                }
                if let line = memory?.briefing?.contextLine {
                    print(line)
                    try transcript.append(.tool, line)
                }
                let turn = ProviderTurn(
                    provider: selected.provider, model: transcript.conversation.model,
                    sessionID: transcript.conversation.providerSessionID,
                    prompt: start.prompt,
                    instructions: ChatInstructions.standard, bridgeExecutable: executablePath,
                    connectionFile: connectionFile.path, workingDirectory: working.path
                )
                do {
                    try await provider.run(turn, executable: executable) { event in try transcript.event(event) }
                    await router.drain()
                    if let reason = tools.stalledReason { throw AutomationFailure(reason) }
                    report(await cycle.end(.completed))
                } catch {
                    if let shutdown { await shutdown.value; return }
                    router.pause()
                    await router.drain()
                    report(await cycle.end(.failed))
                    await tools.session.close()
                    do { try await tools.closeBrowser() }
                    catch { fputs("mecum: browser cleanup failed: \(error)\n", stderr) }
                    router.resume()
                    let failure = tools.stalledReason.map(AutomationFailure.init) ?? error
                    let reason = tools.stalledReason ?? error.localizedDescription
                    try transcript.append(.error, reason)
                    print("Chat error: \(reason)")
                    if !interactive { throw failure }
                }
                if options.once { break }
            }
            router.pause()
            await router.drain()
            await tools.session.close()
            do { try await tools.closeBrowser() }
            catch { fputs("mecum: browser cleanup failed: \(error)\n", stderr) }
            try transcript.save()
        } catch {
            if let shutdown { await shutdown.value; return }
            router.pause()
            await router.drain()
            report(await cycle.end(.failed))
            await tools.session.close()
            do { try await tools.closeBrowser() }
            catch { fputs("mecum: browser cleanup failed: \(error)\n", stderr) }
            throw error
        }
    }

    private static var executablePath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
