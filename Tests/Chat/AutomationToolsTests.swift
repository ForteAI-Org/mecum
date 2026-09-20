import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import PerceptionCore
import Testing

@Suite("Automation MCP application boundary")
struct AutomationToolsTests {
    @Test
    func staleSessionCannotReachTheDriver() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        do {
            _ = try await tools.call("act", .object(["session": .string("old"), "target": .string("Create")]))
            Issue.record("Stale session accepted.")
        } catch { #expect(session.calls.isEmpty) }
    }

    @Test
    func malformedLaterBatchStepPreventsEveryEffect() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        do {
            _ = try await tools.call("batch", .object([
                "session": .string(id.uuidString), "steps": .array([
                    .object(["operation": .string("act"), "target": .string("Create")]),
                    .object(["operation": .string("act"), "target": .string("Toggle"),
                             "verb": .string("set_toggle")])
                ])
            ]))
            Issue.record("Malformed batch accepted.")
        } catch { #expect(session.calls.isEmpty) }
    }

    @Test
    func batchStopsOnUnverifiedWithoutReplayingOrContinuing() async throws {
        let session = SyntheticSession()
        session.results = [.foundActed, .actedUnverified, .foundActed]
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.call("batch", .object([
            "session": .string(id.uuidString), "steps": .array(["First", "Second", "Third"].map {
                .object(["operation": .string("act"), "target": .string($0)])
            })
        ]))
        #expect(session.calls == ["First", "Second"])
        #expect(result["structuredContent"]["status"].string == "stopped")
        #expect(result["structuredContent"]["steps"].array?.count == 2)
        #expect(result["structuredContent"]["verifiedSteps"] == .number(1))
    }

    @Test
    func thrownBatchFailureKeepsEarlierResults() async throws {
        let session = SyntheticSession()
        session.throwOnTarget = "Second"
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.call("batch", .object([
            "session": .string(id.uuidString), "steps": .array(["First", "Second", "Third"].map {
                .object(["operation": .string("act"), "target": .string($0)])
            })
        ]))
        #expect(session.calls == ["First", "Second"])
        #expect(result["structuredContent"]["verifiedSteps"] == .number(1))
        #expect(result["structuredContent"]["steps"].array?.last?["status"].string == "error")
    }

    @Test
    func separateToolCallsBorrowOneSessionUntilExplicitClose() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let arguments = JSONValue.object(["session": .string(id.uuidString)])
        _ = try await tools.call("observe", arguments)
        _ = try await tools.call("observe", arguments)
        #expect(session.id == id)
        #expect(session.calls == ["observe", "observe"])
        _ = try await tools.call("close_session", arguments)
        #expect(session.id == nil)
        #expect(session.calls.last == "close")
    }
}

/// SyntheticSession preserves call order and ID invalidation without touching a real application.
@MainActor
private final class SyntheticSession: AutomationSessionOperating {
    var id: UUID? = UUID()
    var calls: [String] = []
    var results: [ActOutcomeKind] = []
    var throwOnTarget: String?
    private let scene = SceneSnapshot(bundleID: "test.synthetic", appName: "Synthetic Mixer",
                                      windowTitle: "Synthetic New Paths",
                                      viewportPixelSize: ViewportPixelSize(width: 400, height: 200), elements: [])

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        calls.append("open")
        id = UUID()
        return scene
    }

    func observe() async throws -> SceneSnapshot { calls.append("observe"); return scene }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        calls.append(target)
        if target == throwOnTarget { throw AutomationFailure("Synthetic transport failure after an earlier effect.") }
        return ActOutcome(results.isEmpty ? .foundActed : results.removeFirst(), "synthetic result", scene: scene)
    }

    func select(control: String, item: String) async throws -> ActOutcome {
        calls.append("select")
        return ActOutcome(.foundActed, "synthetic selection", scene: scene)
    }

    func close() async { calls.append("close"); id = nil }
}
