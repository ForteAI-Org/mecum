import AppKit
import AutomationMCP
import AutomationRuntime
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
import SeatCore
import SQLite3
import SQLiteMemory
import Synchronization
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
            "context_menu": ["session", "target", "item"]
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

    func open(application: String, window: String?, context: ActionContext) async throws -> SceneSnapshot {
        throw AutomationFailure("unused")
    }
    func observe(context: ActionContext) async throws -> SceneSnapshot { throw AutomationFailure("unused") }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?,
             context: ActionContext) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func select(control: String, item: String, context: ActionContext) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func deliver(_ input: InputRequest.Input, section: String?, context: ActionContext) async throws -> ActOutcome {
        throw AutomationFailure("unused")
    }
    func close() async {}
}

/// SyntheticSession preserves call order and ID invalidation without touching a real application. Given
/// a memory, it records what a real session records for an observation (the `current` sample under the
/// call's event, or under an observation event of its own after `open`), so the tools' structured
/// results are proven against real rows; it never claims a sample it did not write.
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
                                      viewportPixelSize: ViewportPixelSize(width: 400, height: 200), elements: [
        SceneElement(id: "control|create", kind: .control, label: "Create",
                     bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.05), role: "AXButton")
    ])

    /// The memory an observation's sample is written to, when the test gives one.
    private let memory: MemoryService?
    private var revision: Int64 = 0

    init(memory: MemoryService? = nil) { self.memory = memory }

    /// The contexts the tools passed, in call order.
    var contexts: [ActionContext] = []

    /// The application the session says it drives, for the recorded calls.
    var application: AppContextIdentity? { AppContextIdentity(bundleID: "test.synthetic", version: "1.0") }

    /// What the session reports for its last call: the effect a test plants, under that call's event.
    var plantedEffect: SceneEffect?
    private(set) var lastReport: CallRecorder.Report?

    private func report(_ context: ActionContext) {
        contexts.append(context)
        lastReport = CallRecorder.Report(eventID: context.eventID, effect: plantedEffect, samples: [], notes: [])
    }

    /// Records the scene as the `current` sample under `eventID`, as a real session does, and reports it.
    private func observed(_ context: ActionContext, under eventID: String) async {
        contexts.append(context)
        revision += 1
        var samples: [CapturePhase] = []
        var notes: [String] = []
        if let memory {
            let window = PerceivedWindow(scene: scene, frame: CGRect(x: 0, y: 0, width: 400, height: 200),
                                         capture: CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true),
                                         surface: .window)
            do {
                _ = try await memory.record(CaptureSample(key: CaptureSampleKey(eventID: eventID, phase: .current), of: window,
                                                          sessionRevision: revision))
                samples = [.current]
            } catch {
                notes = ["sample current: \(MemoryService.describe(error))"]
            }
        }
        lastReport = CallRecorder.Report(eventID: eventID, effect: nil, samples: samples, sessionRevision: revision, notes: notes)
    }

    func open(application: String, window: String?, context: ActionContext) async throws -> SceneSnapshot {
        calls.append("open")
        id = UUID()
        // The first scene is the session's own observation: another event, with the application and the origin.
        let own = context.another(sessionID: id?.uuidString)
        if let memory {
            _ = try? await memory.record(own.event(app: application_, occurredAtMS: memory.clock.calendarMS(), kind: .observation))
        }
        await observed(context, under: own.eventID)
        return scene
    }

    private var application_: AppContextIdentity? { application }

    func observe(context: ActionContext) async throws -> SceneSnapshot {
        calls.append("observe")
        await observed(context, under: context.eventID)
        return scene
    }

    /// Cancels the running task once the action has been performed: a stop that lands after the effect.
    var cancelAfterActing = false

    /// Runs once the action has been performed, before the tool concludes: what a test does right after
    /// the effect (another writer taking the archive).
    var afterActing: (() -> Void)?

    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?,
             context: ActionContext) async throws -> ActOutcome {
        calls.append(target)
        report(context)
        if target == throwOnTarget { throw AutomationFailure("Synthetic transport failure after an earlier effect.") }
        afterActing?()
        if cancelAfterActing {
            withUnsafeCurrentTask { $0?.cancel() }
            try Task.checkCancellation()
        }
        return ActOutcome(results.isEmpty ? .foundActed : results.removeFirst(), "synthetic result", scene: scene)
    }

    func select(control: String, item: String, context: ActionContext) async throws -> ActOutcome {
        calls.append("select")
        report(context)
        return ActOutcome(.foundActed, "synthetic selection", scene: scene)
    }

    func deliver(_ input: InputRequest.Input, section: String?, context: ActionContext) async throws -> ActOutcome {
        calls.append("deliver")
        inputs.append(input)
        sections.append(section)
        report(context)
        return ActOutcome(results.isEmpty ? .foundActed : results.removeFirst(), "synthetic input", scene: scene)
    }

    func close() async { calls.append("close"); id = nil }
}

/// The tools over a living memory of their own: every call recorded as a fact, with the session's
/// report, through the one decoder; a memory that cannot be written never stops a tool.
@MainActor
@Suite("Automation MCP calls in the living memory")
struct AutomationToolsMemoryTests {

