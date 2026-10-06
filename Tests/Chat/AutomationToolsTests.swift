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
    @Test("shortcut guidance preserves target-specific support and observed file-panel state")
    func shortcutGuidanceMatchesQualifiedTargets() {
        let instructions = AutomationTools.instructions
        #expect(!instructions.contains("Command-C, Command-V, Command-A, Command-Z) do nothing"))
        #expect(instructions.contains("Shortcut support depends on the target and its current context"))
        #expect(instructions.contains("never automatically replay an action that may already have happened"))
        #expect(instructions.contains("observe its initial value"))
        #expect(!instructions.contains("Go to Folder opens with / in its field"))
    }

    @Test("exact native window titles distinguish an omitted selector from an untitled window")
    func nativeWindowTitleIsPreserved() async throws {
        let definition = try #require(AutomationTools.definitions.first { $0["name"].string == "open_session" })
        let titleSchema = definition["inputSchema"]["properties"]["window"]
        #expect(titleSchema["type"].string == "string")
        #expect(titleSchema["minLength"] == .null || titleSchema["minLength"] == .number(0))
        for title: String? in [nil, "", "  ", "Probe.png @ 100%"] {
            let session = SyntheticSession()
            session.id = nil
            let tools = AutomationTools(session: session)
            var arguments: [String: JSONValue] = ["app": .string("Synthetic Mixer")]
            if let title { arguments["window"] = .string(title) }
            _ = try await tools.call("open_session", .object(arguments))
            #expect(session.openedWindowTitles == [title])
            #expect(session.calls == ["open"])
        }
    }

    @Test("non-string window selectors refuse before opening a session")
    func malformedWindowTitleCannotOpen() async throws {
        for title: JSONValue in [.null, .bool(true), .number(109442), .array([]), .object([:])] {
            let session = SyntheticSession()
            session.id = nil
            let tools = AutomationTools(session: session)
            await #expect(throws: AutomationFailure.self) {
                try await tools.call("open_session", .object([
                    "app": .string("Synthetic Mixer"), "window": title
                ]))
            }
            #expect(session.calls.isEmpty)
            #expect(session.id == nil)
        }
    }

    @Test("Observation guidance follows the remaining session, without replaying a terminal failure", arguments: [true, false])
    func observationGuidanceMatchesSessionLifetime(_ ends: Bool) async throws {
        let session = SyntheticSession()
        session.observationFailure = AutomationFailure("Synthetic observation refusal.")
        session.endsWhenObserved = ends
        let id = try #require(session.id)
        var records: [String] = []
        let tools = AutomationTools(session: session)
        tools.record = { records.append($0) }
        await #expect(throws: AutomationFailure.self) {
            try await tools.call("observe", .object(["session": .string(id.uuidString)]))
        }
        #expect(session.calls == ["observe"])
        let record = try #require(records.last)
        if ends {
            #expect(session.id == nil)
            #expect(!record.contains("Observe before any retry"))
            #expect(record.contains("Use status"))
        } else {
            #expect(session.id == id)
            #expect(record.contains("Observe before any retry"))
        }
    }

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

    @Test("A terminal batch failure keeps prior effects and never advises observing its ended ID")
    func aTerminalBatchFailureNeedsDiscovery() async throws {
        let session = SyntheticSession()
        session.throwOnTarget = "Second"
        session.endsWhenActFails = true
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.call("batch", .object([
            "session": .string(id.uuidString), "steps": .array(["First", "Second", "Third"].map {
                .object(["operation": .string("act"), "target": .string($0)])
            })
        ]))
        #expect(session.calls == ["First", "Second"])
        #expect(session.id == nil)
        #expect(result["structuredContent"]["verifiedSteps"] == .number(1))
        let guidance = try #require(result["structuredContent"]["steps"].array?.last?["guidance"].string)
        #expect(guidance.contains("Earlier effects remain"))
        #expect(guidance.contains("Use status"))
        #expect(!guidance.contains("Observe before"))
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
    func closingReportsPendingApplicationCleanupAlongsideTheReleasedSeat() async throws {
        let session = SyntheticSession()
        let warning = "TextEdit is still running after the quit request."
        session.closeWarning = warning
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        let result = try await tools.call("close_session", .object(["session": .string(id.uuidString)]))

        #expect(session.id == nil)
        #expect(result["structuredContent"]["status"].string == "closed")
        #expect(result["structuredContent"]["warning"].string == warning)
    }

    @Test
    func windowsUsesTheSessionsDiscoveryWithoutOpeningASeat() async throws {
        let finder = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let session = SyntheticSession()
        session.discoveryRows = [WindowRow(layer: 0, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                           title: "Owned offscreen fixture", number: 987_654)]
        let result = try await AutomationTools(session: session).call("windows", .object([
            "app": .string("com.apple.finder")
        ]))
        #expect(session.discoveryReads == [finder.processIdentifier])
        #expect(session.calls.isEmpty)
        #expect(result["structuredContent"]["applications"].array?.first?["windows"] == .array([
            .object(["id": .number(987_654), "title": .string("Owned offscreen fixture")])
        ]))
    }

    @Test
    func inputToolsAreListedWithTheirSchemas() throws {
        let tools = Dictionary(uniqueKeysWithValues: AutomationTools.definitions.map { ($0["name"].string ?? "", $0) })
        let required: [String: [String]] = [
            "type_text": ["session", "target", "text"], "insert_text": ["session", "text"],
            "press_key": ["session", "key"],
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
            == ["act", "select", "type_text", "insert_text", "press_key", "scroll", "drag", "context_menu"])
        #expect(!AutomationTools.instructions.contains("Typing, scrolling, keyboard shortcuts"))
        #expect(AutomationTools.instructions.contains("may need explicit focus before accepting keys"))
        #expect(AutomationTools.instructions.contains("use the browser apps marks as the default"))
        #expect(AutomationTools.instructions.contains("its other visible windows move to the seat's display too"))
    }

    @Test
    func insertionPreservesTheExistingFocusWithoutATarget() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id).uuidString
        let result = try await tools.call("insert_text", .object([
            "session": .string(id), "text": .string("Mecum-à-中-🙂")
        ]))
        #expect(result["structuredContent"]["status"].string == "found_acted")
        #expect(session.inputs.count == 1)
        #expect(session.inputs == [.insertText("Mecum-à-中-🙂")])
        #expect(session.sections == [nil])
        _ = try await tools.call("insert_text", .object([
            "session": .string(id), "text": .string("Mecum"),
            "expected_value": .string("prefix Mecum suffix")
        ]))
        #expect(session.inputs.last == .insertText("Mecum", expecting: "prefix Mecum suffix"))
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
            ("insert_text", ["text": .string("")]),
            ("insert_text", ["text": .string("x"), "target": .string("Name")]),
            ("insert_text", ["text": .string("x"), "expected_value": .bool(true)]),
            ("insert_text", ["text": .string("x"), "expected_value": .string("")]),
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
    func batchStopsBeforeReturnWhenInsertionIsUnverified() async throws {
        let session = SyntheticSession()
        session.results = [.actedUnverified, .foundActed]
        let result = try await AutomationTools(session: session).call("batch", .object([
            "session": .string(try #require(session.id).uuidString), "steps": .array([
                .object(["operation": .string("insert_text"), "text": .string("Mecum")]),
                .object(["operation": .string("press_key"), "key": .string("return")])
            ])
        ]))
        #expect(session.inputs == [.insertText("Mecum")])
        #expect(result["structuredContent"]["status"].string == "stopped")
        #expect(result["structuredContent"]["attemptedSteps"] == .number(1))
        #expect(result["structuredContent"]["verifiedSteps"] == .number(0))
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
        #expect(apps["description"].string?.contains("defaultBrowser on the browser that opens web links") == true)
    }

    @Test
    func appsMarksTheDefaultBrowserAndOnlyIt() async throws {
        let session = CatalogueSession(candidates: [
            ApplicationCandidate(name: "Browser", bundleID: "com.example.Browser", version: "1.0", isRunning: true,
                                 isDefaultBrowser: true),
            ApplicationCandidate(name: "Other Browser", bundleID: "com.example.Other", version: nil, isRunning: true)
        ])
        let result = try await AutomationTools(session: session).call("apps", .null)
        #expect(result["structuredContent"] == .object(["applications": .array([
            .object(["name": .string("Browser"), "bundleID": .string("com.example.Browser"),
                     "version": .string("1.0"), "running": .bool(true), "defaultBrowser": .bool(true)]),
            .object(["name": .string("Other Browser"), "bundleID": .string("com.example.Other"),
                     "running": .bool(true)])
        ])]))
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

