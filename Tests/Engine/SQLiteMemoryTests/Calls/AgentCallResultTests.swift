//
//  AgentCallResultTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Testing

/// The structured results of the listing and scene tools (S3-d correction): typed rows written with the
/// call's end and read back exactly after reopening, once per call, with their shape guarded both ways.
@Suite("Structured results of status, windows, apps, open_session and observe")
struct AgentCallResultTests {

    private typealias F = AgentCallFixtures

    private static let status = AgentCallResult.status(StatusResult(sessionID: F.session, screenRecording: true, accessibility: false, postEvent: true))
    private static let windows = AgentCallResult.listing(ListingResult(kind: .windows, applications: [
        ListedApplication(name: "Mail", bundleID: "com.apple.mail", pid: 404, windows: [
            ListedWindow(number: 77, title: "Inbox — 3"), ListedWindow(number: 78, title: nil), ListedWindow(number: 79, title: ""),
        ]),
        ListedApplication(name: "", bundleID: "com.example.nameless", pid: 500, windows: []),
    ]))
    private static let apps = AgentCallResult.listing(ListingResult(kind: .apps, applications: [
        ListedApplication(name: "Pro Tools", bundleID: "com.avid.ProTools", version: "26.4.1.179", isRunning: false),
        ListedApplication(name: "Pro Tools", bundleID: "com.example.ProTools", version: nil, isRunning: true, location: "~/Applications"),
    ], hiddenCount: 59))

    /// A completed call of `tool` with `result`, planned, started and concluded.
    private static func conclude(_ memory: F.Memory, _ id: String, _ request: AgentCallRequest, _ result: AgentCallResult?,
                                 session: String? = F.session, app: AppContextIdentity? = F.app) async throws {
        _ = try await memory.calls.record(try F.call(id, request, session: session, app: app))
        _ = try await memory.calls.advance([AgentCallTransition(id, .started(atMS: F.t0 + 1))])
        _ = try await memory.calls.advance([AgentCallTransition(id, AgentCallProgress(.completed, result: result, endedAtMS: F.t0 + 2, durationMS: 1))])
    }

