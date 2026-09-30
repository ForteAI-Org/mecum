import AppKit
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

    @Test
    func inputToolsAreListedWithTheirSchemas() throws {
        let tools = Dictionary(uniqueKeysWithValues: AutomationTools.definitions.map { ($0["name"].string ?? "", $0) })
        let required: [String: [String]] = [
            "type_text": ["session", "target", "text"], "press_key": ["session", "key"],
            "scroll": ["session", "direction"], "drag": ["session", "from"],
            "context_menu": ["session", "target", "item"], "menu": ["session", "path"], "press": ["session", "button"]
        ]
        for (name, fields) in required {
            let tool = try #require(tools[name], "missing tool \(name)")
            #expect(tool["inputSchema"]["required"].array?.compactMap(\.string) == fields)
            #expect(tool["annotations"]["readOnlyHint"] == .bool(false))
        }
        let key = tools["press_key"]?["inputSchema"]["properties"]
        let names = key?["key"]["enum"].array?.compactMap(\.string) ?? []
        #expect(["return", "tab", "escape", "space", "delete", "left", "up", "a", "z", "0", "9"]
            .allSatisfy(names.contains))
        #expect(key?["modifiers"]["items"]["enum"].array?.compactMap(\.string) == ["cmd", "shift", "opt", "ctrl"])
        #expect(key?["count"]["maximum"] == .number(Double(InputRequest.maximumKeyPresses)))
        let verbs = tools["act"]?["inputSchema"]["properties"]["verb"]["enum"].array?.compactMap(\.string) ?? []
        #expect(verbs.contains("triple_click"))
        let steps = tools["batch"]?["inputSchema"]["properties"]["steps"]["items"]["oneOf"].array ?? []
        #expect(steps.compactMap { $0["properties"]["operation"]["const"].string }
            == ["act", "select", "type_text", "press_key", "scroll", "drag", "context_menu"])
        #expect(!AutomationTools.instructions.contains("Typing, scrolling, keyboard shortcuts"))
        #expect(AutomationTools.instructions.contains("A file panel that just opened has no field focused yet"))
    }

    @Test
    func inputToolsReachTheSessionAsEngineInputs() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id).uuidString
        func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
            try await tools.call(name, .object(arguments.merging(["session": .string(id)], uniquingKeysWith: { $1 })))
        }
        let typed = try await call("type_text", ["target": .string("Project Name"), "text": .string("My Project")])
        #expect(typed["structuredContent"]["status"].string == "found_acted")
        _ = try await call("type_text", ["target": .string("Notes"), "text": .string(" more"), "replace": .bool(false),
                                         "section": .string("Inspector")])
        _ = try await call("press_key", ["key": .string("n"), "modifiers": .array([.string("cmd"), .string("shift")]),
                                         "count": .number(2)])
        _ = try await call("press_key", ["key": .string("return")])
        _ = try await call("scroll", ["direction": .string("down")])
        _ = try await call("scroll", ["direction": .string("up"), "lines": .number(5), "target": .string("List")])
        _ = try await call("drag", ["from": .string("Clip"), "to": .string("Timeline")])
        _ = try await call("drag", ["from": .string("Clip"), "dx": .number(-40)])
        _ = try await call("context_menu", ["target": .string("Search"), "item": .string("Select All")])
        #expect(session.inputs == [
            .typeText("My Project", into: "Project Name", replacing: true),
            .typeText(" more", into: "Notes", replacing: false),
            .pressKey(KeyChord(.character("n"), modifiers: [.command, .shift]), times: 2),
            .pressKey(KeyChord(.return), times: 1),
            .scroll(lines: -3, over: nil),
            .scroll(lines: 5, over: "List"),
            .drag(from: "Clip", to: .target("Timeline")),
            .drag(from: "Clip", to: .offset(dx: -40, dy: 0)),
            .contextMenu(on: "Search", item: "Select All"),
        ])
        #expect(session.sections[1] == "Inspector")
    }

    @Test
    func malformedInputsNeverReachTheSession() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        let malformed: [(String, [String: JSONValue])] = [
            ("press_key", ["key": .string("f13")]),
            ("press_key", ["key": .string("a"), "modifiers": .array([.string("hyper")])]),
            ("press_key", ["key": .string("a"), "count": .number(21)]),
            ("press_key", ["key": .string("a"), "count": .number(1.5)]),
            ("scroll", ["direction": .string("left")]),
            ("drag", ["from": .string("Clip")]),
            ("drag", ["from": .string("Clip"), "to": .string("Bin"), "dx": .number(3)]),
            ("type_text", ["target": .string("Name"), "text": .string("x"), "replace": .string("yes")]),
            ("context_menu", ["target": .string("Search")]),
        ]
        for (name, arguments) in malformed {
            do {
                _ = try await tools.call(name, .object(arguments.merging(["session": id], uniquingKeysWith: { $1 })))
                Issue.record("\(name) accepted \(arguments)")
            } catch {}
        }
        #expect(session.calls.isEmpty)
    }

    @Test
    func batchCarriesInputStepsAndStopsOnAnUnverifiedKey() async throws {
        let session = SyntheticSession()
        session.results = [.foundActed, .actedUnverified, .foundActed]
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.call("batch", .object([
            "session": .string(id.uuidString), "steps": .array([
                .object(["operation": .string("type_text"), "target": .string("Name"), "text": .string("Demo")]),
                .object(["operation": .string("press_key"), "key": .string("return")]),
                .object(["operation": .string("scroll"), "direction": .string("down")])
            ])
        ]))
        #expect(session.inputs == [.typeText("Demo", into: "Name", replacing: true),
                                   .pressKey(KeyChord(.return), times: 1)])
        #expect(result["structuredContent"]["status"].string == "stopped")
        #expect(result["structuredContent"]["verifiedSteps"] == .number(1))
    }
}