extension AutomationToolsTests {
    /// A window titled `title` whose one section lists a control for each of `rows`.
    private static func scene(_ rows: [String], title: String = "Synthetic New Paths") -> SceneSnapshot {
        SceneSnapshot(
            bundleID         : "test.synthetic",
            appName          : "Synthetic Mixer",
            windowTitle      : title,
            viewportPixelSize: ViewportPixelSize(width: 400, height: 200),
            elements         : rows.enumerated().map { index, label in
                SceneElement(id: "row\(index)", kind: .control, label: label,
                             bounds: NormalizedRect(x: 0.1, y: 0.04 * Double(index), width: 0.2, height: 0.03),
                             section: "Tracks")
            },
            sections         : [SceneSection(name: "Tracks",
                                             bounds: NormalizedRect(x: 0, y: 0, width: 1, height: 1))]
        )
    }

    private static let rows = (1...20).map { "Track \($0) volume" }

    @Test
    func anActionSendsOnlyTheChangesSinceTheSceneTheModelRead() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        session.scene = Self.scene(Self.rows)
        let observed = try await tools.call("observe", .object(["session": id]))["structuredContent"]
        #expect(observed["scene"].string == session.scene.text())
        #expect(observed["changes"] == .null)

        session.scene = Self.scene(Self.rows.map { $0 == "Track 7 volume" ? "Track 7 muted" : $0 })
        let acted = try await tools.call("act", .object(["session": id, "target": .string("Track 7")]))
        let observation = acted["structuredContent"]["observation"]
        let changes = try #require(observation["changes"].string)
        #expect(observation["scene"] == .null)
        #expect(observation["since"] == observed["revision"])
        #expect(changes.contains("\nSection: Tracks"))
        #expect(changes.contains("\n-     [control] Track 7 volume"))
        #expect(changes.contains("\n+     [control] Track 7 muted"))
        #expect(!changes.contains("Track 8"))

