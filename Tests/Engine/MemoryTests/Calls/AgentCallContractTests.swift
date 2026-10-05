//
//  AgentCallContractTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
@testable import Memory
import PerceptionCore
import Testing

/// The call contract on its own: every tool's arguments as typed rows and back, the defaults
/// written once, the exact comparison, the refusals both ways, and the moves between states.
@Suite("The agent call contract: typed arguments, exact comparison, states")
struct AgentCallContractTests {

    /// One request of every tool, and every variant the tools decode.
    static let requests: [(String, AgentCallRequest)] = [
        ("status", .status),
        ("windows", .windows(app: nil)),
        ("windows app", .windows(app: "Mail")),
        ("apps", .apps(query: nil)),
        ("apps query", .apps(query: "com.apple")),
        ("open_session", .openSession(app: "Calculator", window: nil)),
        ("open_session window", .openSession(app: "Mail", window: "Inbox – 3")),
        ("observe", .observe),
        ("act click", .act(target: "Send", verb: .click, value: nil, section: nil)),
        ("act double", .act(target: "row 3", verb: .doubleClick, value: nil, section: "Sidebar")),
        ("act triple", .act(target: "Body", verb: .tripleClick, value: nil, section: nil)),
        ("act right", .act(target: "File", verb: .rightClick, value: nil, section: nil)),
        ("act toggle on", .act(target: "Wi-Fi", verb: .setToggle, value: .on, section: nil)),
        ("act toggle off", .act(target: "Wi-Fi", verb: .setToggle, value: .off, section: "Network")),
        ("select", .select(control: "Format", item: "H.264")),
        ("type_text", .typeText(target: "To", text: "Zoë ☕️ 東京", section: nil, replace: true)),
        ("type_text append NUL", .typeText(target: "Body", text: "a\u{0}b", section: "Compose", replace: false)),
        ("insert_text", .insertText(text: "Zoë ☕️ 東京", expectedValue: nil)),
        ("insert_text expecting", .insertText(text: "\n", expectedValue: "Line\n")),
        ("press_key", .pressKey(key: .return, modifiers: [], count: 1)),
        ("press_key chord", .pressKey(key: .character("n"), modifiers: [.cmd, .shift], count: 3)),
        ("scroll", .scroll(direction: .down, lines: 3, target: nil, section: nil)),
        ("scroll target", .scroll(direction: .up, lines: 50, target: "List", section: "Main")),
        ("drag to", .drag(from: "A", to: .target("B"), section: nil)),
        ("drag offset", .drag(from: "Slider", to: .offset(dx: -0.0, dy: 12.5), section: "Panel")),
        ("context_menu", .contextMenu(target: "Paragraph", item: "Copia", section: nil)),
        ("batch", .batch),
        ("close_session", .closeSession),
    ]

