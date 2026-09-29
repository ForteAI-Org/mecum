//
//  ClickLivingMemoryTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import AutomationMCP
import EngineCore
import Foundation
import LocalMCP
import Memory
@testable import mecum
import PerceptionCore
@testable import SQLiteLivingMemory
import Testing

/// Learning and recalling a click, a double-click and a right-click through the production path,
/// offline: request, the tool adapter's `act`, the real engine and its evidence, the turn's events,
/// admission, the SQLite store and recall in a new instance. Each instance is a `MecumProcess` over
/// one temporary knowledge directory, in this test process; only the application window and the
/// provider are synthetic.
@Suite("Learning and recalling a click through the production path", .serialized)
struct ClickLivingMemoryTests {

    private let bundle = "test.synthetic.mixer"

    /// One verb's case: what the person asks, what the model calls, and what the gesture opens.
    nonisolated private struct Case: Sendable, CustomStringConvertible {
        let gesture: ClickEvidence.Gesture
        let target: String
        let request: String
        let recalling: String
        let opens: ClickEvidence.Surface

        var description: String { gesture.rawValue }
    }

    nonisolated private static let cases: [Case] = [
        Case(gesture: .click, target: "File", request: "Clicca File per aprire il menu",
             recalling: "Clicca File. Prima dimmi se hai un’esperienza verificata che può aiutare; poi osserva la "
                + "finestra attuale e agisci solo se il controllo è presente.",
             opens: .menu),
        Case(gesture: .doubleClick, target: "Project", request: "Fai doppio clic su Project per aprirlo",
             recalling: "Double-click Project to open the window. Tell me first if you remember how.",
             opens: .window(title: "Project 1")),
        Case(gesture: .rightClick, target: "Track 1", request: "Fai clic destro su Track 1",
             recalling: "Right-click Track 1 to open the context menu. Stop if it is not unique.",
             opens: .menu),
    ]

    /// A window with a menu button, a document, a track header and a toggle, each reacting to its gesture.
    private func studio() -> ControlSession.Window {
        let window = ControlSession.Window(bundleID: bundle, title: "Synthetic Mixer", toggles: [
            .init("File", nil), .init("Project", nil), .init("Track 1", nil), .init("Mute", .off),
        ])
        window.reactions = [
            "File"   : [.click: .menu(["New", "Open", "Save As"])],
            "Project": [.doubleClick: .window("Project 1")],
            "Track 1": [.rightClick: .menu(["Delete Track", "Duplicate Track", "Rename"])],
        ]
        return window
    }

    @MainActor
    private static func act(
        _ tools  : AutomationTools,
        _ id     : JSONValue,
        _ target : String,
        _ gesture: ClickEvidence.Gesture,
        section  : String? = nil
    ) async throws {
        var arguments: [String: JSONValue] = ["session": id, "target": .string(target),
                                              "verb": .string(gesture.rawValue)]
        if let section { arguments["section"] = .string(section) }
        _ = try await tools.call("act", .object(arguments))
    }

    private func outcome(_ end: TurnCycle.End) -> ExperienceEvent.Outcome? {
        end.report.event?.outcome
    }

    // MARK: Learning and recall

