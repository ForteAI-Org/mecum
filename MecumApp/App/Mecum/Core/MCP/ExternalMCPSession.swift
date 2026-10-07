import AutomationMCP
import AutomationRuntime
import Foundation
import LocalMCP
import Memory

/// ExternalMCPSession exposes the current engine for one authenticated client connection.
/// The host serializes requests and drains them before closing this session. Disconnects
/// release its Seat; reconnects start fresh and never replay an earlier operation.
@MainActor
final class ExternalMCPSession {
    typealias Performing = @MainActor (@escaping @MainActor () async throws -> JSONValue) async throws -> JSONValue

    private let profile: MCPClientProfile
    private let tools: AutomationTools
    private let perform: Performing
    private let activity: @MainActor (String) -> Void
    private var isClosed = false

    lazy var router = MCPRouter(
        tools: profile.desktop ? AutomationTools.definitions : [],
        instructions: AutomationTools.instructions + "\n" + Self.instructions
    ) { [weak self] name, arguments in
        guard let self, !self.isClosed, self.profile.desktop else {
            throw MCPRequestFailure("This client is not authorized for desktop access.")
        }
        self.activity(name)
        return try await self.perform { [tools = self.tools] in
            try await tools.call(name, arguments)
        }
    }

    init(
        profile: MCPClientProfile,
        session: any AutomationSessionOperating,
        perform: @escaping Performing = { try await $0() },
        activity: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.profile = profile
        self.tools = AutomationTools(session: session)
        self.tools.producer = CallProducer(source: .mcp, streamID: "mcp-" + profile.id.uuidString)
        self.perform = perform
        self.activity = activity
    }

    static let instructions = "Mecum must remain open. open_session can launch an installed app: "
        + "use apps to find its exact bundle ID. Calls share the app’s Seat queue with its workers; "
        + "if a session expires, observe the current state before deciding what to do. "
        + "Reconnects start a fresh session and do not restore the previous session ID."

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await tools.session.close()
    }
}
