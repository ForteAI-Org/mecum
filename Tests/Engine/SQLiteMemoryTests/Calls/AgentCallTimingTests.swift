//
//  AgentCallTimingTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// The columns S3-d and its correction fill for a call: the calendar instant it started, kept through
/// its end; the monotonic duration beside the calendar, which may run backwards between the two
/// instants; and the effect the engine observed, stored as typed parts with its labels as rows.
@Suite("A call's start, duration and observed effect")
struct AgentCallTimingTests {

    private typealias F = AgentCallFixtures

    private let flip = ObservedEffect(SceneEffect.stateFlip(from: .off, to: .on))

    @Test("the start is written by the started move and kept by the end; the duration is the producer's, read back beside the calendar")
    func startAndDurationRoundTrip() async throws {
        let memory = try await F.open()
        _ = try await memory.calls.record(try F.call("t", .act(target: "Wi-Fi", verb: .setToggle, value: .on, section: nil)))
        #expect(try await memory.calls.call("t")?.startedAtMS == nil)
        #expect(try await memory.calls.advance([AgentCallTransition("t", .started(atMS: F.t0 + 10))]) == .committed)
        let started = try #require(try await memory.calls.call("t"))
        #expect(started.progress.status == .started && started.startedAtMS == F.t0 + 10 && started.durationMS == nil)
        #expect(started.progress.startedAtMS == nil, "the progress compares moves; the call carries the start")
        #expect(try await memory.calls.advance([AgentCallTransition("t", .started(atMS: F.t0 + 11))]) == .alreadyApplied,
                "a started call offered another start is a retry: the first instant stays")
        // The calendar went back between the start and the end; the duration is the monotonic measure.
        let concluded = AgentCallProgress(.completed, result: .outcome(.foundActed, message: "set 'Wi-Fi' → on"),
                                          endedAtMS: F.t0 + 4, durationMS: 15, observedEffect: flip)
        #expect(try await memory.calls.advance([AgentCallTransition("t", concluded)]) == .committed)
        let call = try #require(try await memory.calls.call("t"))
        #expect(call.startedAtMS == F.t0 + 10)
        #expect(call.progress.endedAtMS == F.t0 + 4, "the chronology is kept as the calendar said it")
        #expect(call.durationMS == 15)
        #expect(call.progress.observedEffect?.isExactly(flip) == true)
        #expect(call.progress.observedEffect?.sceneEffect == .stateFlip(from: .off, to: .on))
        #expect(try await memory.calls.advance([AgentCallTransition("t", concluded)]) == .alreadyApplied)
        let otherDuration = AgentCallProgress(.completed, result: .outcome(.foundActed, message: "set 'Wi-Fi' → on"),
                                              endedAtMS: F.t0 + 4, durationMS: 16, observedEffect: flip)
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("t", otherDuration)]) }
                == .conflictingEnd(eventID: "t", stored: .completed, offered: .completed))
        let otherEffect = AgentCallProgress(.completed, result: .outcome(.foundActed, message: "set 'Wi-Fi' → on"),
                                            endedAtMS: F.t0 + 4, durationMS: 15, observedEffect: ObservedEffect(.menuOpened(labels: ["x"])))
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("t", otherEffect)]) }
                == .conflictingEnd(eventID: "t", stored: .completed, offered: .completed))
        await memory.store.close()
    }

    @Test("the five effects and the supervision's two menus are read back exactly after reopening: labels as rows, in order, bytes kept")
    func effectsRoundTripThroughTheFile() async throws {
        let url = try temporaryDatabase()
        var memory = try await F.open(at: url)
        let effects: [(String, SceneEffect)] = [
            ("title", .windowTitleChanged(title: "Untitled 2 — Edited")),
            ("flip", .stateFlip(from: .mixed, to: .off)),
            ("menu", .menuOpened(labels: ["Desktop", "Mobile", "Web"])),
            ("appeared", .elementsAppeared(labels: ["Queue", "", "A|B", "e\u{301}"])),
            ("gone", .elementsDisappeared(labels: [])),
            ("one", .menuOpened(labels: ["A|B", "C"])),
            ("two", .menuOpened(labels: ["A", "B|C"])),
        ]
        for (id, effect) in effects {
            _ = try await memory.calls.record(try F.call(id, .act(target: "Menu", verb: .click, value: nil, section: nil)))
            _ = try await memory.calls.advance([AgentCallTransition(id, .started(atMS: F.t0))])
            _ = try await memory.calls.advance([AgentCallTransition(id, AgentCallProgress(
                .completed, result: .outcome(.foundActed, message: "observed"), endedAtMS: F.t0 + 1, durationMS: 1,
                observedEffect: ObservedEffect(effect)))])
        }
        await memory.store.close()
        memory = try await F.open(at: url)
        for (id, effect) in effects {
            let read = try #require(try await memory.calls.call(id)?.progress.observedEffect)
            #expect(read.sceneEffect == effect, Comment(rawValue: id))
            #expect(read.isExactly(ObservedEffect(effect)), Comment(rawValue: id))
        }
        let one = try #require(try await memory.calls.call("one")?.progress.observedEffect)
        let two = try #require(try await memory.calls.call("two")?.progress.observedEffect)
        #expect(!one.isExactly(two))
        #expect(one.labels == ["A|B", "C"] && two.labels == ["A", "B|C"])
        #expect(try await memory.count("SELECT count(*) FROM memory_agent_action_effect_labels") == 3 + 4 + 0 + 2 + 2)
        #expect(try await memory.count("SELECT count(*) FROM memory_agent_action_effect_labels WHERE label = ''") == 1)
        await memory.store.close()
    }

    @Test("a start on another state, a duration on a state not reached from started, an effect off a concluded action or input, and a producer that never reported a start")
    func whatTheContractRefuses() async throws {
        func refusal(_ progress: AgentCallProgress, _ tool: AgentTool) -> AgentCallError.Invalidity? {
            do { try progress.validate(for: tool); return nil }
            catch AgentCallError.invalidProgress(let invalidity) { return invalidity }
            catch { return nil }
        }
        #expect(refusal(AgentCallProgress(.completed, result: .outcome(.foundActed, message: "m"), startedAtMS: 5, endedAtMS: 9), .act)
                == .startForbidden)
        #expect(refusal(AgentCallProgress(.planned, startedAtMS: 5), .act) == .startForbidden)
        #expect(refusal(AgentCallProgress(.skipped, endedAtMS: 9, durationMS: 1), .act) == .durationForbidden)
        #expect(refusal(AgentCallProgress(.failed, result: .error(message: "boom"), endedAtMS: 9, observedEffect: flip), .act)
                == .effectForbidden)
        #expect(refusal(AgentCallProgress(.completed, endedAtMS: 9, observedEffect: flip), .observe) == .effectForbidden)
        #expect(refusal(AgentCallProgress(.completed, result: .outcome(.actedNoop, message: "m"), endedAtMS: 9, observedEffect: flip), .scroll)
                == nil)
        #expect(refusal(.started(atMS: 5), .status) == nil)
        let memory = try await F.open()
        _ = try await memory.calls.record(try F.call("plain", .observe))
        // A producer that reports no start and no duration: the row keeps NULL and the call has none.
        _ = try await memory.calls.advance([AgentCallTransition("plain", .started)])
        _ = try await memory.calls.advance([AgentCallTransition("plain", F.ended(.completed))])
        let call = try #require(try await memory.calls.call("plain"))
        #expect(call.startedAtMS == nil && call.durationMS == nil && call.progress.status == .completed)
        await memory.store.close()
    }

    @Test("stored effect rows the contract does not admit are refused by the reader with a typed error, and the store goes on")
    func malformedEffectRows() async throws {
        let memory = try await F.open()
        for id in ["gap", "scalar"] {
            _ = try await memory.calls.record(try F.call(id, .act(target: "Menu", verb: .click, value: nil, section: nil)))
            _ = try await memory.calls.advance([AgentCallTransition(id, .started(atMS: F.t0))])
        }
        _ = try await memory.calls.advance([AgentCallTransition("gap", AgentCallProgress(
            .completed, result: .outcome(.foundActed, message: "m"), endedAtMS: F.t0 + 1, observedEffect: ObservedEffect(.menuOpened(labels: ["a", "b"]))))])
        _ = try await memory.calls.advance([AgentCallTransition("scalar", AgentCallProgress(
            .completed, result: .outcome(.foundActed, message: "m"), endedAtMS: F.t0 + 1, observedEffect: flip))])
        try await memory.store.write { transaction in
            try transaction.execute("DELETE FROM memory_agent_action_effect_labels WHERE event_id = 'gap' AND position = 0", [])
            // The DDL guards the columns; the reader still refuses a flip whose state is not a state of this build.
            try transaction.execute("PRAGMA ignore_check_constraints = ON", [])
            try transaction.execute("UPDATE memory_agent_actions SET observed_state_after = 'sideways' WHERE event_id = 'scalar'", [])
            try transaction.execute("PRAGMA ignore_check_constraints = OFF", [])
        }
        #expect(await callError { _ = try await memory.calls.call("gap") }
                == .malformedCall(eventID: "gap", malformation: .positionsNotContiguous("effect labels")))
        #expect(await callError { _ = try await memory.calls.call("scalar") }
                == .malformedCall(eventID: "scalar", malformation: .resultShape("observed_effect: state sideways")))
        #expect(try await memory.calls.record(try F.call("after", .observe)) == .committed, "the store goes on")
        await memory.store.close()
    }

    @Test("a batch's steps carry their own starts and durations, and the summary reads as before")
    func stepsCarryTheirStarts() async throws {
        let memory = try await F.open()
        let (batch, steps) = try F.batch("b", Array(F.sevenSteps.prefix(2)))
        _ = try await memory.calls.record(batch: batch, steps: steps)
        _ = try await memory.calls.advance([AgentCallTransition("b", .started(atMS: F.t0 + 1)),
                                            AgentCallTransition("b.0", .started(atMS: F.t0 + 2))])
        _ = try await memory.calls.advance([AgentCallTransition("b.0", AgentCallProgress(
            .completed, result: .outcome(.actedNoop, message: "already on"), endedAtMS: F.t0 + 4, durationMS: 2))])
        _ = try await memory.calls.advance([AgentCallTransition("b.1", .started(atMS: F.t0 + 5))])
        _ = try await memory.calls.advance([AgentCallTransition("b.1", AgentCallProgress(
            .completed, result: .outcome(.foundActed, message: "selected"), endedAtMS: F.t0 + 9, durationMS: 4))])
        _ = try await memory.calls.advance([AgentCallTransition("b", AgentCallProgress(
            .completed, result: .batch(stopped: false, attempted: 2, verified: 2), endedAtMS: F.t0 + 10, durationMS: 9))])
        let read = try await memory.calls.steps(ofBatch: "b")
        #expect(read.map(\.startedAtMS) == [F.t0 + 2, F.t0 + 5])
        #expect(read.map(\.durationMS) == [2, 4])
        #expect(try await memory.calls.call("b")?.durationMS == 9)
        await memory.store.close()
    }
}