    /// A real current sample for `eventID`: the window the scene was captured as.
    private static func sample(_ memory: F.Memory, eventID: String, revision: Int64) async throws -> CaptureSampleKey {
        let scene = SceneSnapshot(bundleID: F.app.bundleID, appName: "Fixture", windowTitle: "Chat",
                                  viewportPixelSize: ViewportPixelSize(width: 100, height: 100), elements: [
            SceneElement(id: "control|send", kind: .control, label: "Send",
                         bounds: NormalizedRect(x: 0.1, y: 0.1, width: 0.1, height: 0.05), role: "AXButton")
        ])
        let window = PerceivedWindow(scene: scene, frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                     capture: CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true), surface: .window)
        let key = CaptureSampleKey(eventID: eventID, phase: .current)
        _ = try await memory.captures.record(CaptureSample(key: key, of: window, sessionRevision: revision))
        return key
    }

    @Test("status, windows and apps keep typed rows in order, NULL apart from empty text, read back exactly after reopening")
    func listingsRoundTrip() async throws {
        let url = try temporaryDatabase()
        var memory = try await F.open(at: url)
        try await Self.conclude(memory, "s", .status, Self.status, session: nil, app: nil)
        try await Self.conclude(memory, "w", .windows(app: nil), Self.windows, session: nil, app: nil)
        try await Self.conclude(memory, "a", .apps(query: "pro"), Self.apps, session: nil, app: nil)
        try await Self.conclude(memory, "none", .windows(app: "Mail"), nil, session: nil, app: nil)
        await memory.store.close()
        memory = try await F.open(at: url)
        let status = try #require(try await memory.calls.call("s")?.progress.result)
        #expect(status.isExactly(Self.status))
        let windows = try #require(try await memory.calls.call("w")?.progress.result)
        #expect(windows.isExactly(Self.windows))
        if case .listing(let listing) = windows {
            #expect(listing.applications[0].windows.map(\.title) == ["Inbox — 3", nil, ""])
            #expect(listing.applications[1].name == "" && listing.applications[1].windows.isEmpty)
        } else { Issue.record("not a listing") }
        let apps = try #require(try await memory.calls.call("a")?.progress.result)
        #expect(apps.isExactly(Self.apps))
        if case .listing(let listing) = apps {
            #expect(listing.hiddenCount == 59 && listing.applications.map(\.location) == [nil, "~/Applications"])
        } else { Issue.record("not a listing") }
        #expect(try await memory.calls.call("none")?.progress.result == nil, "a listing the producer could not record stays an explicit gap")
        #expect(try await memory.calls.call("none")?.durationMS == 1)
        let traced = try await memory.calls.calls(inTrace: "trace-1", after: nil, limit: 10)
        #expect(traced.map(\.event.eventID) == ["s", "w", "a", "none"])
        #expect(try await memory.count("SELECT count(*) FROM memory_agent_action_applications") == 4)
        #expect(try await memory.count("SELECT count(*) FROM memory_agent_action_windows") == 3)
        await memory.store.close()
    }

    @Test("an observation result points to its real current sample under the call, or under the session's own observation with its origin")
    func observationsRoundTrip() async throws {
        let url = try temporaryDatabase()
        var memory = try await F.open(at: url)
        // observe: the sample is the call's own.
        _ = try await memory.calls.record(try F.call("o", .observe))
        _ = try await memory.calls.advance([AgentCallTransition("o", .started(atMS: F.t0 + 1))])
        let own = try await Self.sample(memory, eventID: "o", revision: 2)
        let observation = AgentCallResult.observation(ObservationResult(sessionID: F.session, sessionRevision: 2, observedAtMS: F.t0 + 2, sample: own))
        _ = try await memory.calls.advance([AgentCallTransition("o", AgentCallProgress(.completed, result: observation, endedAtMS: F.t0 + 2, durationMS: 1))])
        // open_session: the call named no session and no app when planned; the sample is under the session's own
        // observation, whose origin is the call.
        _ = try await memory.calls.record(try F.call("open", .openSession(app: "Fixture", window: nil), session: nil, app: nil))
        _ = try await memory.calls.advance([AgentCallTransition("open", .started(atMS: F.t0 + 3))])
        _ = try await memory.captures.record(MemoryEventRecord(
            eventID: "open.observation", source: .app, streamID: "worker-1", traceID: "trace-1", sessionID: F.session,
            kind: .observation, app: F.app, occurredAtMS: F.t0 + 4, originEventID: "open"))
        let first = try await Self.sample(memory, eventID: "open.observation", revision: 1)
        let opening = AgentCallResult.observation(ObservationResult(sessionID: F.session, sessionRevision: 1, observedAtMS: F.t0 + 4, sample: first))
        _ = try await memory.calls.advance([AgentCallTransition("open", AgentCallProgress(.completed, result: opening, endedAtMS: F.t0 + 4, durationMS: 2))])
        // A result pointing at a sample the store does not hold is refused, with the call left as it was.
        _ = try await memory.calls.record(try F.call("nowhere", .observe))
        _ = try await memory.calls.advance([AgentCallTransition("nowhere", .started(atMS: F.t0 + 5))])
        let missing = AgentCallResult.observation(ObservationResult(sessionID: F.session, sessionRevision: 3, observedAtMS: F.t0 + 6,
                                                                    sample: CaptureSampleKey(eventID: "nowhere", phase: .current)))
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("nowhere", AgentCallProgress(.completed, result: missing, endedAtMS: F.t0 + 6))]) }
                == .missingSample(eventID: "nowhere", sample: CaptureSampleKey(eventID: "nowhere", phase: .current)))
        #expect(try await memory.calls.call("nowhere")?.progress.status == .started)
        await memory.store.close()
        memory = try await F.open(at: url)
        let read = try #require(try await memory.calls.call("o")?.progress.result)
        #expect(read.isExactly(observation))
        let readOpening = try #require(try await memory.calls.call("open")?.progress.result)
        #expect(readOpening.isExactly(opening))
        if case .observation(let result) = readOpening {
            let event = try #require(try await memory.captures.event(result.sample.eventID))
            #expect(event.kind == .observation && event.originEventID == "open" && event.app == F.app)
            #expect(try await memory.captures.sample(result.sample)?.sessionRevision == 1)
        } else { Issue.record("not an observation") }
        // The same end offered again is a retry; another revision under it is a conflict.
        #expect(try await memory.calls.advance([AgentCallTransition("o", AgentCallProgress(.completed, result: observation, endedAtMS: F.t0 + 2, durationMS: 1))]) == .alreadyApplied)
        let other = AgentCallResult.observation(ObservationResult(sessionID: F.session, sessionRevision: 9, observedAtMS: F.t0 + 2, sample: own))
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("o", AgentCallProgress(.completed, result: other, endedAtMS: F.t0 + 2, durationMS: 1))]) }
                == .conflictingEnd(eventID: "o", stored: .completed, offered: .completed))
        await memory.store.close()
    }

    @Test("a result the tool does not represent, and result rows written by hand that break the shape, are refused")
    func refusals() async throws {
        let memory = try await F.open()
        _ = try await memory.calls.record(try F.call("s", .status, session: nil, app: nil))
        _ = try await memory.calls.advance([AgentCallTransition("s", .started(atMS: F.t0))])
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("s", AgentCallProgress(.completed, result: Self.windows, endedAtMS: F.t0 + 1))]) }
                == .invalidProgress(.resultMismatch))
        let badApps = AgentCallResult.listing(ListingResult(kind: .apps, applications: [ListedApplication(name: "X", bundleID: "x", pid: 1, isRunning: true)]))
        _ = try await memory.calls.record(try F.call("a", .apps(query: nil), session: nil, app: nil))
        _ = try await memory.calls.advance([AgentCallTransition("a", .started(atMS: F.t0))])
        #expect(await callError { _ = try await memory.calls.advance([AgentCallTransition("a", AgentCallProgress(.completed, result: badApps, endedAtMS: F.t0 + 1))]) }
                == .invalidProgress(.listingShape("application 0 carries windows fields")))
        // Rows planted by hand: a status call whose status row is missing, a listing with a gap in its positions.
        try await Self.conclude(memory, "planted", .status, Self.status, session: nil, app: nil)
        try await Self.conclude(memory, "gap", .windows(app: nil), Self.windows, session: nil, app: nil)
        try await memory.store.write { transaction in
            try transaction.execute("DELETE FROM memory_agent_action_status WHERE event_id = 'planted'", [])
            try transaction.execute("DELETE FROM memory_agent_action_windows WHERE event_id = 'gap' AND position = 0", [])
        }
        #expect(await callError { _ = try await memory.calls.call("planted") } == .malformedCall(eventID: "planted", malformation: .resultShape("status row")))
        #expect(await callError { _ = try await memory.calls.call("gap") } == .malformedCall(eventID: "gap", malformation: .resultShape("window positions of application 0")))
        #expect(try await memory.calls.record(try F.call("after", .observe)) == .committed, "the store goes on")
        await memory.store.close()
    }
}