        #expect(observation["revision"] == .number(2))
        let again = try await tools.call("act", .object(["session": id, "target": .string("Track 7")]))
        #expect(again["structuredContent"]["observation"]["changes"] == .string("Unchanged since revision 2."))
    }

    @Test("an action's scene of another window, or one that changed in most of its lines, is sent whole",
          arguments: [true, false])
    func anotherWindowOrALargeChangeSendsTheWholeScene(_ isAnotherWindow: Bool) async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.call("observe", .object(["session": id]))
        let after = isAnotherWindow ? Self.scene(Self.rows, title: "Another window")
            : Self.scene(Self.rows.map { $0 + " (soloed)" })
        session.scene = after
        let acted = try await tools.call("act", .object(["session": id, "target": .string("Track 1")]))
        #expect(acted["structuredContent"]["observation"]["scene"].string == after.text())
        #expect(acted["structuredContent"]["observation"]["changes"] == .null)
    }

    @Test
    func anActionAfterTheSceneIsForgottenSendsItWhole() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = JSONValue.string(try #require(session.id).uuidString)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.call("observe", .object(["session": id]))

        tools.forgetScene()
        let acted = try await tools.call("act", .object(["session": id, "target": .string("Track 1")]))
        #expect(acted["structuredContent"]["observation"]["scene"].string == session.scene.text())
        #expect(acted["structuredContent"]["observation"]["changes"] == .null)
    }

    @Test
    func closingTheSessionForgetsTheSceneTheModelRead() async throws {
        let session = SyntheticSession()
        let tools = AutomationTools(session: session)
        let id = try #require(session.id)
        session.scene = Self.scene(Self.rows)
        _ = try await tools.call("observe", .object(["session": .string(id.uuidString)]))
        _ = try await tools.call("close_session", .object(["session": .string(id.uuidString)]))
        // The synthetic session takes its old ID back: only a forgotten baseline makes this scene whole.
        session.id = id
        let acted = try await tools.call("act", .object([
            "session": .string(id.uuidString), "target": .string("Track 1")
        ]))
        #expect(acted["structuredContent"]["observation"]["scene"].string == session.scene.text())
        #expect(acted["structuredContent"]["observation"]["changes"] == .null)
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
    var closeWarning: String?
    var calls: [String] = []
    var openedWindowTitles: [String?] = []
    var results: [ActOutcomeKind] = []
    var throwOnTarget: String?
    var observationFailure: AutomationFailure?
    var endsWhenObserved = false
    var endsWhenActFails = false
    var inputs: [InputRequest.Input] = []
    var sections: [String?] = []
    var discoveryRows: [WindowRow] = []
    var discoveryReads: [pid_t] = []
    var scene = SceneSnapshot(bundleID: "test.synthetic", appName: "Synthetic Mixer",
                              windowTitle: "Synthetic New Paths",
                              viewportPixelSize: ViewportPixelSize(width: 400, height: 200), elements: [])

    func open(application: String, window: String?) async throws -> SceneSnapshot {
        calls.append("open")
        openedWindowTitles.append(window)
        id = UUID()
        return scene
    }

    func observe() async throws -> SceneSnapshot {
        calls.append("observe")
        if let observationFailure {
            if endsWhenObserved { id = nil }
            throw observationFailure
        }
        return scene
    }

    func windowCandidates(ownedBy processID: pid_t) throws -> [WindowRow] {
        discoveryReads.append(processID)
        return discoveryRows
    }

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        calls.append(target)
        if target == throwOnTarget {
            if endsWhenActFails { id = nil }
            throw AutomationFailure("Synthetic transport failure after an earlier effect.")
        }
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
