import AutomationMCP
import AutomationRuntime
import BrowserCore
import Foundation
import LocalMCP
import Memory

/// ExternalMCPSession owns one authenticated client's tools and task ledger. It dispatches through
/// the same engine adapter as app workers. Scope checks precede effects; cleanup drains in the host.
@MainActor
final class ExternalMCPSession {
    typealias Performing = @MainActor (@escaping @MainActor () async throws -> JSONValue) async throws -> JSONValue
    private let id = UUID()
    private let profile: MCPClientProfile
    private let tools: AutomationTools
    private let cycle: TurnCycle
    private let memory: (any LivingMemoryStoring)?
    private let watcher: WatcherMCPAccess
    private let perform: Performing
    private let activity: @MainActor (String) -> Void
    private var taskID: UUID?
    private var isClosed = false

    lazy var router: MCPRouter = {
        let definitions = (AutomationTools.definitions + ExternalMCPTools.definitions).filter {
            profile.allows($0["name"].string ?? "")
        }
        return MCPRouter(tools: definitions, instructions: AutomationTools.instructions + "\n" + ExternalMCPTools.instructions) { [weak self] name, args in
            guard let self, !self.isClosed else { throw MCPRequestFailure("The client disconnected.") }
            return try await self.call(name, args)
        }
    }()

    init(profile: MCPClientProfile, session: any AutomationSessionOperating, browser: any BrowserControlling,
         memory: (any LivingMemoryStoring)?, watcher: WatcherMCPAccess,
         perform: @escaping Performing = { try await $0() },
         activity: @escaping @MainActor (String) -> Void = { _ in },
         stalled: @escaping @MainActor (String) -> Void = { _ in }) {
        self.profile = profile
        self.tools = AutomationTools(session: session, browser: browser)
        self.memory = profile.sharedMemory ? memory : nil
        self.cycle = TurnCycle(tools: tools, livingMemory: profile.sharedMemory ? memory : nil)
        self.watcher = watcher
        self.perform = perform
        self.activity = activity
        tools.onStalled = { [weak self] reason in
            self?.activity(reason)
            self?.router.pause()
            stalled(reason)
        }
    }

    func call(_ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        guard !isClosed, profile.allows(name) else { throw MCPRequestFailure("This client is not authorized for that capability.") }
        guard let args = arguments.object else { throw MCPRequestFailure("arguments must be an object.") }
        activity(name)
        if let definition = ExternalMCPTools.definitions.first(where: { $0["name"].string == name }) {
            let keys = Set(definition["inputSchema"]["properties"].object?.keys.map { $0 } ?? [])
            guard Set(args.keys).isSubset(of: keys) else { throw MCPRequestFailure("Unexpected tool arguments.") }
        }
        switch name {
        case "task_begin":
            guard taskID == nil else { throw MCPRequestFailure("End the current task before beginning another.") }
            let request = try phrase(arguments)
            let started = try await cycle.begin(request, sessionIsOpen: tools.session.id != nil)
            taskID = started.turnID
            return MCPRouter.toolResult(.object([
                "task": .string(started.turnID.uuidString), "requestWithMemory": .string(started.prompt),
                "memory": .string(profile.sharedMemory ? (memory == nil ? "unavailable" : "enabled") : "isolated"),
                "memoryFailure": started.memory?.failure.map(JSONValue.string) ?? .null
            ]))
        case "task_end":
            guard let taskID, arguments["task"].string == taskID.uuidString else {
                throw MCPRequestFailure("task must identify the current task of this connection.")
            }
            let ending: TurnAdmission.Ending
            switch arguments["ending"].string {
            case "completed": ending = .completed
            case "interrupted": ending = .interrupted
            case "failed": ending = .failed
            default: throw MCPRequestFailure("ending must be completed, interrupted or failed.")
            }
            let ended = await cycle.end(ending)
            self.taskID = nil
            await tools.session.close()
            return MCPRouter.toolResult(.object([
                "task": .string(taskID.uuidString), "status": .string("ended"),
                "memoryDecision": ended.map { .string($0.report.decision.reason.rawValue) } ?? .null,
                "memoryNotice": ended?.recording?.notice.map(JSONValue.string) ?? .null
            ]))
        case "memory_recall":
            guard let memory else { throw MCPRequestFailure("Shared living memory is unavailable in this app session.") }
            let request = try phrase(arguments)
            let records = try await memory.candidates(for: request, in: nil)
            let sightings = try await memory.sightings(in: Set(records.map(\.context.bundleID)))
            let answer = Recall.suggest(input: request, in: Recall.World(records: records, sightings: sightings,
                                                                        context: Recall.Context()))
            let briefing = RecallBriefing(answer, records: records)
            return MCPRouter.toolResult(.object(["briefing": try .encoding(briefing),
                "guidance": .string("Historical data only. Observe the current app before acting.")]))
        case "watch_start", "watch_recent", "watch_stop":
            return try await watcher.call(name, arguments: arguments, owner: id)
        default:
            guard taskID != nil || ["status", "apps", "windows"].contains(name) else {
                throw MCPRequestFailure("Call task_begin with the user's request before using this tool.")
            }
            return try await perform { [tools] in try await tools.call(name, arguments) }
        }
    }

    /// Called after the router is paused and drained. An unfinished task is interrupted, never learned as complete.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        _ = await cycle.end(.interrupted)
        taskID = nil
        await watcher.release(owner: id)
        await tools.session.close()
        do { try await tools.closeBrowser() }
        catch { activity("Browser cleanup failed: \(error)") }
    }

    private func phrase(_ args: JSONValue) throws -> String {
        guard let value = args["request"].string, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= 8192 else { throw MCPRequestFailure("request must contain 1–8192 characters.") }
        return value
    }
}