    private static func memory() -> MemoryService {
        MemoryService(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-tools-\(UUID().uuidString)/Knowledge", isDirectory: true))
    }

    /// The host as a fixture sees it: two permissions granted, one not; two running applications with their windows.
    private static let fixtureEnvironment = ToolEnvironment(
        permission: { $0 != .accessibility },
        windows   : { word in
            let all = [
                ListedApplication(name: "Mail", bundleID: "com.apple.mail", pid: 404, windows: [
                    ListedWindow(number: 77, title: "Inbox — 3"), ListedWindow(number: 78, title: nil)]),
                ListedApplication(name: "Notes", bundleID: "com.apple.Notes", pid: 505, windows: []),
            ]
            if let word { return all.filter { $0.name == word } }
            return all
        }
    )

    private static func tools(_ session: any AutomationSessionOperating, memory: MemoryService,
                              environment: ToolEnvironment = fixtureEnvironment) -> (AutomationTools, records: () -> [String]) {
        let tools = AutomationTools(session: session, memory: memory, source: .cli, streamID: "chat-worker", environment: environment)
        tools.traceID = "trace-1"
        var records: [String] = []
        tools.record = { records.append($0) }
        return (tools, { records })
    }

    @Test("status is recorded planned, started and completed under the trace, from the producer named, with its typed result")
    func statusIsRecorded() async throws {
        let memory = Self.memory()
        let session = SyntheticSession()
        let (tools, records) = Self.tools(session, memory: memory)
        let answer = try await tools.call("status", .null)
        let calls = try await memory.calls(inTrace: "trace-1", after: nil, limit: 10)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.request.tool == .status)
        #expect(call.progress.status == .completed)
        #expect(call.progress.result?.isExactly(.status(StatusResult(
            sessionID: session.id?.uuidString, screenRecording: true, accessibility: false, postEvent: true))) == true)
        #expect(answer["structuredContent"]["permissions"]["accessibility"] == .bool(false))
        #expect(call.startedAtMS != nil && (call.durationMS ?? -1) >= 0)
        #expect(call.event.source == .cli && call.event.streamID == "chat-worker" && call.event.sessionID == nil)
        #expect(call.event.app == nil, "a listing names no application")
        #expect(!records().contains { $0.hasPrefix("← memory") })
        await memory.close()
    }

    @Test("windows and apps keep their typed rows: order, NULL apart from empty text, the count left out; the answer and the rows agree")
    func listingsAreRecorded() async throws {
        let memory = Self.memory()
        let (tools, _) = Self.tools(SyntheticSession(), memory: memory)
        let windows = try await tools.call("windows", .null)
        #expect(windows["structuredContent"]["applications"].array?.count == 2)
        #expect(windows["structuredContent"]["applications"].array?[0]["windows"].array?[1]["title"] == .string(""),
                "the answer shows an empty text")
        _ = try await tools.call("windows", .object(["app": .string("Notes")]))
        let many = (1...61).map { ApplicationCandidate(name: "App \($0)", bundleID: "com.example.\($0)", version: $0 == 1 ? "1.0" : nil,
                                                       isRunning: $0 % 2 == 0, location: $0 == 2 ? "~/Applications" : nil) }
        let (appsTools, _) = Self.tools(CatalogueSession(candidates: many), memory: memory)
        let apps = try await appsTools.call("apps", .object(["query": .string("app")]))
        #expect(apps["structuredContent"]["more"] == .string("1 more not listed; pass a query to find them."))
        let calls = try await memory.calls(inTrace: "trace-1", after: nil, limit: 10)
        #expect(calls.map(\.request.tool) == [.windows, .windows, .apps])
        guard case .listing(let all)? = calls[0].progress.result, case .listing(let notes)? = calls[1].progress.result,
              case .listing(let listed)? = calls[2].progress.result else {
            Issue.record("the listings left no typed rows: \(calls.map { String(describing: $0.progress.result) })")
            return
        }
        #expect(all.kind == .windows && all.hiddenCount == 0)
        #expect(all.applications.map(\.name) == ["Mail", "Notes"] && all.applications.map(\.pid) == [404, 505])
        #expect(all.applications[0].windows.map(\.title) == ["Inbox — 3", nil], "the row keeps the absence the answer cannot")
        #expect(notes.applications.map(\.bundleID) == ["com.apple.Notes"])
        #expect(listed.kind == .apps && listed.hiddenCount == 1 && listed.applications.count == 60)
        #expect(listed.applications[0].version == "1.0" && listed.applications[1].location == "~/Applications")
        #expect(listed.applications.map(\.isRunning).prefix(2) == [false, true])
        #expect(calls[2].request.isExactly(.apps(query: "app")))
        await memory.close()
    }

    @Test("open_session and observe keep their session, revision and real sample: the observe's under its call, the open's under the session's own observation with its origin")
    func observationsAreRecorded() async throws {
        let memory  = Self.memory()
        let session = SyntheticSession(memory: memory)
        let (tools, records) = Self.tools(session, memory: memory)
        let opened = try await tools.call("open_session", .object(["app": .string("Synthetic Mixer")]))
        let id = try #require(session.id).uuidString
        let observed = try await tools.call("observe", .object(["session": .string(id)]))
        #expect(opened["structuredContent"]["revision"] == .number(1) && observed["structuredContent"]["revision"] == .number(2),
                "the answer carries the session's revision, the one the samples were taken at")
        let calls = try await memory.calls(inTrace: "trace-1", after: nil, limit: 10)
        #expect(calls.map(\.request.tool) == [.openSession, .observe])
        guard case .observation(let first)? = calls[0].progress.result, case .observation(let second)? = calls[1].progress.result else {
            Issue.record("the scene tools left no typed result: \(calls.map { String(describing: $0.progress.result) })")
            return
        }
        #expect(first.sessionID == id && first.sessionRevision == 1)
        #expect(second.sessionID == id && second.sessionRevision == 2)
        #expect(second.sample == CaptureSampleKey(eventID: calls[1].event.eventID, phase: .current))
        #expect(try await memory.sample(second.sample)?.elements.map(\.label) == ["Create"])
        let origin = try #require(try await memory.event(first.sample.eventID))
        #expect(origin.kind == .observation && origin.originEventID == calls[0].event.eventID && origin.sessionID == id)
        #expect(origin.app?.bundleID == "test.synthetic")
        #expect(calls[0].event.app == nil && calls[0].event.sessionID == nil, "the open's own event stays as planned")
        #expect(try await memory.sample(first.sample) != nil)
        #expect(!records().contains { $0.hasPrefix("← memory") })
        await memory.close()
    }

    @Test("a scene whose sample the session could not record has no result: an explicit gap, said, never a row pointing at nothing")
    func anObservationWithoutItsSampleHasNoResult() async throws {
        let memory  = Self.memory()
        let session = SyntheticSession()
        let (tools, records) = Self.tools(session, memory: memory)
        let id = try #require(session.id).uuidString
        _ = try await tools.call("observe", .object(["session": .string(id)]))
        let call = try #require(try await memory.calls(inTrace: "trace-1", after: nil, limit: 10).first)
        #expect(call.progress.status == .completed && call.progress.result == nil)
        #expect(!records().contains { $0.hasPrefix("← memory could not record observe") })
        await memory.close()
    }

    @Test("S3-d supervision: cancellation while planning cannot reach an effect")
    func supervisionCancellationWhilePlanning() async throws {
        let memory = Self.memory()
        try await memory.open()
        let session = SyntheticSession()
        let (tools, _) = Self.tools(session, memory: memory)
        let id = try #require(session.id).uuidString
        var db: OpaquePointer?
        #expect(sqlite3_open(memory.url.path, &db) == SQLITE_OK)
        let handle = try #require(db)
        defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        let task = Task { @MainActor in
            try await tools.call("act", .object(["session": .string(id), "target": .string("Must not execute")]))
        }
        var waiting = false
        for _ in 0..<200 {
            if await memory.status().diagnostics?.retainedWrites == 1 { waiting = true; break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(waiting, "the call must actually be waiting on its planned write before cancellation")
        task.cancel()
        let result = await task.result
        #expect(session.calls.isEmpty, "cancelled planning must not fall through to the UI action")
        switch result {
            case .failure(let error): #expect(error is CancellationError, "\(error)")
            case .success: Issue.record("cancelled tool returned a normal result")
        }
        #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        #expect(try await memory.calls(inTrace: "trace-1", after: nil, limit: 10).isEmpty, "nothing was planned: the write was cancelled")
        #expect(await memory.status().isReady, "contention is not degradation")
        await memory.close()
    }

    @Test("a cancellation that lands after the effect keeps the known outcome and records the call as cancelled, never undone")
    func cancellationAfterTheEffectKeepsTheOutcome() async throws {
        let memory  = Self.memory()
        let session = SyntheticSession()
        session.cancelAfterActing = true
        let (tools, _) = Self.tools(session, memory: memory)
        let id = try #require(session.id).uuidString
        let outcome = await Task { @MainActor in
            try await tools.call("act", .object(["session": .string(id), "target": .string("Create")]))
        }.result
        #expect(session.calls == ["Create"], "the action ran once")
        if case .failure(let error) = outcome { #expect(error is CancellationError) } else { Issue.record("a cancelled turn answered") }
        let call = try #require(try await memory.calls(inTrace: "trace-1", after: nil, limit: 10).first)
        #expect(call.progress.status == .cancelled, "the effect happened, its outcome is unknown to the record: cancelled, not undone")
        #expect(call.startedAtMS != nil && (call.durationMS ?? -1) >= 0, "the finalization was written although the task was cancelled")
        await memory.close()
    }

    @Test("a call whose effect happened keeps its terminal result under ordinary contention past the budget: the action ran once, the row is read back after the release")
    func anEffectIsConcludedUnderOrdinaryContention() async throws {
        // Short cycles and a 20 ms budget, as the supervision's probe; nobody stops the turn.
        let memory = MemoryService(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-tools-held-\(UUID().uuidString)/Knowledge", isDirectory: true), configuration: .init(
            store: .init(lockBudget: .milliseconds(10), retryPause: .milliseconds(2), maximumRetryPause: .milliseconds(2)),
            finalizationBudget: .milliseconds(20)
        ))
        try await memory.open()
        let session = SyntheticSession()
        session.plantedEffect = .menuOpened(labels: ["Desktop", "Mobile"])
        let (tools, records) = Self.tools(session, memory: memory)
        let id = try #require(session.id).uuidString
        var db: OpaquePointer?
        #expect(sqlite3_open(memory.url.path, &db) == SQLITE_OK)
        let handle = try #require(db)
        defer { sqlite3_close(handle) }
        // Right after the effect, another writer takes the archive and holds it for 250 ms.
        session.afterActing = { #expect(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK) }
        let release = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(250))
            #expect(sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        }
        let answer = try await tools.call("act", .object(["session": .string(id), "target": .string("Create")]))
        try await release.value
        #expect(session.calls == ["Create"], "the action ran once; nothing was replayed to conclude it")
        #expect(answer["structuredContent"]["status"].string == "found_acted")
        #expect(!records().contains { $0.hasPrefix("← memory") }, "no gap for the wait alone: \(records())")
        let call = try #require(try await memory.calls(inTrace: "trace-1", after: nil, limit: 10).first)
        #expect(call.progress.status == .completed, "the terminal result, written once the other writer released its lock")
        if case .outcome(let kind, let message)? = call.progress.result { #expect(kind == .foundActed && message == "synthetic result") }
        else { Issue.record("expected the action's outcome, got \(String(describing: call.progress.result))") }
        #expect(call.progress.observedEffect?.sceneEffect == .menuOpened(labels: ["Desktop", "Mobile"]))
        #expect((call.durationMS ?? -1) >= 0 && call.progress.endedAtMS != nil)
        #expect(await memory.status().diagnostics?.commits == 3, "planned, started, completed: one commit each")
        #expect(await memory.status().isReady)
        await memory.close()
    }

    @Test("durations are monotone and the calendar is kept as it was, even when the wall runs backwards during a call")
    func durationsAreMonotoneWhateverTheCalendarDoes() async throws {
        let walls  = Mutex([1_700_000_000.900, 1_700_000_000.400, 1_700_000_000.100, 1_700_000_000.050])
        let ticks  = Mutex<Int64>(1_000_000_000)
        let clock  = MemoryClock(
            wall     : { Date(timeIntervalSince1970: walls.withLock { $0.isEmpty ? 1_700_000_000.050 : $0.removeFirst() }) },
            monotonic: { ticks.withLock { $0 += 4_000_000; return $0 } }
        )
        let memory = MemoryService(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-tools-clock-\(UUID().uuidString)/Knowledge", isDirectory: true), clock: clock)
        let (tools, _) = Self.tools(SyntheticSession(), memory: memory)
        _ = try await tools.call("status", .null)
        let call = try #require(try await memory.calls(inTrace: "trace-1", after: nil, limit: 10).first)
        let started = try #require(call.startedAtMS), ended = try #require(call.progress.endedAtMS)
        #expect(ended < started, "the calendar went backwards and the record says so")
        #expect(call.event.occurredAtMS > started, "the facts keep their original calendar, planned before started")
        #expect((call.durationMS ?? -1) >= 0, "the duration is the monotonic clock's, never negative")
        await memory.close()
    }

    @Test("an action carries its decoded arguments, the session's application, the outcome and the effect the session reported")
    func actionIsRecordedWithItsEffect() async throws {
        let memory  = Self.memory()
        let session = SyntheticSession()
        session.plantedEffect = .elementsAppeared(labels: ["Queue"])
        let (tools, _) = Self.tools(session, memory: memory)
        let id = try #require(session.id).uuidString
        _ = try await tools.call("act", .object(["session": .string(id), "target": .string("Send")]))
        let call = try #require(try await memory.calls(inTrace: "trace-1", after: nil, limit: 10).first)
        #expect(call.request.isExactly(.act(target: "Send", verb: .click, value: nil, section: nil)), "the default verb is written once")
        #expect(call.event.sessionID == id)
        #expect(call.event.app?.bundleID == "test.synthetic" && call.event.app?.version == "1.0")
        #expect(call.progress.status == .completed)
        #expect(call.progress.result?.isExactly(.outcome(.foundActed, message: "synthetic result")) == true)
        #expect(call.progress.observedEffect?.kind == "elementsAppeared")
        #expect(call.progress.observedEffect?.labels == ["Queue"])
        #expect(call.progress.observedEffect?.sceneEffect == .elementsAppeared(labels: ["Queue"]))
        #expect(session.contexts.map(\.eventID) == [call.event.eventID], "the session saw the call's own context")
        #expect(session.contexts.first?.traceID == "trace-1" && session.contexts.first?.sessionID == id)
        await memory.close()
    }

    @Test("a batch is recorded with its steps as children: the ones run, the one that stopped it and the rest skipped")
    func batchIsRecordedWithItsSteps() async throws {
        let memory  = Self.memory()
        let session = SyntheticSession()
        session.results = [.foundActed, .actedUnverified, .foundActed]
        let (tools, _) = Self.tools(session, memory: memory)
        let id = try #require(session.id).uuidString
        _ = try await tools.call("batch", .object([
            "session": .string(id), "steps": .array([
                .object(["operation": .string("act"), "target": .string("First")]),
                .object(["operation": .string("type_text"), "target": .string("Name"), "text": .string("Demo")]),
                .object(["operation": .string("scroll"), "direction": .string("down")])
            ])
        ]))
        let calls = try await memory.calls(inTrace: "trace-1", after: nil, limit: 10)
        let batch = try #require(calls.first { $0.request.tool == .batch })
        #expect(batch.requestedSteps == 3)
        #expect(batch.progress.result?.isExactly(.batch(stopped: true, attempted: 2, verified: 1)) == true)
        let steps = try await memory.steps(ofBatch: batch.event.eventID)
        #expect(steps.map(\.request.tool) == [.act, .typeText, .scroll])
        #expect(steps.map(\.progress.status) == [.completed, .completed, .skipped])
        #expect(steps.map(\.event.parentPosition) == [0, 1, 2])
        #expect(steps.allSatisfy { $0.event.parentEventID == batch.event.eventID && $0.event.sessionID == id })
        #expect(steps[1].request.isExactly(.typeText(target: "Name", text: "Demo", section: nil, replace: true)))
        #expect(steps[1].progress.result?.isExactly(.outcome(.actedUnverified, message: "synthetic input")) == true)
        #expect(steps[2].startedAtMS == nil, "a skipped step never started")
        #expect(session.contexts.map(\.parentEventID) == [batch.event.eventID, batch.event.eventID])
        await memory.close()
    }

    @Test("a step that throws is recorded failed with its error, and the batch stops there")
    func failingStepIsRecorded() async throws {
        let memory  = Self.memory()
        let session = SyntheticSession()
        session.throwOnTarget = "Second"
        let (tools, _) = Self.tools(session, memory: memory)
        let id = try #require(session.id).uuidString
        _ = try await tools.call("batch", .object([
            "session": .string(id), "steps": .array(["First", "Second", "Third"].map {
                .object(["operation": .string("act"), "target": .string($0)])
            })
        ]))
        let batch = try #require(try await memory.calls(inTrace: "trace-1", after: nil, limit: 10).first { $0.request.tool == .batch })
        let steps = try await memory.steps(ofBatch: batch.event.eventID)
        #expect(steps.map(\.progress.status) == [.completed, .failed, .skipped])
        #expect(steps[1].progress.result?.isExactly(.error(message: "Synthetic transport failure after an earlier effect.")) == true)
        #expect(batch.progress.result?.isExactly(.batch(stopped: true, attempted: 2, verified: 1)) == true)
        await memory.close()
    }

    @Test("a request the decoder refuses, or a stale session, records nothing")
    func refusedRequestsRecordNothing() async throws {
        let memory  = Self.memory()
        let session = SyntheticSession()
        let (tools, _) = Self.tools(session, memory: memory)
        _ = try? await tools.call("act", .object(["session": .string("old"), "target": .string("Create")]))
        _ = try? await tools.call("scroll", .object(["session": .string(try #require(session.id).uuidString),
                                                     "direction": .string("left")]))
        #expect(try await memory.calls(inTrace: "trace-1", after: nil, limit: 10).isEmpty)
        #expect(session.calls.isEmpty)
        await memory.close()
    }

    @Test("a memory that cannot be opened never stops a tool: the call answers, and one record line says why")
    func degradedMemoryNeverStopsATool() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-tools-blocked-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: parent)
        let memory = MemoryService(directory: parent.appendingPathComponent("Knowledge", isDirectory: true))
        let session = SyntheticSession()
        let (tools, records) = Self.tools(session, memory: memory)
        let result = try await tools.call("status", .null)
        #expect(result["structuredContent"]["permissions"] != .null)
        let lines = records()
        #expect(lines.first?.hasPrefix("→ status") == true)
        #expect(lines.contains { $0.hasPrefix("← memory could not record status: could not open: ") })
        #expect(lines.last?.hasPrefix("← status ") == true)
        #expect(lines.filter { $0.hasPrefix("← memory") }.count == 1, "the moves of a call never planned are not attempted")
        await memory.close()
    }

    @Test("the one decoder reads every tool as its definition says, and refuses what the definitions now state")
    func decoderAgreesWithTheDefinitions() throws {
        let definitions = Dictionary(uniqueKeysWithValues: AutomationTools.definitions.map { ($0["name"].string ?? "", $0) })
        #expect(definitions.count == 14)
        let minimal: [String: JSONValue] = [
            "status": .object([:]), "windows": .object([:]), "apps": .object([:]),
            "open_session": .object(["app": .string("Calculator")]),
            "observe": .object(["session": .string("s")]),
            "act": .object(["session": .string("s"), "target": .string("Send")]),
            "select": .object(["session": .string("s"), "control": .string("Format"), "item": .string("H.264")]),
            "type_text": .object(["session": .string("s"), "target": .string("To"), "text": .string("  ")]),
            "press_key": .object(["session": .string("s"), "key": .string("return")]),
            "scroll": .object(["session": .string("s"), "direction": .string("down")]),
            "drag": .object(["session": .string("s"), "from": .string("Clip"), "dy": .number(12)]),
            "context_menu": .object(["session": .string("s"), "target": .string("Text"), "item": .string("Copy")]),
            "batch": .object(["session": .string("s"), "steps": .array([.object(["operation": .string("act"), "target": .string("x")])])]),
            "close_session": .object(["session": .string("s")]),
        ]
        for (name, arguments) in minimal {
            let request = try ToolRequestDecoder.decode(name, arguments)
            #expect(request.tool.rawValue == name, Comment(rawValue: name))
        }
        let drag = try ToolRequestDecoder.decode("drag", minimal["drag"]!)
        #expect(drag.isExactly(.drag(from: "Clip", to: .offset(dx: 0, dy: 12), section: nil)), "a missing axis is written as 0")
        let keys = try ToolRequestDecoder.decode("press_key", .object(["session": .string("s"), "key": .string("A"),
                                                                        "modifiers": .array([.string("shift"), .string("cmd")])]))
        #expect(keys.isExactly(.pressKey(key: .character("a"), modifiers: [.cmd, .shift], count: 1)),
                "modifiers are kept in the definition's order, the key as the chord names it")
        // What the definitions state and the decoder enforces alike.
        #expect(definitions["act"]?["inputSchema"]["properties"]["target"]["pattern"] == .string("\\S"))
        #expect(definitions["type_text"]?["inputSchema"]["properties"]["text"]["pattern"] == .null, "typed text may be spaces")
        #expect(definitions["drag"]?["inputSchema"]["anyOf"].array?.count == 3)
        #expect(definitions["act"]?["inputSchema"]["properties"]["verb"]["description"].string?.contains("click when absent") == true)
        #expect(throws: AutomationFailure.self) { try ToolRequestDecoder.decode("act", .object(["session": .string("s"), "target": .string("   ")])) }
        #expect(throws: AutomationFailure.self) { try ToolRequestDecoder.decode("drag", .object(["session": .string("s"), "from": .string("Clip")])) }
        #expect(throws: AutomationFailure.self) {
            try ToolRequestDecoder.decode("press_key", .object(["session": .string("s"), "key": .string("a"),
                                                                "modifiers": .array([.string("cmd"), .string("cmd")])]))
        }
        #expect(throws: AutomationFailure.self) {
            try ToolRequestDecoder.step(.object(["operation": .string("act"), "target": .string("x"), "session": .string("other")]),
                                        batchSession: "s")
        }
        #expect(try ToolRequestDecoder.step(.object(["operation": .string("act"), "target": .string("x"), "session": .string("s")]),
                                            batchSession: "s").tool == .act)
        #expect(throws: AutomationFailure.self) { try ToolRequestDecoder.step(.object(["operation": .string("observe")]), batchSession: "s") }
        #expect(throws: AutomationFailure.self) { try ToolRequestDecoder.decode("run_menu", .object([:])) }
    }

    @Test("the six differences the S2-3b delivery listed are aligned or stated in the definitions, with the decoder unchanged")
    func theSixDifferencesAreStated() throws {
        let definitions = Dictionary(uniqueKeysWithValues: AutomationTools.definitions.map { ($0["name"].string ?? "", $0) })
        let steps = definitions["batch"]?["inputSchema"]["properties"]["steps"]["items"]["oneOf"].array ?? []
        #expect(steps.count == 7)
        // 1. A step may repeat the batch's session, which must be the batch's: the step schemas now say so.
        for step in steps {
            #expect(step["properties"]["session"]["description"].string?.contains("must be the batch's session") == true)
            #expect(step["required"].array?.contains(.string("session")) == false)
        }
        // 2. A required text needs a character that is not a space; typed text may be spaces.
        #expect(definitions["select"]?["inputSchema"]["properties"]["item"]["pattern"] == .string("\\S"))
        #expect(try ToolRequestDecoder.decode("type_text", .object(["session": .string("s"), "target": .string("To"),
                                                                     "text": .string(" ")])).tool == .typeText)
        // 3. value with set_toggle only: a condition the schema states in words, the decoder enforces.
        #expect(definitions["act"]?["inputSchema"]["properties"]["value"]["description"].string?.contains("set_toggle") == true)
        #expect(throws: AutomationFailure.self) {
            try ToolRequestDecoder.decode("act", .object(["session": .string("s"), "target": .string("x"), "value": .string("on")]))
        }
        // 4. A drag ends on to or at an offset, never both: anyOf for one of them, the descriptions for "never both".
        let drag = definitions["drag"]?["inputSchema"]["properties"]
        #expect(drag?["to"]["description"].string?.contains("never with dx or dy") == true)
        #expect(throws: AutomationFailure.self) {
            try ToolRequestDecoder.decode("drag", .object(["session": .string("s"), "from": .string("a"), "to": .string("b"),
                                                           "dx": .number(1)]))
        }
        // 5. The key is read without regard to case, as described; repeated modifiers are refused, as uniqueItems says.
        #expect(definitions["press_key"]?["inputSchema"]["properties"]["key"]["description"].string?.contains("case") == true)
        #expect(definitions["press_key"]?["inputSchema"]["properties"]["modifiers"]["uniqueItems"] == .bool(true))
        #expect(try ToolRequestDecoder.decode("press_key", .object(["session": .string("s"), "key": .string("Return")]))
            .isExactly(.pressKey(key: .return, modifiers: [], count: 1)))
        // 6. A JSON integer may be written 3.0, as JSON Schema's integer admits; a fraction is refused.
        #expect(try ToolRequestDecoder.decode("scroll", .object(["session": .string("s"), "direction": .string("up"),
                                                                 "lines": .number(3.0)])).isExactly(
            .scroll(direction: .up, lines: 3, target: nil, section: nil)))
        #expect(throws: AutomationFailure.self) {
            try ToolRequestDecoder.decode("scroll", .object(["session": .string("s"), "direction": .string("up"), "lines": .number(2.5)]))
        }
    }

    @Test("the batch's acceptance rule is one: found_acted, and acted_noop only for set_toggle")
    func theAcceptanceRuleIsShared() {
        let toggle = AgentCallRequest.act(target: "x", verb: .setToggle, value: .on, section: nil)
        let click  = AgentCallRequest.act(target: "x", verb: .click, value: nil, section: nil)
        let key    = AgentCallRequest.pressKey(key: .return, modifiers: [], count: 1)
        #expect(toggle.accepts(.foundActed) && toggle.accepts(.actedNoop))
        #expect(click.accepts(.foundActed) && !click.accepts(.actedNoop) && !key.accepts(.actedNoop))
        for kind in [ActOutcomeKind.ambiguous, .honestMiss, .actedUnverified, .refused, .dryRun] {
            #expect(!toggle.accepts(kind) && !click.accepts(kind) && !key.accepts(kind))
        }
    }
}

