//
//  ToggleLivingMemoryTests.swift
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

/// Learning and recalling a toggle through the production path, offline: request, the tool
/// adapter's `act` with `set_toggle`, the real engine and its evidence, the turn's events, admission,
/// the SQLite store and recall in a new instance. Each `MecumProcess` instance has its own store,
/// brain, session, tools and turn cycle over one temporary knowledge directory, in this test process;
/// only the application window and the provider are synthetic, the provider being the tool calls a
/// model would make.
@Suite("Learning and recalling a toggle through the production path", .serialized)
struct ToggleLivingMemoryTests {

    private let bundle = "test.synthetic.mixer"
    private let recalling = "Attiva Mute. Prima dimmi se hai un’esperienza verificata che può aiutare; poi osserva "
        + "la finestra attuale e agisci solo se il controllo è presente."

    @MainActor
    private static func setToggle(_ tools: AutomationTools, _ id: JSONValue, _ value: String,
                                  target: String = "Mute", section: String? = nil) async throws {
        var arguments: [String: JSONValue] = ["session": id, "target": .string(target),
                                              "verb": .string("set_toggle"), "value": .string(value)]
        if let section { arguments["section"] = .string(section) }
        _ = try await tools.call("act", .object(arguments))
    }

    /// A mixer with a Mute in two tracks: one label, one id, two sections.
    private func tracks(_ first: ControlState?, _ second: ControlState?) -> ControlSession.Window {
        ControlSession.Window(bundleID: bundle, title: "Synthetic Mixer", toggles: [
            .init("Mute", first, section: "Track 1"), .init("Mute", second, section: "Track 2"),
        ])
    }

    private func mixer(_ mute: ControlState?, title: String = "Synthetic Mixer") -> ControlSession.Window {
        ControlSession.Window(bundleID: bundle, title: title, toggles: [.init("Mute", mute), .init("Solo", .off)])
    }

    private func outcome(_ end: TurnCycle.End) -> ExperienceEvent.Outcome? {
        end.report.event?.outcome
    }

    // MARK: Learning and recall

    @Test("off to on is learned with its proof, then recalled as a state and confirmed in a new instance")
    @MainActor
    func offToOnLearnedRecalledConfirmed() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            do {
                let first = try MecumProcess(knowledge: knowledge, window: window)
                let (start, end) = try await first.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
                #expect(start.memory?.briefing == nil)
                #expect(end.report.decision.reason == .admittedSingleToggle)
                let arguments = ActionArguments(target: "Mute", verb: .setToggle, desiredState: .on)
                guard case .act(arguments, .foundActed, .toggle(let proof)?)? = end.report.attempts.last else {
                    Issue.record("the act attempt lost its arguments or evidence: \(end.report.attempts)"); return
                }
                #expect(proof.stateBefore == .read(.off, .resolvedElement))
                #expect(proof.click == .sent && proof.stateAfter == .read(.on, .sameElement))
                guard case .recorded(.applied(let record?), .admittedSingleToggle)? = end.recording else {
                    Issue.record("nothing was recorded: \(String(describing: end.recording))"); return
                }
                #expect(record.step == .setToggle(control: "Mute", section: nil, state: .on))
                #expect(record.successCount == 1)
                #expect(end.recording?.notice == "memory: remembered set 'Mute' on, verified ×1")
                #expect(window.state(of: "Mute") == .on && window.clicks == 1)
            }

