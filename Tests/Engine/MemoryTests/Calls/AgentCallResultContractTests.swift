//
//  AgentCallResultContractTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import EngineCore
@testable import Memory
import PerceptionCore
import Testing

/// The S3-d correction's contracts on their own: an observed effect as typed parts that keep every
/// label, the structured results of the listing and scene tools, the duration beside the calendar,
/// and the origin an observation keeps to the call it was taken for.
@Suite("Typed effects, structured results, durations and origins: the contracts")
struct AgentCallResultContractTests {

    static let effects: [SceneEffect] = [
        .windowTitleChanged(title: "Untitled 2 — Edited"),
        .stateFlip(from: .off, to: .on),
        .menuOpened(labels: ["Desktop", "Mobile", "Web"]),
        .elementsAppeared(labels: ["Queue", "", "A|B"]),
        .elementsDisappeared(labels: []),
    ]

    @Test("the five effects become typed parts and are rebuilt exactly, labels in order, an empty label kept")
    func effectsRoundTrip() throws {
        for effect in Self.effects {
            let observed = ObservedEffect(effect)
            #expect(observed.kind == effect.family)
            #expect(observed.sceneEffect == effect, Comment(rawValue: effect.encoded))
            let stored = try ObservedEffect(kind: observed.kind, title: observed.title, stateBefore: observed.stateBefore?.rawValue,
                                            stateAfter: observed.stateAfter?.rawValue, labels: observed.labels)
            #expect(stored.isExactly(observed), Comment(rawValue: effect.encoded))
            #expect(stored.sceneEffect == effect)
        }
        #expect(ObservedEffect(.elementsAppeared(labels: ["Queue", "", "A|B"])).labels == ["Queue", "", "A|B"])
    }

    @Test("two menus whose labels differ only in where a separator falls are two effects, in the parts and in the comparison")
    func separatorsAreContent() {
        let one = ObservedEffect(.menuOpened(labels: ["A|B", "C"]))
        let two = ObservedEffect(.menuOpened(labels: ["A", "B|C"]))
        #expect(one.labels == ["A|B", "C"] && two.labels == ["A", "B|C"])
        #expect(!one.isExactly(two))
        #expect(one.sceneEffect != two.sceneEffect)
        // The engine's own text, kept for the brain, cannot tell them apart: the store never uses it.
        #expect(one.sceneEffect.encoded == two.sceneEffect.encoded)
        let bytes = ObservedEffect(.menuOpened(labels: ["e\u{301}"])), composed = ObservedEffect(.menuOpened(labels: ["é"]))
        #expect(!bytes.isExactly(composed), "labels are compared as bytes")
    }