/// Measures, on temporary archives, how long a tool call takes to answer once its turn is stopped while
/// another writer holds the archive, after the effect already happened: the conclusion of the call, and
/// for a batch the skips of the steps never run and the batch's own conclusion, all within the turn's
/// one budget from the stop (`finalizationScope`, set and stopped here as `AgentTurnHost` does). Prints one `STOP-MEASURE` line per case (monotonic, from the stop to the call's
/// return) and checks the structure: the effect ran once, no later step ran, what was cut is said in the
/// call's record lines and missing on disk. The budget is 100 ms unless `MECUM_MEASURE_FINALIZATION_MS`
/// says otherwise; `MECUM_MEASURE_PRODUCTION=1` uses the service's production defaults. A synthetic
/// session, no seat, no provider.
@MainActor
@Suite("Measured: a tool call's finalizations after a stop", .serialized)
struct AutomationToolsStopMeasures {

    private static let environment = ProcessInfo.processInfo.environment

    private static var configuration: MemoryService.Configuration {
        if environment["MECUM_MEASURE_PRODUCTION"] == "1" { return MemoryService.Configuration() }
        let budget = environment["MECUM_MEASURE_FINALIZATION_MS"].flatMap(Int.init) ?? 100
        return MemoryService.Configuration(
            store: .init(lockBudget: .milliseconds(20), retryPause: .milliseconds(2), maximumRetryPause: .milliseconds(5)),
            finalizationBudget: .milliseconds(budget)
        )
    }

