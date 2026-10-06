import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Testing
@testable import Mecum

@MainActor
struct ExternalMCPSessionTests {
    @Test func disabledCapabilityExposesNoToolsAndRejectsCalls() async throws {
        let desktop = SyntheticMCPDesktop()
        let session = ExternalMCPSession(profile: MCPClientProfile(name: "No access", desktop: false), session: desktop)
        let listed = await session.router.handle(request("tools/list"))
        #expect(listed?["result"]["tools"].array?.isEmpty == true)
        let call = await session.router.handle(request("tools/call", params: .object([
            "name": .string("select"), "arguments": .object([:])
        ])))
        #expect(call?["error"]["code"] == .number(-32602))
        #expect(desktop.selections == 0)
        await session.close()
        await session.close()
        #expect(desktop.closes == 1)
    }

    @Test func currentCatalogAndInstructionsDoNotPromiseUnportedFeatures() async throws {
        let session = ExternalMCPSession(profile: MCPClientProfile(name: "Synthetic"), session: SyntheticMCPDesktop())
        let listed = await session.router.handle(request("tools/list"))
        #expect(listed?["result"]["tools"].array == AutomationTools.definitions)
        let initialized = await session.router.handle(request("initialize"))
        let instructions = try #require(initialized?["result"]["instructions"].string)
        #expect(instructions.contains(AutomationTools.instructions))
        #expect(!instructions.contains("Each message from the person begins with Mecum's seat line"))
        await session.close()
    }

    private func request(_ method: String, params: JSONValue = .object([:])) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string(method), "params": params])
    }
}

/// A synthetic desktop for the real bundled bridge: no discovery, capture or input touches the Mac.
@MainActor
final class SyntheticMCPDesktop: AutomationSessionOperating {
    private(set) var id: UUID? = UUID()
    private(set) var selections = 0
    private(set) var closes = 0
    private let scene = SceneSnapshot(
        bundleID: "test.mcp", appName: "Synthetic Mixer", windowTitle: "Mixer",
        viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: []
    )

    func open(application: String, window: String?) async throws -> SceneSnapshot { scene }
    func observe() async throws -> SceneSnapshot { scene }
    func select(control: String, item: String) async throws -> ActOutcome {
        guard control == "Mono", item == "Stereo" else { throw AutomationFailure("Unexpected synthetic selection.") }
        selections += 1
        return ActOutcome(.foundActed, "Selected Stereo.", scene: scene)
    }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw AutomationFailure("Not used by this fixture.")
    }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw AutomationFailure("Not used by this fixture.")
    }
    func applications(matching query: String?) async throws -> [ApplicationCandidate] { [] }
    func close() async { id = nil; closes += 1 }
}