    @Test("every tool and variant becomes its contract's rows and is rebuilt exactly from them; every name is the tool's own and admitted")
    func roundTrip() throws {
        #expect(Set(Self.requests.map(\.1.tool)) == Set(AgentTool.allCases), "the fixtures cover every tool")
        for (name, request) in Self.requests {
            let rows = request.arguments
            let rebuilt = try AgentCallRequest(tool: request.tool, arguments: rows, eventID: "e")
            #expect(rebuilt.isExactly(request), Comment(rawValue: name))
            let admitted = Set(AgentCallArguments.specs(of: request.tool).map(\.name))
            #expect(rows.allSatisfy { admitted.contains($0.name) }, Comment(rawValue: name))
            #expect(rows.allSatisfy { $0.name == "modifiers" || $0.position == 0 }, Comment(rawValue: name))
        }
        #expect(AgentCallRequest.pressKey(key: .character("n"), modifiers: [.cmd, .shift], count: 3).arguments.filter { $0.name == "modifiers" }
            == [BrainArgument(name: "modifiers", position: 0, value: .text("cmd")), BrainArgument(name: "modifiers", position: 1, value: .text("shift"))])
        #expect(AgentCallRequest.status.arguments.isEmpty && AgentCallRequest.batch.arguments.isEmpty)
    }

    @Test("defaults are written once, as the decoder fills them: the verb, replace, the count, the lines and a drag's missing axis are rows; an absent optional is no row")
    func defaultsAreRows() {
        #expect(AgentCallRequest.act(target: "Send", verb: .click, value: nil, section: nil).arguments.map(\.name) == ["target", "verb"])
        #expect(AgentCallRequest.typeText(target: "To", text: "x", section: nil, replace: true).arguments.last
            == BrainArgument(name: "replace", position: 0, value: .boolean(true)))
        #expect(AgentCallRequest.pressKey(key: .tab, modifiers: [], count: 1).arguments.map(\.name) == ["key", "count"])
        #expect(AgentCallRequest.scroll(direction: .down, lines: 3, target: nil, section: nil).arguments.map(\.value)
            == [.text("down"), .integer(3)])
        let offset = AgentCallRequest.input(.drag(from: "A", to: .offset(dx: 0, dy: 40)), section: nil)
        #expect(offset.arguments.map(\.name) == ["from", "dx", "dy"])
    }

    @Test("the decoder's own values map once: a scroll's signed lines become a direction and a count, a chord's modifiers their tokens in the definition's order, a key its word")
    func fromTheDecodersTypes() {
        let up = AgentCallRequest.input(.scroll(lines: 5, over: "List"), section: "Main")
        #expect(up.isExactly(.scroll(direction: .up, lines: 5, target: "List", section: "Main")))
        let down = AgentCallRequest.input(.scroll(lines: -3, over: nil), section: nil)
        #expect(down.isExactly(.scroll(direction: .down, lines: 3, target: nil, section: nil)))
        let chord = AgentCallRequest.input(.pressKey(KeyChord(.character("z"), modifiers: [.control, .shift, .command]), times: 2), section: nil)
        #expect(chord.isExactly(.pressKey(key: .character("z"), modifiers: [.cmd, .shift, .ctrl], count: 2)))
        let typed = AgentCallRequest.input(.typeText("hi", into: "Field", replacing: false), section: "S")
        #expect(typed.isExactly(.typeText(target: "Field", text: "hi", section: "S", replace: false)))
        let menu = AgentCallRequest.input(.contextMenu(on: "Text", item: "Copy"), section: nil)
        #expect(menu.isExactly(.contextMenu(target: "Text", item: "Copy", section: nil)))
    }

    @Test("the comparison is exact: bytes not Unicode equivalence, NUL and empty text are content, absent is not empty, false is not true, order of modifiers counts, −0.0 and +0.0 are one offset")
    func exactComparison() {
        let base = AgentCallRequest.typeText(target: "Café", text: "x", section: nil, replace: true)
        #expect(base.isExactly(.typeText(target: "Caf" + "é", text: "x", section: nil, replace: true)))
        let variants: [(String, AgentCallRequest)] = [
            ("decomposed", .typeText(target: "Cafe\u{301}", text: "x", section: nil, replace: true)),
            ("NUL", .typeText(target: "Café", text: "x\u{0}", section: nil, replace: true)),
            ("empty section", .typeText(target: "Café", text: "x", section: "", replace: true)),
            ("replace false", .typeText(target: "Café", text: "x", section: nil, replace: false)),
            ("other tool", .contextMenu(target: "Café", item: "x", section: nil)),
        ]
        #expect("Cafe\u{301}" == "Café", "Swift's String equality would hide the first")
        for (name, variant) in variants {
            #expect(!base.isExactly(variant) && !variant.isExactly(base), Comment(rawValue: name))
        }
        #expect(!AgentCallRequest.pressKey(key: .tab, modifiers: [.cmd, .shift], count: 1)
            .isExactly(.pressKey(key: .tab, modifiers: [.shift, .cmd], count: 1)))
        #expect(AgentCallRequest.drag(from: "A", to: .offset(dx: -0.0, dy: 1), section: nil)
            .isExactly(.drag(from: "A", to: .offset(dx: 0.0, dy: 1), section: nil)))
        #expect(!AgentCallRequest.drag(from: "A", to: .offset(dx: 0, dy: 1), section: nil)
            .isExactly(.drag(from: "A", to: .offset(dx: 0, dy: 1.0.nextUp), section: nil)))
        #expect(!AgentCallRequest.windows(app: nil).isExactly(.windows(app: "")))
    }

    @Test("a request the tools could not decode is refused before any store: a value without set_toggle and the reverse, mixed, a modifier twice, zero presses or lines, an offset that is not finite")
    func invalidRequests() {
        func refused(_ request: AgentCallRequest, _ invalidity: AgentCallError.Invalidity) {
            #expect(throws: AgentCallError.invalidRequest(invalidity)) { try request.validate() }
        }
        refused(.act(target: "X", verb: .setToggle, value: nil, section: nil), .toggleWithoutValue)
        refused(.act(target: "X", verb: .click, value: .on, section: nil), .valueWithoutToggle)
        refused(.act(target: "X", verb: .setToggle, value: .mixed, section: nil), .valueNotOnOff)
        refused(.pressKey(key: .tab, modifiers: [.cmd, .cmd], count: 1), .repeatedModifier)
        refused(.pressKey(key: .tab, modifiers: [], count: 0), .notPositive(argument: "count"))
        refused(.scroll(direction: .up, lines: 0, target: nil, section: nil), .notPositive(argument: "lines"))
        refused(.drag(from: "A", to: .offset(dx: .nan, dy: 0), section: nil), .notFinite(argument: "dx"))
        refused(.drag(from: "A", to: .offset(dx: 0, dy: -.infinity), section: nil), .notFinite(argument: "dy"))
        #expect(throws: Never.self) { try AgentCallRequest.pressKey(key: .tab, modifiers: [], count: 500).validate() }
    }

    @Test("stored rows the contract does not admit are refused on the way out: name, kind, duplicate, position, gap, missing row, unknown code as bytes, both or neither drag ends, a value with another verb, NaN")
    func malformedRows() {
        func refused(_ tool: AgentTool, _ rows: [BrainArgument], _ malformation: AgentCallError.Malformation) {
            #expect(throws: AgentCallError.malformedCall(eventID: "e", malformation: malformation)) {
                _ = try AgentCallRequest(tool: tool, arguments: rows, eventID: "e")
            }
        }
        func row(_ name: String, _ value: BrainArgument.Value, _ position: Int = 0) -> BrainArgument {
            BrainArgument(name: name, position: position, value: value)
        }
        let act = AgentCallRequest.act(target: "Send", verb: .click, value: nil, section: nil).arguments
        refused(.act, act + [row("text", .text("x"))], .forbiddenArgument("text"))
        refused(.status, [row("session", .text("s"))], .forbiddenArgument("session"))
        refused(.act, [row("target", .integer(1)), row("verb", .text("click"))], .argumentKindMismatch("target"))
        refused(.act, act + [row("target", .text("Other"))], .duplicateArgument("target", position: 0))
        refused(.act, [row("target", .text("Send"), 1), row("verb", .text("click"))], .positionsNotContiguous("target"))
        refused(.act, [row("target", .text("Send"))], .missingArgument("verb"))
        refused(.act, [row("target", .text("Send")), row("verb", .text("Click"))], .unknownCode(argument: "verb", code: "Click"))
        refused(.act, [row("target", .text("Send")), row("verb", .text("click")), row("value", .text("on"))],
                .incompatibleArguments("valueWithoutToggle"))
        refused(.pressKey, [row("key", .text("RETURN")), row("count", .integer(1))], .unknownCode(argument: "key", code: "RETURN"))
        refused(.pressKey, [row("key", .text("tab")), row("modifiers", .text("cmd"), 1), row("count", .integer(1))],
                .positionsNotContiguous("modifiers"))
        refused(.pressKey, [row("key", .text("tab")), row("modifiers", .text("meta")), row("count", .integer(1))],
                .unknownCode(argument: "modifiers", code: "meta"))
        refused(.drag, [row("from", .text("A")), row("to", .text("B")), row("dx", .real(1)), row("dy", .real(1))],
                .incompatibleArguments("to, dx, dy"))
        refused(.drag, [row("from", .text("A")), row("dx", .real(1))], .incompatibleArguments("to, dx, dy"))
        refused(.drag, [row("from", .text("A")), row("dx", .real(.nan)), row("dy", .real(0))], .invalidValue("dx"))
        refused(.scroll, [row("direction", .text("left")), row("lines", .integer(3))], .unknownCode(argument: "direction", code: "left"))
        refused(.typeText, [row("target", .text("T")), row("text", .text("x"))], .missingArgument("replace"))
    }

    @Test("a call is an action event, and a tool that takes the session needs the event's session; the listings and open_session do not")
    func records() throws {
        func event(session: String?, kind: MemoryEventKind = .action) -> MemoryEventRecord {
            MemoryEventRecord(eventID: "e", source: .app, streamID: "w", sessionID: session, kind: kind, occurredAtMS: 1)
        }
        #expect(throws: AgentCallError.invalidRequest(.notAnAction)) {
            _ = try AgentCallRecord(event: event(session: "s", kind: .input), request: .observe)
        }
        for tool in AgentTool.allCases where tool.takesSession {
            let request = Self.requests.first { $0.1.tool == tool }!.1
            #expect(throws: AgentCallError.invalidRequest(.missingSession), Comment(rawValue: tool.rawValue)) {
                _ = try AgentCallRecord(event: event(session: nil), request: request)
            }
        }
        for request in [AgentCallRequest.status, .windows(app: nil), .apps(query: nil), .openSession(app: "Mail", window: nil)] {
            _ = try AgentCallRecord(event: event(session: nil), request: request)
        }
        #expect(Set(AgentTool.allCases.filter(\.isBatchStep)) == [.act, .select, .typeText, .insertText, .pressKey, .scroll, .drag, .contextMenu])
    }

    @Test("a progress carries what its tool reports in that state: no instant before the end, an instant at every end, the outcome of an action, the counts of a batch, an error for a failure, nothing a listing returns")
    func progressShapes() throws {
        let outcome = AgentCallResult.outcome(.honestMiss, message: "No Send here.")
        try AgentCallProgress(.completed, result: outcome, endedAtMS: 5).validate(for: .act)
        try AgentCallProgress(.completed, result: .batch(stopped: true, attempted: 2, verified: 1), endedAtMS: 5).validate(for: .batch)
        try AgentCallProgress(.completed, result: .closed(message: "Application session closed."), endedAtMS: 5).validate(for: .closeSession)
        try AgentCallProgress(.completed, endedAtMS: 5).validate(for: .observe)
        try AgentCallProgress(.failed, result: .error(message: "Session ID is missing or stale."), endedAtMS: 5).validate(for: .windows)
        try AgentCallProgress(.skipped, endedAtMS: 5).validate(for: .select)
        func refused(_ progress: AgentCallProgress, _ tool: AgentTool, _ invalidity: AgentCallError.Invalidity) {
            #expect(throws: AgentCallError.invalidProgress(invalidity)) { try progress.validate(for: tool) }
        }
        refused(AgentCallProgress(.started, endedAtMS: 5), .act, .endForbidden)
        refused(AgentCallProgress(.completed, result: outcome), .act, .endMissing)
        refused(AgentCallProgress(.completed, endedAtMS: 5), .act, .resultMismatch)
        refused(AgentCallProgress(.completed, result: outcome, endedAtMS: 5), .observe, .resultMismatch)
        refused(AgentCallProgress(.completed, result: outcome, endedAtMS: 5), .status, .resultMismatch)
        refused(AgentCallProgress(.completed, result: outcome, endedAtMS: 5), .batch, .resultMismatch)
        refused(AgentCallProgress(.failed, endedAtMS: 5), .act, .resultMismatch)
        refused(AgentCallProgress(.skipped, result: outcome, endedAtMS: 5), .act, .resultForbidden)
        refused(AgentCallProgress(.completed, result: .batch(stopped: false, attempted: 1, verified: 2), endedAtMS: 5), .batch, .batchCounts)
    }

    @Test("the moves: planned starts, is skipped or cancelled; started completes, fails, is cancelled or interrupted; the stored state again is a retry; another end is a conflict; anything else is refused")
    func transitions() throws {
        let statuses = AgentCallStatus.allCases
        for from in statuses {
            for to in statuses {
                let stored = AgentCallProgress(from, result: from == .failed ? .error(message: "x") : nil,
                                               endedAtMS: from.isTerminal ? 5 : nil)
                let offered = AgentCallProgress(to, result: to == .failed ? .error(message: "x") : nil,
                                                endedAtMS: to.isTerminal ? 5 : nil)
                let label = Comment(rawValue: "\(from.rawValue) → \(to.rawValue)")
                if from == to {
                    #expect(try offered.decision(after: stored, eventID: "e") == false, label)
                } else if from.next.contains(to) {
                    #expect(try offered.decision(after: stored, eventID: "e") == true, label)
                } else if from.isTerminal, to.isTerminal {
                    #expect(throws: AgentCallError.conflictingEnd(eventID: "e", stored: from, offered: to), label) {
                        _ = try offered.decision(after: stored, eventID: "e")
                    }
                } else {
                    #expect(throws: AgentCallError.invalidTransition(eventID: "e", from: from, to: to), label) {
                        _ = try offered.decision(after: stored, eventID: "e")
                    }
                }
            }
        }
        let done = AgentCallProgress(.completed, result: .outcome(.foundActed, message: "Clicked."), endedAtMS: 5)
        for other in [AgentCallProgress(.completed, result: .outcome(.actedUnverified, message: "Clicked."), endedAtMS: 5),
                      AgentCallProgress(.completed, result: .outcome(.foundActed, message: "Clicked!"), endedAtMS: 5),
                      AgentCallProgress(.completed, result: .outcome(.foundActed, message: "Clicked."), endedAtMS: 6)] {
            #expect(throws: AgentCallError.conflictingEnd(eventID: "e", stored: .completed, offered: .completed)) {
                _ = try other.decision(after: done, eventID: "e")
            }
        }
        #expect(Set(statuses.filter(\.isTerminal)) == [.completed, .failed, .cancelled, .interrupted, .skipped])
    }
}