    private static func ms(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    private static var budgetMS: Int64 { ms(configuration.finalizationBudget) }

    private static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while await !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// The tools over a fresh memory, a synthetic session that takes the archive right after its first
    /// effect, and the raw connection holding it.
    private func composed() async throws -> (AutomationTools, SyntheticSession, MemoryService, OpaquePointer, () -> [String]) {
        let memory = MemoryService(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mecum-tools-stop-\(UUID().uuidString)/Knowledge", isDirectory: true),
            configuration: Self.configuration)
        try await memory.open()
        let session = SyntheticSession()
        let tools = AutomationTools(session: session, memory: memory, source: .cli, streamID: "chat-worker",
                                    environment: ToolEnvironment(permission: { _ in true }, windows: { _ in [] }))
        tools.traceID = "trace-stop"
        var records: [String] = []
        tools.record = { records.append($0) }
        var db: OpaquePointer?
        #expect(sqlite3_open(memory.url.path, &db) == SQLITE_OK)
        let handle = try #require(db)
        var locked = false
        session.afterActing = {
            guard !locked else { return }
            locked = true
            #expect(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        }
        return (tools, session, memory, handle, { records })
    }

    private func stop(_ call: Task<JSONValue, any Error>, memory: MemoryService, scope: MemoryFinalizationScope?)
        async -> (Result<JSONValue, any Error>, Duration) {
        await Self.until { await memory.status().diagnostics?.retainedWrites == 1 }
        let stop = ContinuousClock.now
        scope?.stop(at: stop)
        call.cancel()
        let result = await call.result
        return (result, ContinuousClock.now - stop)
    }

    @Test("an act stopped after its effect under a lock that never goes: its conclusion is cut after one budget; the row stays started")
    func actUnderAPermanentLock() async throws {
        let (tools, session, memory, handle, records) = try await composed()
        tools.finalizationScope = MemoryFinalizationScope()
        let id = try #require(session.id).uuidString
        let call = Task { @MainActor in try await tools.call("act", .object(["session": .string(id), "target": .string("Create")])) }
        let (result, elapsed) = await stop(call, memory: memory, scope: tools.finalizationScope)
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close(handle)
        let row = try #require(try await memory.calls(inTrace: "trace-stop", after: nil, limit: 10).first)
        let gaps = records().filter { $0.hasPrefix("← memory") }
        print("STOP-MEASURE case=act-permanent-lock budgetMs=\(Self.budgetMS) stopToReturnMs=\(Self.ms(elapsed)) "
              + "effects=\(session.calls.count) cut=\(gaps.count) row=\(row.progress.status) "
              + "answer=\(result.map { $0["structuredContent"]["status"].string ?? "?" })")
        #expect(session.calls == ["Create"], "the effect ran once")
        #expect(gaps.count == 1, "\(records())")
        #expect(row.progress.status == .started, "the conclusion was cut: the outcome is unknown to the record, never invented")
        #expect(Self.ms(elapsed) >= Self.budgetMS && Self.ms(elapsed) < Self.budgetMS * 2 + 500)
        #expect(await memory.status().diagnostics?.retainedWrites == 0)
        await memory.close()
    }

    /// A batch of `count` acts, stopped after its first effect under a lock that never goes.
    private func stoppedBatch(_ count: Int) async throws {
        let (tools, session, memory, handle, records) = try await composed()
        tools.finalizationScope = MemoryFinalizationScope()
        let id = try #require(session.id).uuidString
        let steps = (0..<count).map { JSONValue.object(["operation": .string("act"), "target": .string("Step \($0)")]) }
        let call = Task { @MainActor in
            try await tools.call("batch", .object(["session": .string(id), "steps": .array(steps)]))
        }
        let (result, elapsed) = await stop(call, memory: memory, scope: tools.finalizationScope)
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close(handle)
        let rows = try await memory.calls(inTrace: "trace-stop", after: nil, limit: 10)
        let batch = try #require(rows.first { $0.request.tool == .batch })
        let stored = try await memory.steps(ofBatch: batch.event.eventID)
        let gaps = records().filter { $0.hasPrefix("← memory") }
        print("STOP-MEASURE case=batch-\(count)-permanent-lock budgetMs=\(Self.budgetMS) stopToReturnMs=\(Self.ms(elapsed)) "
              + "effects=\(session.calls.count) cut=\(gaps.count) batch=\(batch.progress.status) "
              + "steps=\(stored.map { "\($0.progress.status)" }.prefix(4))… answer=\(result.map { $0["structuredContent"]["status"].string ?? "?" })")
        #expect(session.calls == ["Step 0"], "no step after the stop")
        #expect(gaps.count == count + 1, "the step's end, \(count - 1) skips and the batch's end, each said: \(gaps.count)")
        #expect(Self.ms(elapsed) >= Self.budgetMS, "the budget is spent before anything is cut")
        #expect(Self.ms(elapsed) < Self.budgetMS * 2 + 200, "one budget for the turn, where one per fact would take \(count + 1)")
        #expect(stored.first?.progress.status == .started, "cut, never claimed")
        #expect(stored.dropFirst().allSatisfy { $0.progress.status == .planned }, "never begun, and their skip not written")
        #expect(batch.progress.status == .planned || batch.progress.status == .started)
        #expect(await memory.status().diagnostics?.retainedWrites == 0)
        await memory.close()
    }

    @Test("a batch of three stopped after its first effect under a lock that never goes: no later step runs; its four facts share one budget")
    func batchUnderAPermanentLock() async throws {
        try await stoppedBatch(3)
    }

    @Test("a batch of twenty stopped after its first effect under a lock that never goes: no later step runs; its twenty-one facts share one budget")
    func batchOfTwentyUnderAPermanentLock() async throws {
        try await stoppedBatch(20)
    }

    @Test("the next turn is a new owner: its stopped call has a whole budget of its own after the last turn's was spent")
    func theNextTurnHasANewBudget() async throws {
        let (tools, session, memory, handle, _) = try await composed()
        let id = try #require(session.id).uuidString
        tools.finalizationScope = MemoryFinalizationScope()
        let first = Task { @MainActor in try await tools.call("act", .object(["session": .string(id), "target": .string("Create")])) }
        _ = await stop(first, memory: memory, scope: tools.finalizationScope)
        tools.finalizationScope = MemoryFinalizationScope()
        // The other writer lets go, so the second call is planned, and takes the archive again after its effect.
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        session.afterActing = { #expect(sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK) }
        let second = Task { @MainActor in try await tools.call("act", .object(["session": .string(id), "target": .string("Again")])) }
        let (_, elapsed) = await stop(second, memory: memory, scope: tools.finalizationScope)
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close(handle)
        #expect(session.calls == ["Create", "Again"])
        #expect(Self.ms(elapsed) >= Self.budgetMS, "a new budget, not the spent one of the turn before")
        await memory.close()
    }

    @Test("an act stopped after its effect with the lock released within the budget: the conclusion is saved, once")
    func actWithTheLockReleasedAfterTheStop() async throws {
        let (tools, session, memory, handle, records) = try await composed()
        let id = try #require(session.id).uuidString
        let call = Task { @MainActor in try await tools.call("act", .object(["session": .string(id), "target": .string("Create")])) }
        await Self.until { await memory.status().diagnostics?.retainedWrites == 1 }
        let stop = ContinuousClock.now
        call.cancel()
        try await Task.sleep(for: .milliseconds(Self.budgetMS / 2))
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close(handle)
        let result = await call.result
        let elapsed = ContinuousClock.now - stop
        let row = try #require(try await memory.calls(inTrace: "trace-stop", after: nil, limit: 10).first)
        print("STOP-MEASURE case=act-released-within-budget budgetMs=\(Self.budgetMS) stopToReturnMs=\(Self.ms(elapsed)) "
              + "effects=\(session.calls.count) cut=\(records().filter { $0.hasPrefix("← memory") }.count) row=\(row.progress.status) "
              + "answer=\(result.map { $0["structuredContent"]["status"].string ?? "?" })")
        #expect(session.calls == ["Create"])
        #expect(!records().contains { $0.hasPrefix("← memory") }, "\(records())")
        #expect([.completed, .cancelled].contains(row.progress.status), "a terminal row, written once the lock went")
        await memory.close()
    }
}