extension AutomationToolsTests {
    @Test
    func appsIsListedReadOnlyWithAnOptionalQuery() throws {
        let apps = try #require(AutomationTools.definitions.first { $0["name"].string == "apps" })
        #expect(apps["annotations"]["readOnlyHint"] == .bool(true))
        #expect(apps["inputSchema"]["required"] == .array([]))
        #expect(apps["inputSchema"]["properties"].object?.keys.sorted() == ["query"])
        #expect(apps["description"].string?.contains("then pass its bundleID to open_session") == true)
    }

    @Test
    func appsNeedsNoSessionAndReturnsTheCandidatesFields() async throws {
        let session = CatalogueSession(candidates: [
            ApplicationCandidate(name: "Pro Tools", bundleID: "com.avid.ProTools", version: "26.4.1.179",
                                 isRunning: false),
            ApplicationCandidate(name: "Pro Tools", bundleID: "com.example.ProTools", version: nil, isRunning: true,
                                 location: "~/Applications")
        ])
        let tools = AutomationTools(session: session)
        var records: [String] = []
        tools.record = { records.append($0) }
        let result = try await tools.call("apps", .object(["query": .string("pro tools")]))
        #expect(session.queries == ["pro tools"])
        #expect(result["structuredContent"] == .object(["applications": .array([
            .object(["name": .string("Pro Tools"), "bundleID": .string("com.avid.ProTools"),
                     "version": .string("26.4.1.179"), "running": .bool(false)]),
            .object(["name": .string("Pro Tools"), "bundleID": .string("com.example.ProTools"),
                     "running": .bool(true), "location": .string("~/Applications")])
        ])]))
        #expect(records.first?.hasPrefix("→ apps ") == true)
        #expect(records.last?.hasPrefix("← apps ") == true)

        _ = try await tools.call("apps", .null)
        #expect(session.queries == ["pro tools", nil])
    }

    @Test
    func appsListsSixtyAndCountsTheRest() async throws {
        let many = (1...61).map { ApplicationCandidate(name: "App \($0)", bundleID: "com.example.\($0)", version: nil,
                                                       isRunning: false) }
        let result = try await AutomationTools(session: CatalogueSession(candidates: many)).call("apps", .null)
        #expect(result["structuredContent"]["applications"].array?.count == 60)
        #expect(result["structuredContent"]["more"] == .string("1 more not listed; pass a query to find them."))
    }

    @Test
    func theDefaultListsRunningApplicationsOnly() async throws {
        let listed = try await SyntheticSession().applications(matching: nil)
        #expect(!listed.isEmpty)
        #expect(listed.allSatisfy { app in
            app.isRunning && NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
                .contains { $0.activationPolicy == .regular }
        })
        let finder = try await SyntheticSession().applications(matching: "com.apple.FINDER")
        #expect(finder.map(\.bundleID) == ["com.apple.finder"])
    }
}

/// CatalogueSession answers only apps, with a fixed list, and has no session to open.
@MainActor
private final class CatalogueSession: AutomationSessionOperating {
    let id: UUID? = nil
    let candidates: [ApplicationCandidate]
    var queries: [String?] = []

    init(candidates: [ApplicationCandidate]) { self.candidates = candidates }

    func applications(matching query: String?) async throws -> [ApplicationCandidate] {
        queries.append(query)
        return candidates
    }

    func open(application: String, window: String?) async throws -> SceneSnapshot { throw AutomationFailure("unused") }
    func observe() async throws -> SceneSnapshot { throw AutomationFailure("unused") }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func select(control: String, item: String) async throws -> ActOutcome { throw AutomationFailure("unused") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func close() async {}
}

/// SyntheticSession preserves call order and ID invalidation without touching a real application.
@MainActor
private final class SyntheticSession: AutomationSessionOperating {
    var id: UUID? = UUID()
    var calls: [String] = []
    var results: [ActOutcomeKind] = []
    var throwOnTarget: String?
    var inputs: [InputRequest.Input] = []
    var sections: [String?] = []
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

    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome {
        calls.append("deliver")
        inputs.append(input)
        sections.append(section)
        return ActOutcome(results.isEmpty ? .foundActed : results.removeFirst(), "synthetic input", scene: scene)
    }

    func close() async { calls.append("close"); id = nil }
}
