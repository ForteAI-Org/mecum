import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import Testing

@MainActor
@Suite("Menu tools and memory ledger")
struct MenuToolsTests {
    @Test func exposesBothRoutesAndRecordsNativeEvidence() async throws {
        let session = MenuToolSession()
        let tools = AutomationTools(session: session)
        let ledger = TurnLedger()
        ledger.begin(request: "Open I/O Setup")
        tools.onEvent = { ledger.record($0) }
        let id = JSONValue.string(try #require(session.id).uuidString)
        let catalog = try await tools.call("menus", .object(["session": id]))
        #expect(catalog["structuredContent"]["isComplete"].bool == true)
        let route = try await tools.call("resolve_action", .object(["session": id, "query": .string("Export")]))
        #expect(route["structuredContent"]["kind"].string == "ambiguous")
        _ = try await tools.call("menu", .object(["session": id, "path": .array([.string("Setup"), .string("I/O...")]),
                                                   "expect_window": .string("I/O Setup")]))
        #expect(session.invocations == 1)
        #expect(ledger.finish(.completed)?.decision.reason == .admittedSingleMenu)
    }

    @Test func generalMenuAndDialogPressDoNotTeachAnUnverifiedMemoryStep() async throws {
        for name in ["menu", "press"] {
            let session = MenuToolSession()
            let tools = AutomationTools(session: session)
            let ledger = TurnLedger()
            ledger.begin(request: "Use the explicit native command")
            tools.onEvent = { ledger.record($0) }
            var args: [String: JSONValue] = ["session": .string(try #require(session.id).uuidString)]
            args[name == "menu" ? "path" : "button"] = .string(name == "menu" ? "File > Save" : "OK")
            let result = try await tools.call(name, .object(args))
            #expect(result["structuredContent"]["status"].string == "found_acted")
            #expect(session.invocations == 1)
            #expect(ledger.finish(.completed)?.decision.reason != .admittedSingleMenu)
        }
    }

    @Test func startupMenuReadAndOpeningNeedNoExistingSession() async throws {
        let session = MenuToolSession()
        session.id = nil
        let tools = AutomationTools(session: session)
        let catalog = try await tools.call("menus", .object(["app": .string("Synthetic Editor")]))
        #expect(catalog["structuredContent"]["isComplete"].bool == true)
        let result = try await tools.call("open_recent", .object([
            "app": .string("Synthetic Editor"),
            "path": .array([.string("File"), .string("Open Recent"), .string("/Projects/Example.prproj")])
        ]))
        #expect(result["structuredContent"]["status"].string == "found_acted")
        #expect(result["structuredContent"]["session"].string != nil)
        #expect(session.invocations == 1)
    }

    @Test func startupRejectsMalformedPathsExistingSessionsAndAmbiguousMenuScope() async throws {
        let session = MenuToolSession()
        let tools = AutomationTools(session: session)
        for arguments: JSONValue in [.object([:]), .object(["app": .string("Editor"),
                "session": .string(try #require(session.id).uuidString)]),
                .object(["session": .string(UUID().uuidString)])] {
            await #expect(throws: (any Error).self) { _ = try await tools.call("menus", arguments) }
        }
        let fresh = AutomationTools(session: session)
        for path in [["File", "Open Recent", "/Projects/Example.prproj"], ["File", "Quit"]] {
            await #expect(throws: (any Error).self) {
                _ = try await fresh.call("open_recent", .object(["app": .string("Editor"),
                    "path": .array(path.map(JSONValue.string))]))
            }
        }
        #expect(session.invocations == 0)
    }

    @Test func smallStartupCaptureIsNotAReadySession() throws {
        var scene = MenuToolSession().scene
        scene.viewportPixelSize = .init(width: 66, height: 20)
        #expect(throws: MenuFailure.self) { try RecentDocumentRuntime.validateOpening(scene) }
    }

    @Test func malformedPathsAndStaleSessionCannotInvoke() async throws {
        let session = MenuToolSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        for path: JSONValue in [.string("Setup >> I/O..."), .array([.string("Setup"), .number(1)])] {
            await #expect(throws: (any Error).self) {
                _ = try await tools.call("menu", .object(["session": id, "path": path, "expect_window": .string("I/O Setup")]))
            }
        }
        await #expect(throws: (any Error).self) {
            _ = try await tools.call("menu", .object(["session": .string(UUID().uuidString),
                "path": .array([.string("Setup"), .string("I/O...")]), "expect_window": .string("I/O Setup")]))
        }
        #expect(session.invocations == 0)
    }
}

@MainActor
private final class MenuToolSession: AutomationSessionOperating {
    var id: UUID? = UUID()
    var invocations = 0
    let scene = SceneSnapshot(bundleID: "test.menu", appName: "Synthetic Editor", windowTitle: "Edit",
                              viewportPixelSize: .init(width: 800, height: 600),
                              elements: [.init(id: "export", kind: .control, label: "Export",
                                               bounds: .init(x: 0, y: 0, width: 0.1, height: 0.1))])
    func open(application: String, window: String?) async throws -> SceneSnapshot { scene }
    func observe() async throws -> SceneSnapshot { scene }
    func menus(application: String) throws -> MenuCatalog { try menus() }
    func openRecent(application: String, path: [String]) async throws -> ActOutcome {
        invocations += 1
        id = UUID()
        return ActOutcome(.foundActed, "Synthetic recent document verified", scene: scene)
    }
    func menus() throws -> MenuCatalog {
        .init(items: [.init(path: ["File", "Export"], isEnabled: true)], isComplete: true)
    }
    func resolveAction(_ query: String) async throws -> ActionRoute {
        try ActionRoute(query: query, scene: scene, catalog: menus())
    }
    func menu(path: [String], expectingWindow: String) async throws -> ActOutcome {
        invocations += 1
        return ActOutcome(.foundActed, "synthetic opening", evidence: .menu(.init(
            bundleID: scene.bundleID, windowTitle: scene.windowTitle, path: path,
            expectedWindow: expectingWindow, effect: .openedWindow)))
    }
    func menu(path: [String]) async throws -> ActOutcome {
        invocations += 1
        return ActOutcome(.foundActed, "Window changed, without a typed goal", scene: scene)
    }
    func press(button: String) async throws -> ActOutcome {
        invocations += 1
        return ActOutcome(.foundActed, "Dialog changed, without a typed goal", scene: scene)
    }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw MenuFailure("Unexpected UI action")
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw MenuFailure("Unexpected select") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { throw MenuFailure("Unexpected input") }
    func close() async { id = nil }
}