    @Test("a stored effect whose parts do not fit its family is refused on the way out")
    func malformedEffects() {
        func refused(_ kind: String, title: String? = nil, before: String? = nil, after: String? = nil, labels: [String] = []) {
            #expect(throws: AgentCallError.self) {
                try ObservedEffect(kind: kind, title: title, stateBefore: before, stateAfter: after, labels: labels)
            }
        }
        refused("rowsMoved")
        refused("windowTitleChanged")
        refused("windowTitleChanged", title: "x", labels: ["y"])
        refused("stateFlip", before: "off")
        refused("stateFlip", before: "off", after: "sideways")
        refused("stateFlip", title: "x", before: "off", after: "on")
        refused("menuOpened", title: "x", labels: ["a"])
        refused("elementsAppeared", before: "off", after: "on")
    }

    @Test("a progress carries the duration only after a start and never below zero, and the result each tool represents")
    func durationsAndStructuredResults() throws {
        let status = AgentCallResult.status(StatusResult(sessionID: nil, screenRecording: true, accessibility: false, postEvent: true))
        let windows = AgentCallResult.listing(ListingResult(kind: .windows, applications: [
            ListedApplication(name: "Mail", bundleID: "com.apple.mail", pid: 404, windows: [ListedWindow(number: 7, title: nil)])
        ]))
        let apps = AgentCallResult.listing(ListingResult(kind: .apps, applications: [
            ListedApplication(name: "Pro Tools", bundleID: "com.avid.ProTools", version: "26.4", isRunning: false, location: "~/Applications")
        ], hiddenCount: 3))
        let observation = AgentCallResult.observation(ObservationResult(
            sessionID: "S", sessionRevision: 2, observedAtMS: 1_700_000_000_000, sample: CaptureSampleKey(eventID: "e", phase: .current)
        ))
        try AgentCallProgress(.completed, result: status, endedAtMS: 5, durationMS: 0).validate(for: .status)
        try AgentCallProgress(.completed, result: windows, endedAtMS: 5, durationMS: 12).validate(for: .windows)
        try AgentCallProgress(.completed, result: apps, endedAtMS: 5).validate(for: .apps)
        try AgentCallProgress(.completed, result: observation, endedAtMS: 5).validate(for: .observe)
        try AgentCallProgress(.completed, result: observation, endedAtMS: 5).validate(for: .openSession)
        try AgentCallProgress(.completed, endedAtMS: 5).validate(for: .windows)
        try AgentCallProgress(.cancelled, endedAtMS: 5, durationMS: 3).validate(for: .act)
        try AgentCallProgress(.cancelled, endedAtMS: 5).validate(for: .act)
        func refused(_ progress: AgentCallProgress, _ tool: AgentTool, _ invalidity: AgentCallError.Invalidity) {
            #expect(throws: AgentCallError.invalidProgress(invalidity)) { try progress.validate(for: tool) }
        }
        refused(AgentCallProgress(.skipped, endedAtMS: 5, durationMS: 1), .act, .durationForbidden)
        refused(AgentCallProgress(.started, startedAtMS: 1, durationMS: 1), .act, .durationForbidden)
        refused(AgentCallProgress(.completed, result: status, endedAtMS: 5, durationMS: -1), .status, .durationNegative)
        refused(AgentCallProgress(.completed, result: windows, endedAtMS: 5), .apps, .resultMismatch)
        refused(AgentCallProgress(.completed, result: status, endedAtMS: 5), .windows, .resultMismatch)
        refused(AgentCallProgress(.completed, result: observation, endedAtMS: 5), .status, .resultMismatch)
        refused(AgentCallProgress(.completed, result: status, endedAtMS: 5), .act, .resultMismatch)
        let badWindows = AgentCallResult.listing(ListingResult(kind: .windows, applications: [
            ListedApplication(name: "Mail", bundleID: "com.apple.mail", isRunning: true)
        ]))
        refused(AgentCallProgress(.completed, result: badWindows, endedAtMS: 5), .windows, .listingShape("application 0 has no pid"))
        let badApps = AgentCallResult.listing(ListingResult(kind: .apps, applications: [
            ListedApplication(name: "X", bundleID: "x", pid: 1, isRunning: true)
        ]))
        refused(AgentCallProgress(.completed, result: badApps, endedAtMS: 5), .apps, .listingShape("application 0 carries windows fields"))
        let badObservation = AgentCallResult.observation(ObservationResult(
            sessionID: "S", sessionRevision: 1, observedAtMS: 1, sample: CaptureSampleKey(eventID: "e", phase: .after)
        ))
        refused(AgentCallProgress(.completed, result: badObservation, endedAtMS: 5), .observe, .observationShape("sample is not current"))
        // Exact comparison, byte for byte, order kept.
        #expect(windows.isExactly(windows) && !windows.isExactly(apps))
        let reordered = AgentCallResult.listing(ListingResult(kind: .windows, applications: [
            ListedApplication(name: "Mail", bundleID: "com.apple.mail", pid: 404, windows: [ListedWindow(number: 7, title: "")])
        ]))
        #expect(!windows.isExactly(reordered), "a NULL title and an empty title are two listings")
        #expect(AgentCallProgress(.completed, result: status, endedAtMS: 5, durationMS: 1)
            .isExactly(AgentCallProgress(.completed, result: status, endedAtMS: 5, durationMS: 1)))
        #expect(!AgentCallProgress(.completed, result: status, endedAtMS: 5, durationMS: 1)
            .isExactly(AgentCallProgress(.completed, result: status, endedAtMS: 5, durationMS: 2)))
    }

    @Test("an observation keeps the call it was taken for as its origin, which no action and no event may name as itself")
    func origins() throws {
        let call = MemoryEventRecord(eventID: "open-1", source: .app, streamID: "w", traceID: "t", kind: .action, occurredAtMS: 1)
        try call.validate()
        let observation = MemoryEventRecord(eventID: "obs-1", source: .app, streamID: "w", traceID: "t", sessionID: "s",
                                            kind: .observation, occurredAtMS: 2, originEventID: "open-1")
        try observation.validate()
        #expect(observation.immutableContent.originEventID == "open-1")
        var other = observation
        other.originEventID = "open-2"
        #expect(!observation.hasSameImmutableContent(as: other), "the origin is part of the event's identity")
        #expect(observation.contentDigest != other.contentDigest)
        let onAction = MemoryEventRecord(eventID: "a", source: .app, streamID: "w", kind: .action, occurredAtMS: 1, originEventID: "open-1")
        #expect(throws: ObservationContractError.invalidRecord(.originOnNonObservation)) { try onAction.validate() }
        let onSelf = MemoryEventRecord(eventID: "o", source: .app, streamID: "w", kind: .observation, occurredAtMS: 1, originEventID: "o")
        #expect(throws: ObservationContractError.invalidRecord(.originIsSelf)) { try onSelf.validate() }
        #expect(throws: ObservationContractError.invalidRecord(.originOnNonObservation)) {
            try AgentCallRecord(event: onAction, request: .openSession(app: "Calculator", window: nil))
        }
    }
}