    @Test("a verified gesture is learned with its proof, recalled by its verb in a new instance, and confirmed once",
          arguments: cases)
    @MainActor
    private func learnedRecalledConfirmed(_ verb: Case) async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = studio()
            do {
                let first = try MecumProcess(knowledge: knowledge, window: window)
                let (start, end) = try await first.turn(verb.request) {
                    try await Self.act($0, $1, verb.target, verb.gesture)
                }
                #expect(start.memory?.briefing == nil)
                #expect(end.report.decision.reason == .admittedSingleClick)
                let arguments = ActionArguments(target: verb.target, verb: verb.gesture.verb)
                guard case .act(arguments, .foundActed, .click(let proof)?)? = end.report.attempts.last else {
                    Issue.record("the act attempt lost its arguments or evidence: \(end.report.attempts)"); return
                }
                #expect(proof.gesture == verb.gesture && proof.delivery == .sent && proof.surface == verb.opens)
                #expect(proof.windowTitle == "Synthetic Mixer")
                guard case .recorded(.applied(let record?), .admittedSingleClick)? = end.recording else {
                    Issue.record("nothing was recorded: \(String(describing: end.recording))"); return
                }
                #expect(record.step == .click(verb.gesture, target: verb.target, section: nil, opens: verb.opens))
                #expect(record.successCount == 1)
                #expect(end.recording?.notice
                        == "memory: remembered \(verb.gesture.rawValue) '\(verb.target)' to open "
                            + "\(verb.opens.summary), verified ×1")
                let again = await TurnRecorder(store: first.store).record(end.report)
                guard case .recorded(.duplicate(let same?), _) = again else {
                    Issue.record("a repeated delivery was not a duplicate: \(again)"); return
                }
                #expect(same.successCount == 1, "delivering the same turn twice counts it once")
                #expect(window.gestures == [verb.gesture], "one gesture, a double-click included")
            }

            window.closeSurfaces()
            let second = try MecumProcess(knowledge: knowledge, window: window)
            let (start, end) = try await second.turn(verb.recalling) {
                try await Self.act($0, $1, verb.target, verb.gesture)
            }
            let briefing = try #require(start.memory?.briefing)
            #expect(briefing.status == "suggested")
            #expect(briefing.remembered?.tool == verb.gesture.rawValue)
            #expect(briefing.remembered?.control == verb.target)
            #expect(briefing.remembered?.opens == verb.opens.summary)
            #expect(briefing.guidance.contains("use act with verb \(verb.gesture.rawValue)"))
            #expect(briefing.contextLine == "memory context: suggested \(verb.gesture.rawValue) '\(verb.target)' to open "
                    + "\(verb.opens.summary) (verified ×1, notObserved)")
            #expect(start.prompt.contains(#""tool":"\#(verb.gesture.rawValue)""#))
            #expect(end.report.decision.reason == .confirmsFollowedExperience)
            let records = try await second.experiences()
            #expect(records.count == 1 && records.first?.successCount == 2)
            let learned = try #require(records.first)
            #expect(try await second.store.history(of: learned.id).count == 2)
            #expect(window.gestures == [verb.gesture, verb.gesture], "one gesture per turn, never a replay")
        }
    }

    @Test("a remembered gesture is not recalled for another gesture, surface, target or section")
    @MainActor
    func noCrossGestureRecall() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = studio()
            do {
                let first = try MecumProcess(knowledge: knowledge, window: window)
                _ = try await first.turn("Fai clic destro su Track 1") {
                    try await Self.act($0, $1, "Track 1", .rightClick)
                }
            }
            window.closeSurfaces()
            let second = try MecumProcess(knowledge: knowledge, window: window)
            for request in ["Clicca Track 1", "Fai doppio clic su Track 1",
                            "Fai clic destro su Track 1 nella traccia 2",
                            "Fai clic destro su Track 1 per aprire la finestra", "Attiva Mute"] {
                let start = try await second.cycle.begin(request, sessionIsOpen: false)
                #expect(start.memory?.briefing == nil, "'\(request)'")
                _ = await second.cycle.end(.completed)
            }
        }
    }

    // MARK: What is never learned

    @Test("a surface elsewhere, several surfaces or another gesture than the request's teach nothing")
    @MainActor
    func unattributedAndMismatched() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = studio()
            let process = try MecumProcess(knowledge: knowledge, window: window)

            window.menuElsewhere = true
            let (_, elsewhere) = try await process.turn("Fai clic destro su Track 1") {
                try await Self.act($0, $1, "Track 1", .rightClick)
            }
            guard case .act(_, .foundActed, .click(let far)?)? = elsewhere.report.attempts.last else {
                Issue.record("the far menu was not reported: \(elsewhere.report.attempts)"); return
            }
            #expect(far.effect == .unattributed(.surfaceElsewhere), "found_acted, but nothing opened at the target")
            #expect(elsewhere.report.decision.reason == .notVerified)
            #expect(outcome(elsewhere) == .uncertain(.clickEffectUnattributed(.surfaceElsewhere)))

            window.closeSurfaces()
            window.menuElsewhere = false
            window.opensSecondWindow = true
            let (_, several) = try await process.turn("Fai doppio clic su Project") {
                try await Self.act($0, $1, "Project", .doubleClick)
            }
            #expect(outcome(several) == .uncertain(.clickEffectUnattributed(.severalSurfaces)))

            window.closeSurfaces()
            window.opensSecondWindow = false
            let (_, mismatch) = try await process.turn("Fai clic destro su File") {
                try await Self.act($0, $1, "File", .click)
            }
            #expect(mismatch.report.decision.reason == .gestureNotInGoal)
            guard case .keepAttempt(_, .verified(.click)) = mismatch.report.decision.action else {
                Issue.record("the verified click was not kept as history"); return
            }

            window.closeSurfaces()
            let (_, ghost) = try await process.turn("Fai clic destro su File") {
                try await Self.act($0, $1, "File", .rightClick)
            }
            #expect(outcome(ghost) == .uncertain(.clickEffectUnattributed(.noChange)))
            #expect(try await process.experiences().isEmpty)
        }
    }

    @Test("in a Seat capture of the window and its menu, the window's controls are no menu items and teach nothing")
    @MainActor
    func menuCapturedWithTheWindow() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            // The menu opens at Track 1 but paints nothing legible; the window's own controls share the capture.
            let window = studio()
            window.capturesMenuWithWindow = true
            window.menuRowsReadable = false
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, end) = try await process.turn("Fai clic destro su Track 1") {
                try await Self.act($0, $1, "Track 1", .rightClick)
            }
            guard case .act(_, _, .click(let proof)?)? = end.report.attempts.last else {
                Issue.record("no click evidence: \(end.report.attempts)"); return
            }
            #expect(proof.effect == .unattributed(.unreadableSurface), "\(proof.effect)")
            #expect(end.report.event?.outcome == .uncertain(.clickEffectUnattributed(.unreadableSurface)))
            #expect(end.report.decision.reason != .admittedSingleClick)
            #expect(try await process.experiences().isEmpty)
        }
        try await MecumProcess.withKnowledge { knowledge in
            // Its rows readable, the same capture names only them, and the gesture is learned.
            let window = studio()
            window.capturesMenuWithWindow = true
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, end) = try await process.turn("Fai clic destro su Track 1") {
                try await Self.act($0, $1, "Track 1", .rightClick)
            }
            guard case .act(_, .foundActed, .click(let proof)?)? = end.report.attempts.last else {
                Issue.record("the menu was not proven: \(end.report.attempts)"); return
            }
            #expect(proof.effect == .menuOpened(items: ["Delete Track", "Duplicate Track", "Rename"]))
            #expect(end.report.decision.reason == .admittedSingleClick)
            #expect(try await process.experiences().count == 1)
        }
    }

    @Test("a compound request, a batch and a failed call keep what happened but teach nothing")
    @MainActor
    func compoundBatchAndFailure() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = studio()
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, compound) = try await process.turn("Fai clic destro su Track 1 e poi elimina la traccia") {
                try await Self.act($0, $1, "Track 1", .rightClick)
            }
            #expect(compound.report.decision.reason == .compoundGoal)
            guard case .keepAttempt(_, .verified(.click)) = compound.report.decision.action else {
                Issue.record("the verified step of a compound goal was not kept as history"); return
            }

            window.closeSurfaces()
            let (_, batch) = try await process.turn("Fai clic destro su Track 1") { tools, id in
                _ = try await tools.call("batch", .object(["session": id, "steps": .array([.object([
                    "operation": .string("act"), "target": .string("Track 1"), "verb": .string("right_click"),
                ])])]))
            }
            #expect(batch.report.decision.reason == .batchUsed)
            #expect(batch.report.batchSteps.first?.operation
                    == .act(ActionArguments(target: "Track 1", verb: .rightClick)))

            window.closeSurfaces()
            process.session.actFails = true
            let (_, transport) = try await process.turn("Fai clic destro su Track 1") { tools, id in
                _ = try? await tools.call("act", .object(["session": id, "target": .string("Track 1"),
                                                          "verb": .string("right_click")]))
            }
            #expect(transport.report.attempts.last
                    == .failed("act", act: ActionArguments(target: "Track 1", verb: .rightClick)))
            #expect(transport.report.decision.reason == .toolFailed)

            process.session.actFails = false
            window.clickFails = true
            let (_, delivery) = try await process.turn("Fai clic destro su Track 1") {
                try await Self.act($0, $1, "Track 1", .rightClick)
            }
            #expect(outcome(delivery) == .uncertain(.failureNotAttributable))
            #expect(try await process.experiences().isEmpty)
        }
    }

    // MARK: Beside selects and toggles

    @Test("an empty window list before the gesture credits it with no window, not even the one it was sent in",
          arguments: [(ClickEvidence.Gesture.click, "Clicca Mute"), (.doubleClick, "Fai doppio clic su Mute"),
                      (.rightClick, "Fai clic destro su Mute")])
    @MainActor
    private func emptyListingBeforeGesture(_ gesture: ClickEvidence.Gesture, _ request: String) async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = ControlSession.Window(bundleID: bundle, title: "Synthetic Mixer",
                                               toggles: [.init("Mute", nil), .init("Solo", nil)])
            window.gestureRevealsDetails = true
            window.listsNothingBeforeNextGesture = true
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, end) = try await process.turn(request) { try await Self.act($0, $1, "Mute", gesture) }
            guard case .act(_, let kind, .click(let proof)?)? = end.report.attempts.last else {
                Issue.record("no click evidence: \(end.report.attempts)"); return
            }
            #expect(proof.surface == nil, "\(gesture): \(proof.effect)")
            #expect(proof.effect == .unattributed(.originNotListed))
            #expect(kind != .foundActed || proof.surface == nil)
            #expect(end.report.decision.reason == .notVerified)
            guard case .keepAttempt(_, .uncertain(.clickEffectUnattributed(.originNotListed))) = end.report.decision.action
            else { Issue.record("not kept as uncertain history: \(end.report.decision)"); return }
            #expect(try await process.experiences().isEmpty)
            #expect(window.gestures == [gesture])
        }
    }

    /// The error a transcript that cannot be written raises, after the tool's effect.
    private struct TranscriptUnwritable: Error {}

    @Test("an interrupted turn keeps a verified gesture as history and teaches nothing", arguments: cases)
    @MainActor
    private func interruptedGesture(_ verb: Case) async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = studio()
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, end) = try await process.turn(verb.request, ending: .interrupted) {
                try await Self.act($0, $1, verb.target, verb.gesture)
            }
            #expect(end.report.decision.reason == .turnInterrupted)
            guard case .keepAttempt(_, .verified(.click(let proof))) = end.report.decision.action else {
                Issue.record("the gesture was not kept as history: \(end.report.decision)"); return
            }
            #expect(proof.surface == verb.opens)
            #expect(try await process.experiences().isEmpty)
            #expect(window.gestures == [verb.gesture])
        }
    }

    @Test("a transcript that cannot be written after a verified gesture teaches nothing and repeats nothing",
          arguments: cases)
    @MainActor
    private func transcriptFailsAfterTheGesture(_ verb: Case) async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = studio()
            let process = try MecumProcess(knowledge: knowledge, window: window)
            process.tools.record = { line in if line.hasPrefix("← act") { throw TranscriptUnwritable() } }
            let (_, end) = try await process.turn(verb.request) { tools, id in
                await #expect(throws: TranscriptUnwritable.self) {
                    try await Self.act(tools, id, verb.target, verb.gesture)
                }
            }
            let arguments = ActionArguments(target: verb.target, verb: verb.gesture.verb)
            #expect(end.report.attempts.last == .failed("act", act: arguments))
            #expect(end.report.decision.reason == .toolFailed)
            guard case .keepAttempt(_, .verified(.click)) = end.report.decision.action else {
                Issue.record("the verified gesture was not kept as history: \(end.report.decision)"); return
            }
            #expect(try await process.experiences().isEmpty)
            #expect(window.gestures == [verb.gesture])
        }
    }

    @Test("a click, a toggle and a legacy select live in one store, and mecum memory reads them all")
    @MainActor
    func besideTogglesAndSelects() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)
            do {
                let version1 = SQLiteLivingMemorySchema(migrations: [SQLiteLivingMemorySchema.current.migrations[0]])
                let legacy = try SQLiteLivingMemoryStore(file: file, access: .readWrite,
                                                         makeID: { ExperienceID("legacy-select") }, schema: version1)
                let proof = DropdownEvidence(bundleID: bundle, windowTitle: "Synthetic I/O Setup", control: "All Busses",
                                             controlRole: "AXPopUpButton", section: nil, valueBefore: "All Busses",
                                             requestedItem: "Output Busses", readback: .window("Output Busses"),
                                             menuClosedByChoice: true)
                let setup = try #require(WindowContext(bundleID: bundle, windowTitle: "Synthetic I/O Setup"))
                let draft = try #require(ExperienceDraft(phrase: "Seleziona Output Busses", step: ExperienceStep(proof),
                                                         context: setup))
                _ = try await legacy.record(ExperienceEvent(id: "turn-legacy", subject: .step(draft),
                                                            outcome: .verified(.dropdown(proof)), at: Date()))
            }
            let window = studio()
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, toggle) = try await process.turn("Attiva Mute") { tools, id in
                _ = try await tools.call("act", .object(["session": id, "target": .string("Mute"),
                                                         "verb": .string("set_toggle"), "value": .string("on")]))
            }
            #expect(toggle.report.decision.reason == .admittedSingleToggle)
            let (_, click) = try await process.turn("Fai doppio clic su Project") {
                try await Self.act($0, $1, "Project", .doubleClick)
            }
            #expect(click.report.decision.reason == .admittedSingleClick)
            #expect(try await process.experiences().map(\.step.tool) == [.select, .setToggle, .doubleClick])

            let inspection = await LivingMemoryReport.lines(bundleID: bundle, knowledgeDirectory: knowledge)
                .joined(separator: "\n")
            #expect(inspection.contains("step: select 'Output Busses' in the control that read 'All Busses'"))
            #expect(inspection.contains("step: set_toggle 'Mute' to on"))
            #expect(inspection.contains("step: double_click 'Project' to open the window 'Project 1'"))
            #expect(inspection.contains("proof: double_click sent (2 clicks) on 'Project', the new window "
                                        + "\"Project 1\" opened, from window \"Synthetic Mixer\""))
        }
    }
}