            window.set("Mute", .off)
            let second = try MecumProcess(knowledge: knowledge, window: window)
            let (start, end) = try await second.turn(recalling) { try await Self.setToggle($0, $1, "on") }
            let briefing = try #require(start.memory?.briefing)
            #expect(briefing.status == "suggested")
            #expect(briefing.remembered?.tool == "set_toggle")
            #expect(briefing.remembered?.control == "Mute" && briefing.remembered?.state == "on")
            #expect(briefing.remembered?.item == nil)
            #expect(briefing.guidance.contains("verb set_toggle"))
            #expect(briefing.contextLine == "memory context: suggested set_toggle 'Mute' on (verified ×1, notObserved)")
            #expect(start.prompt.hasPrefix("<mecum-memory>\n") && start.prompt.contains(#""tool":"set_toggle""#))
            #expect(end.report.decision.reason == .confirmsFollowedExperience)
            let records = try await second.experiences()
            #expect(records.count == 1 && records.first?.successCount == 2)
            let learned = try #require(records.first)
            #expect(try await second.store.history(of: learned.id).count == 2)
            #expect(window.clicks == 2, "one click per turn, never a replay")
        }
    }

    @Test("on to off is learned as its own state, and a request for on does not recall it")
    @MainActor
    func onToOffIsItsOwnExperience() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.on)
            do {
                let first = try MecumProcess(knowledge: knowledge, window: window)
                let (_, end) = try await first.turn("Disattiva Mute") { try await Self.setToggle($0, $1, "off") }
                #expect(end.report.decision.reason == .admittedSingleToggle)
                #expect(try await first.experiences().map(\.step)
                        == [.setToggle(control: "Mute", section: nil, state: .off)])
                #expect(window.state(of: "Mute") == .off)
            }
            let second = try MecumProcess(knowledge: knowledge, window: window)
            let asksOn = try await second.cycle.begin("Attiva Mute", sessionIsOpen: false)
            #expect(asksOn.memory?.briefing == nil)
            _ = await second.cycle.end(.completed)
            let asksOff = try await second.cycle.begin("Disattiva Mute", sessionIsOpen: false)
            #expect(asksOff.memory?.briefing?.remembered?.state == "off")
            _ = await second.cycle.end(.completed)
        }
    }

    @Test("a toggle already in the requested state is no change: nothing is learned or confirmed")
    @MainActor
    func alreadySetNeverCounts() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.on)
            let first = try MecumProcess(knowledge: knowledge, window: window)
            let (_, noop) = try await first.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            #expect(noop.report.decision.reason == .alreadySet)
            guard case .noChange(.toggle(let proof))? = outcome(noop) else {
                Issue.record("no change was not kept: \(String(describing: outcome(noop)))"); return
            }
            #expect(proof.click == .none)
            #expect(try await first.experiences().isEmpty)
            #expect(window.clicks == 0)

            window.set("Mute", .off)
            _ = try await first.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            let (start, followed) = try await first.turn(recalling) { try await Self.setToggle($0, $1, "on") }
            #expect(start.memory?.briefing?.status == "suggested")
            #expect(followed.report.decision.reason == .alreadySet)
            #expect(try await first.experiences().first?.successCount == 1, "no change never confirms")
            #expect(window.clicks == 1)
        }
    }

    // MARK: Uncertain and failed attempts

    @Test("an unreadable start is refused without a click; an ambiguous end is uncertain")
    @MainActor
    func unknownAndAmbiguous() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let unread = mixer(.off)
            unread.showsStates = false
            let first = try MecumProcess(knowledge: knowledge, window: unread)
            let (_, refused) = try await first.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            #expect(unread.clicks == 0, "no blind click")
            #expect(refused.report.decision.reason == .notVerified)
            #expect(outcome(refused) == .uncertain(.toggleStateUnreadable(.indefinite)))

            let split = mixer(.off)
            split.splitsAfterClick = true
            let second = try MecumProcess(knowledge: knowledge, window: split)
            let (_, ambiguous) = try await second.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            #expect(split.clicks == 1)
            guard case .act(_, .actedUnverified, .toggle(let proof)?)? = ambiguous.report.attempts.last else {
                Issue.record("the ambiguous attempt lost its evidence"); return
            }
            #expect(proof.stateAfter == .unreadable(.severalMatches))
            #expect(outcome(ambiguous) == .uncertain(.toggleStateUnreadable(.severalMatches)))
            #expect(try await second.experiences().isEmpty)
        }
    }

    @Test("a failed call keeps the act's arguments, and a failed click is not attributable")
    @MainActor
    func failures() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            let process = try MecumProcess(knowledge: knowledge, window: window)
            process.session.actFails = true
            let (_, transport) = try await process.turn("Attiva Mute") { tools, id in
                _ = try? await tools.call("act", .object(["session": id, "target": .string("Mute"),
                                                          "verb": .string("set_toggle"), "value": .string("on"),
                                                          "section": .string("Track 1")]))
            }
            let wanted = ActionArguments(target: "Mute", verb: .setToggle, section: "Track 1", desiredState: .on)
            #expect(transport.report.attempts.last == .failed("act", act: wanted))
            #expect(transport.report.decision.reason == .toolFailed)
            #expect(transport.recording == .nothingToRecord(.toolFailed))

            process.session.actFails = false
            let (_, malformed) = try await process.turn("Attiva Mute") { tools, id in
                _ = try? await tools.call("act", .object(["session": id, "target": .string("Mute"),
                                                          "verb": .string("set_toggle"), "value": .string("maybe")]))
            }
            #expect(malformed.report.attempts.last
                    == .failed("act", act: ActionArguments(target: "Mute", verb: .setToggle, desiredState: nil)))

            window.clickFails = true
            let (_, delivery) = try await process.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            #expect(outcome(delivery) == .uncertain(.failureNotAttributable))
            #expect(try await process.experiences().isEmpty)
            #expect(window.state(of: "Mute") == .off)
        }
    }

    // MARK: Context and goal

    @Test("the other state in another window contradicts nothing; in the learned window it contradicts")
    @MainActor
    func contextBoundContradiction() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            do {
                let first = try MecumProcess(knowledge: knowledge, window: window)
                _ = try await first.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            }
            let master = mixer(.off, title: "Synthetic Master")
            master.clickFlips = false
            let second = try MecumProcess(knowledge: knowledge, window: master)
            let (start, elsewhere) = try await second.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            #expect(start.memory?.followed?.context == WindowContext(bundleID: bundle, windowTitle: "Synthetic Mixer"))
            guard case .keepAttempt(let context, .contradicted(.readbackShowed("off"))) = elsewhere.report.decision.action
            else { Issue.record("another window's reading was not kept apart"); return }
            #expect(context.windowFamily == "syntheticmaster")
            #expect(try await second.experiences().first?.failureCount == 0)

            window.set("Mute", .off)
            window.clickFlips = false
            let third = try MecumProcess(knowledge: knowledge, window: window)
            let (_, here) = try await third.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            #expect(here.report.decision.reason == .contradictsFollowedExperience)
            let record = try #require(try await third.experiences().first)
            #expect(record.successCount == 1 && record.failureCount == 1)
        }
    }

    @Test("a compound request and a batch keep what happened but teach nothing")
    @MainActor
    func compoundAndBatch() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, compound) = try await process.turn("Attiva Mute e poi esporta il mix") {
                try await Self.setToggle($0, $1, "on")
            }
            #expect(compound.report.decision.reason == .compoundGoal)
            guard case .keepAttempt(_, .verified(.toggle)) = compound.report.decision.action else {
                Issue.record("the verified step of a compound goal was not kept as history"); return
            }
            window.set("Mute", .off)
            let (_, batch) = try await process.turn("Attiva Mute") { tools, id in
                _ = try await tools.call("batch", .object(["session": id, "steps": .array([.object([
                    "operation": .string("act"), "target": .string("Mute"), "verb": .string("set_toggle"),
                    "value": .string("on"),
                ])])]))
            }
            #expect(batch.report.decision.reason == .batchUsed)
            #expect(batch.report.batchSteps.first?.operation
                    == .act(ActionArguments(target: "Mute", verb: .setToggle, desiredState: .on)))
            #expect(try await process.experiences().isEmpty)
        }
    }

    /// The error a transcript that cannot be written raises, after the tool's effect.
    private struct TranscriptUnwritable: Error {}

    @Test("a redelivered report counts once, and a second real turn counts again")
    @MainActor
    func redeliveryAgainstASecondRun() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, first) = try await process.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            guard case .recorded(.applied(let learned?), .admittedSingleToggle)? = first.recording else {
                Issue.record("nothing was learned: \(String(describing: first.recording))"); return
            }
            guard case .recorded(.duplicate(let same?), _) = await TurnRecorder(store: process.store)
                .record(first.report) else { Issue.record("a redelivery was not a duplicate"); return }
            #expect(same.successCount == 1)
            window.set("Mute", .off)
            let (_, second) = try await process.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            #expect(second.report.turnID != first.report.turnID)
            #expect(second.report.decision.reason == .confirmsFollowedExperience)
            let records = try await process.experiences()
            #expect(records.count == 1 && records.first?.successCount == 2)
            #expect(try await process.store.history(of: learned.id).count == 2)
            #expect(window.clicks == 2)
        }
    }

    @Test("an interrupted turn, and a turn with a second attempt, keep what happened but teach nothing")
    @MainActor
    func interruptedAndRetried() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, interrupted) = try await process.turn("Attiva Mute", ending: .interrupted) {
                try await Self.setToggle($0, $1, "on")
            }
            #expect(interrupted.report.decision.reason == .turnInterrupted)
            guard case .keepAttempt(_, .verified(.toggle)) = interrupted.report.decision.action else {
                Issue.record("the interrupted turn's verified toggle was not kept as history"); return
            }
            #expect(interrupted.recording == .recorded(.applied(nil), .turnInterrupted))
            window.set("Mute", .off)
            let (_, retried) = try await process.turn("Attiva Mute") { tools, id in
                try await Self.setToggle(tools, id, "on")
                try await Self.setToggle(tools, id, "on")
            }
            #expect(retried.report.decision.reason == .severalSteps)
            #expect(retried.report.decision.action == .nothing)
            #expect(try await process.experiences().isEmpty)
            #expect(window.clicks == 2, "the second attempt found Mute on and sent nothing")
        }
    }

    @Test("a transcript that cannot be written after a verified toggle teaches nothing and repeats nothing")
    @MainActor
    func transcriptFailsAfterTheEffect() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            let process = try MecumProcess(knowledge: knowledge, window: window)
            process.tools.record = { line in if line.hasPrefix("← act") { throw TranscriptUnwritable() } }
            let (_, end) = try await process.turn("Attiva Mute") { tools, id in
                await #expect(throws: TranscriptUnwritable.self) { try await Self.setToggle(tools, id, "on") }
            }
            let wanted = ActionArguments(target: "Mute", verb: .setToggle, desiredState: .on)
            guard case .act(wanted, .foundActed, .toggle(let proof)?)? = end.report.attempts.dropLast().last else {
                Issue.record("the effect's outcome was lost: \(end.report.attempts)"); return
            }
            #expect(proof.change == .changed)
            #expect(end.report.attempts.last == .failed("act", act: wanted))
            #expect(end.report.decision.reason == .toolFailed)
            guard case .keepAttempt(_, .verified(.toggle)) = end.report.decision.action else {
                Issue.record("the verified toggle was not kept as history"); return
            }
            #expect(try await process.experiences().isEmpty)
            #expect(window.state(of: "Mute") == .on && window.clicks == 1)
        }
    }

    // MARK: Contested cases

    @Test("a Mute in another track never proves the one that was clicked")
    @MainActor
    func homonymInAnotherTrack() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = tracks(.off, .on)
            window.hidesClickedState = true
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, end) = try await process.turn("Attiva Mute in Track 1") {
                try await Self.setToggle($0, $1, "on", section: "Track 1")
            }
            guard case .act(_, .actedUnverified, .toggle(let proof)?)? = end.report.attempts.last else {
                Issue.record("the homonym's state was taken as proof: \(end.report.attempts)"); return
            }
            #expect(proof.stateAfter == .unreadable(.indefinite))
            #expect(outcome(end) == .uncertain(.toggleStateUnreadable(.indefinite)))
            #expect(try await process.experiences().isEmpty)
        }
    }

    @Test("two readable homonyms are told apart by section, and the section the request names is remembered")
    @MainActor
    func sectionRememberedAndRequired() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = tracks(.off, .off)
            do {
                let first = try MecumProcess(knowledge: knowledge, window: window)
                let (_, end) = try await first.turn("Attiva Mute in Track 1") {
                    try await Self.setToggle($0, $1, "on", section: "Track 1")
                }
                #expect(end.report.decision.reason == .admittedSingleToggle)
                #expect(try await first.experiences().map(\.step)
                        == [.setToggle(control: "Mute", section: "Track 1", state: .on)])
                #expect(window.state(of: "Mute", section: "Track 1") == .on)
                #expect(window.state(of: "Mute", section: "Track 2") == .off)
            }
            window.set("Mute", .off, section: "Track 1")
            let second = try MecumProcess(knowledge: knowledge, window: window)
            let (start, wrong) = try await second.turn("Attiva Mute in Track 2") {
                try await Self.setToggle($0, $1, "on", section: "Track 1")
            }
            #expect(start.memory?.briefing == nil, "Track 1 is not recalled for Track 2")
            #expect(wrong.report.decision.reason == .sectionNotInGoal)
            #expect(try await second.experiences().first?.successCount == 1, "acting on Track 1 confirms nothing")

            window.set("Mute", .off, section: "Track 1")
            let (again, confirmed) = try await second.turn("Attiva Mute in Track 1") {
                try await Self.setToggle($0, $1, "on", section: "Track 1")
            }
            #expect(again.memory?.briefing?.remembered?.section == "Track 1")
            #expect(confirmed.report.decision.reason == .confirmsFollowedExperience)
            #expect(try await second.experiences().first?.successCount == 2)
        }
    }

    /// Pro Tools, 28/09/2026: both Mutes lie in one scene section and each strip's controls carry their track
    /// as a container, rendered "Mute {Track 2}". The call named the container; the proof named the section.
    @Test("a toggle found by its container is learned under that container, then recalled and confirmed by it")
    @MainActor
    func containerNamesTheToggle() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = ControlSession.Window(bundleID: bundle, title: "Synthetic Mixer", toggles: [
                .init("Mute", .off, section: "AUTO", container: "Track 1"),
                .init("Mute", .off, section: "AUTO", container: "Track 2"),
            ])
            do {
                let first = try MecumProcess(knowledge: knowledge, window: window)
                let (_, end) = try await first.turn("Attiva Mute in Track 2") {
                    try await Self.setToggle($0, $1, "on", target: "Mute {Track 2} (row#3)")
                }
                #expect(end.report.decision.reason == .admittedSingleToggle)
                #expect(try await first.experiences().map(\.step)
                        == [.setToggle(control: "Mute", section: "Track 2", state: .on)])
                #expect(window.state(of: "Mute", section: "AUTO", container: "Track 2") == .on)
                #expect(window.state(of: "Mute", section: "AUTO", container: "Track 1") == .off)
            }
            window.set("Mute", .off, section: "AUTO", container: "Track 2")
            let second = try MecumProcess(knowledge: knowledge, window: window)
            let (start, confirmed) = try await second.turn("Attiva Mute in Track 2") {
                try await Self.setToggle($0, $1, "on", target: "Mute", section: "Track 2")
            }
            #expect(start.memory?.briefing?.remembered?.section == "Track 2")
            #expect(confirmed.report.decision.reason == .confirmsFollowedExperience)
            #expect(try await second.experiences().first?.successCount == 2)
        }
    }

    @Test("a memory learned without a section is neither recalled nor confirmed for a request about Track 2")
    @MainActor
    func genericMemoryAndAnotherSection() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            do {
                let first = try MecumProcess(knowledge: knowledge, window: mixer(.off))
                let (_, learned) = try await first.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
                #expect(learned.report.decision.reason == .admittedSingleToggle)
            }
            let window = tracks(.off, .off)
            let second = try MecumProcess(knowledge: knowledge, window: window)
            let (start, track1) = try await second.turn("Attiva Mute in Track 2") {
                try await Self.setToggle($0, $1, "on", section: "Track 1")
            }
            #expect(start.memory?.briefing == nil, "a memory without a section says nothing about Track 2")
            #expect(start.memory?.followed == nil)
            #expect(track1.report.decision.reason == .sectionNotInGoal)

            let (_, undisambiguated) = try await second.turn("Attiva Mute in Track 2") {
                try await Self.setToggle($0, $1, "on")
            }
            guard case .act(_, .ambiguous, nil)? = undisambiguated.report.attempts.last else {
                Issue.record("two Mutes resolved without a section: \(undisambiguated.report.attempts)"); return
            }
            #expect(undisambiguated.report.decision.reason == .noEvidence)

            let (_, track2) = try await second.turn("Attiva Mute in Track 2") {
                try await Self.setToggle($0, $1, "on", section: "Track 2")
            }
            #expect(track2.report.decision.reason == .admittedSingleToggle)
            let records = try await second.experiences()
            #expect(records.map(\.step) == [.setToggle(control: "Mute", section: nil, state: .on),
                                            .setToggle(control: "Mute", section: "Track 2", state: .on)])
            #expect(records.map(\.successCount) == [1, 1], "the generic memory was never confirmed")
            #expect(window.state(of: "Mute", section: "Track 1") == .on)
            #expect(window.state(of: "Mute", section: "Track 2") == .on)
        }
    }

    @Test("a negated, composed or misnamed request teaches nothing, even after a verified toggle")
    @MainActor
    func contestedRequests() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let requests: [(String, TurnAdmission.Reason)] = [
                ("Non attivare Mute", .uncertainGoal),
                ("Attiva Mute, attiva Solo", .compoundGoal),
                ("Attiva Mute, Solo", .uncertainGoal),
                ("Attiva Mute oppure Solo", .uncertainGoal),
                ("Attiva Unmute", .controlNotInGoal),
            ]
            for (request, reason) in requests {
                window.set("Mute", .off)
                let (_, end) = try await process.turn(request) { try await Self.setToggle($0, $1, "on") }
                guard case .act(_, .foundActed, _)? = end.report.attempts.last else {
                    Issue.record("'\(request)': the toggle was not verified"); continue
                }
                #expect(end.report.decision.reason == reason, "'\(request)'")
            }
            #expect(try await process.experiences().isEmpty)
        }
    }

    @Test("a control that moved while its state was read again is clicked where it is now")
    @MainActor
    func movedDuringReread() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            window.perceptionsWithoutState = 1
            window.shiftFromSecondPerception = 0.5
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, end) = try await process.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            guard case .act(_, .foundActed, .toggle(let proof)?)? = end.report.attempts.last else {
                Issue.record("the moved control was not set: \(end.report.attempts)"); return
            }
            #expect(proof.stateBefore == .read(.off, .sameElement))
            #expect(window.state(of: "Mute") == .on && window.clicks == 1)
            #expect(end.report.decision.reason == .admittedSingleToggle)
        }
    }

    @Test("a toggle found elsewhere after the click may be a homonym: nothing is proven or learned")
    @MainActor
    func toggleElsewhereAfterTheClick() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            window.shiftFromSecondPerception = 0.4
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, end) = try await process.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            guard case .act(_, let kind, .toggle(let proof)?)? = end.report.attempts.last else {
                Issue.record("no toggle evidence: \(end.report.attempts)"); return
            }
            #expect(kind == .actedUnverified)
            #expect(proof.stateAfter == .unreadable(.notAtPlace))
            #expect(proof.change == .unverified)
            #expect(end.report.decision.reason == .notVerified)
            guard case .keepAttempt(_, .uncertain(.toggleStateUnreadable(.notAtPlace))) = end.report.decision.action
            else { Issue.record("not kept as uncertain history: \(end.report.decision)"); return }
            #expect(try await process.experiences().isEmpty)
            #expect(window.clicks == 1)
        }
    }

    @Test("a homonym that grazes the clicked toggle's place after the click proves nothing, in the wanted state too")
    @MainActor
    func grazingHomonymAfterTheClick() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            // The Mute clicked ignores the click and is lost to perception; the next strip's Mute is on.
            let window = mixer(.off)
            window.clickFlips = false
            window.homonymBesideAfterClick = (.on, 0.01)
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, end) = try await process.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            guard case .act(_, let kind, .toggle(let proof)?)? = end.report.attempts.last else {
                Issue.record("no toggle evidence: \(end.report.attempts)"); return
            }
            #expect(kind == .actedUnverified)
            #expect(proof.stateAfter == .unreadable(.notAtPlace))
            #expect(proof.change == .unverified)
            #expect(outcome(end) == .uncertain(.toggleStateUnreadable(.notAtPlace)))
            #expect(end.report.decision.reason == .notVerified)
            guard case .keepAttempt(_, .uncertain(.toggleStateUnreadable(.notAtPlace))) = end.report.decision.action
            else { Issue.record("not kept as uncertain history: \(end.report.decision)"); return }
            #expect(try await process.experiences().isEmpty)
            #expect(window.state(of: "Mute") == .off && window.clicks == 1)
        }
    }

    @Test("the toggle clicked, a little moved as it repaints, is still read, proven and learned")
    @MainActor
    func nudgedAfterTheClick() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            window.shiftFromSecondPerception = 0.02
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, end) = try await process.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            guard case .act(_, .foundActed, .toggle(let proof)?)? = end.report.attempts.last else {
                Issue.record("the nudged control was not read: \(end.report.attempts)"); return
            }
            #expect(proof.stateAfter == .read(.on, .sameElement))
            #expect(end.report.decision.reason == .admittedSingleToggle)
            #expect(try await process.experiences().map(\.step) == [.setToggle(control: "Mute", section: nil, state: .on)])
        }
    }

    @Test("a scene of another window after the click proves nothing")
    @MainActor
    func otherWindowAfterClick() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let window = mixer(.off)
            window.titleAfterClick = "Synthetic Export"
            let process = try MecumProcess(knowledge: knowledge, window: window)
            let (_, end) = try await process.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            #expect(window.state(of: "Mute") == .on)
            #expect(outcome(end) == .uncertain(.toggleStateUnreadable(.otherWindow)))
            #expect(try await process.experiences().isEmpty)
        }
    }

    // MARK: Legacy selections

    @Test("a version 1 store with a select is migrated, still recalls it, and learns a toggle beside it")
    @MainActor
    func legacySelectBesideToggle() async throws {
        try await MecumProcess.withKnowledge { knowledge in
            let file = SQLiteLivingMemoryStore.file(inKnowledgeDirectory: knowledge)
            let request = "Seleziona Output Busses nel filtro"
            do {
                let version1 = SQLiteLivingMemorySchema(migrations: [SQLiteLivingMemorySchema.current.migrations[0]])
                let legacy = try SQLiteLivingMemoryStore(file: file, access: .readWrite,
                                                         makeID: { ExperienceID("legacy-select") }, schema: version1)
                let proof = DropdownEvidence(bundleID: bundle, windowTitle: "Synthetic I/O Setup", control: "All Busses",
                                             controlRole: "AXPopUpButton", section: nil, valueBefore: "All Busses",
                                             requestedItem: "Output Busses", readback: .window("Output Busses"),
                                             menuClosedByChoice: true)
                let setup = try #require(WindowContext(bundleID: bundle, windowTitle: "Synthetic I/O Setup"))
                let draft = try #require(ExperienceDraft(phrase: request, step: ExperienceStep(proof), context: setup))
                _ = try await legacy.record(ExperienceEvent(id: "turn-legacy", subject: .step(draft),
                                                            outcome: .verified(.dropdown(proof)), at: Date()))
            }
            let unmigrated = await LivingMemoryReport.lines(bundleID: bundle, knowledgeDirectory: knowledge)
                .joined(separator: "\n")
            #expect(unmigrated.contains("step: select 'Output Busses' in the control that read 'All Busses'"),
                    "mecum memory reads a version 1 store without migrating it")
            #expect(try SQLiteLivingMemoryStore(file: file, access: .readOnly).file == file)

            let process = try MecumProcess(knowledge: knowledge, window: mixer(.off))
            let select = try await process.cycle.begin(request, sessionIsOpen: false)
            #expect(select.memory?.briefing?.remembered?.tool == "select")
            #expect(select.memory?.briefing?.remembered?.item == "Output Busses")
            _ = await process.cycle.end(.completed)
            let (_, toggle) = try await process.turn("Attiva Mute") { try await Self.setToggle($0, $1, "on") }
            #expect(toggle.report.decision.reason == .admittedSingleToggle)
            #expect(try await process.experiences().map(\.step.tool) == [.select, .setToggle])

            let inspection = await LivingMemoryReport.lines(bundleID: bundle, knowledgeDirectory: knowledge)
                .joined(separator: "\n")
            #expect(inspection.contains("step: select 'Output Busses' in the control that read 'All Busses'"))
            #expect(inspection.contains("step: set_toggle 'Mute' to on"))
            #expect(inspection.contains("'off' read on the resolved control before, click sent, 'on' read on the "
                                        + "same element after, wanted 'on', window \"Synthetic Mixer\""))
        }
    }
}
