//
//  MemoryWiringTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 07/10/2026.
//

import AutomationMCP
import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import LocalMCP
import Memory
import PerceptionCore
@testable import SQLiteMemory
import Synchronization
import Testing

/// W is the small world these tests run in: a fresh Knowledge directory, a service of its own, and a
/// window of one application with a few buttons.
enum W {

    static let bundle = "com.example.Editor"

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-wiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func service(_ configuration: MemoryService.Configuration = .init()) throws -> MemoryService {
        MemoryService(directory: try directory(), configuration: configuration)
    }

    static func brain(_ service: MemoryService) -> BrainMemory {
        BrainMemory(brains: service, applications: service, clock: { service.clock.brainNow() })
    }

    static func recorder(_ service: MemoryService, trace: String = "trace-1", session: String? = "s1") -> CallRecorder {
        CallRecorder(memory: service, brain: brain(service),
                     context: ActionContext(source: .app, streamID: "worker-1", traceID: trace, sessionID: session))
    }

    static func button(_ label: String, x: Double) -> SceneElement {
        SceneElement(id: "control|\(label.lowercased())", kind: .control, label: label,
                     bounds: NormalizedRect(x: x, y: 0.1, width: 0.08, height: 0.04), role: "AXButton",
                     labelOrigin: .title)
    }

    static func window(_ elements: [SceneElement], title: String = "Document") -> PerceivedWindow {
        PerceivedWindow(
            scene  : SceneSnapshot(bundleID: bundle, appName: "Editor", windowTitle: title,
                                   viewportPixelSize: ViewportPixelSize(width: 1600, height: 1200), elements: elements),
            frame  : CGRect(x: 0, y: 0, width: 800, height: 600),
            capture: CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true,
                                    windowRole: "AXWindow", nodesVisited: elements.count + 1,
                                    elementsEmitted: elements.count),
            surface: .window
        )
    }

    static let open   = button("Open", x: 0.1)
    static let format = button("Format", x: 0.3)
    static let save   = button("Save", x: 0.5)
}

@Suite("The living memory wired to the tools: the queue, the recorder, the calls and what an action waits for")
struct MemoryWiringTests {

    // MARK: The queue

    @Test("a write is queued and the caller goes on; writes run one after another in the order they were offered")
    func queueOrder() async throws {
        let service = try W.service()
        let order = Mutex<[Int]>([])
        for index in 0..<50 {
            await service.enqueue("write \(index)") { _ in order.withLock { $0.append(index) } }
        }
        #expect(await service.flush(within: .seconds(10)))
        #expect(order.withLock { $0 } == Array(0..<50))
        let status = await service.status()
        #expect(status.written == 50 && status.failed == 0 && status.dropped == 0 && status.pending == 0)
        #expect(status.state == .open)
        await service.close()
    }

    @Test("a queue at its limit drops what arrives and counts it, never holding the producer")
    func fullQueueDrops() async throws {
        let service = try W.service(MemoryService.Configuration(queueLimit: 2))
        await service.enqueue("slow") { _ in try await Task.sleep(for: .milliseconds(300)) }
        try await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        for index in 0..<5 { await service.enqueue("next \(index)") { _ in } }
        #expect(started.duration(to: .now) < .milliseconds(50), "offering a write never waits for the archive")
        let status = await service.status()
        #expect(status.pending == 2 && status.dropped == 3)
        #expect(await service.flush(within: .seconds(5)))
        #expect(await service.status().written == 3)
        await service.close()
    }

    @Test("an archive this build refuses degrades the service: the file is left as found, writes are counted gaps")
    func refusedArchiveDegrades() async throws {
        let service = try W.service()
        let raw = try SQLiteConnection(path: service.url.path)
        try raw.execute("CREATE TABLE somebody_elses (x INTEGER)")
        raw.close()
        let before = try Data(contentsOf: service.url)
        await service.enqueue("a sample") { _ in }
        #expect(await service.flush(within: .seconds(5)))
        let status = await service.status()
        #expect(status.failed == 1 && status.written == 0)
        guard case .degraded(let reason) = status.state else { Issue.record("not degraded: \(status.state)"); return }
        #expect(reason.contains("unknownTables"))
        #expect(try Data(contentsOf: service.url) == before)
        _ = try? await service.brain(of: W.bundle)
        #expect(try Data(contentsOf: service.url) == before, "a read while degraded changes nothing")
        await service.close()
    }

    // MARK: Copies and recovery

    private func files(_ service: MemoryService, _ marker: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: service.directory.path).filter { $0.contains(marker) }.sorted()
    }

    @Test("opening takes a verified copy of the archive once an interval, and keeps the newest copies only")
    func dailyCopy() async throws {
        let service = try W.service()
        _ = await W.recorder(service, session: nil).observe(W.window([W.open, W.save]))
        #expect(await service.flush(within: .seconds(10)))
        for _ in 0..<200 where try files(service, ".backup-").isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try files(service, ".backup-").count == 1)
        #expect(await service.status().lastBackup != nil)
        await service.close()
        let again = MemoryService(directory: service.directory)
        _ = try await again.ready()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try files(again, ".backup-").count == 1, "a copy younger than the interval is enough")
        await again.close()
    }

    @Test("a corrupt archive is moved aside with its date, never deleted, and the newest copy takes its place")
    func corruptRestoredFromCopy() async throws {
        let service = try W.service()
        _ = await W.recorder(service, session: nil).observe(W.window([W.open, W.save]))
        #expect(await service.flush(within: .seconds(10)))
        await service.close()
        // A copy is the archive as it was opened, like the JSON store's copy before the day's first save:
        // the next opening, once the interval has passed, keeps what the first one learned.
        let next = MemoryService(directory: service.directory, configuration: .init(backupInterval: .zero))
        _ = try await next.ready()
        for _ in 0..<200 where try files(next, ".backup-").count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        await next.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: service.url.path + suffix) }
        try Data(repeating: 0x5A, count: 8192).write(to: service.url)

        let reopened = MemoryService(directory: service.directory)
        do {
            let brain = try await reopened.brain(of: W.bundle)
            #expect(brain?.objects.count == 2, "the copy's Brain is back")
        } catch { Issue.record("reopen: \(error) \(await reopened.status())") }
        let status = await reopened.status()
        #expect(status.state == .open)
        #expect(status.lastRecovery?.contains("restored") == true, "\(status.lastRecovery ?? "")")
        let aside = try files(reopened, ".corrupt-")
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: reopened.directory.appendingPathComponent(aside[0])) == Data(repeating: 0x5A, count: 8192))
        await reopened.close()
    }

    @Test("a corrupt archive with no copy is moved aside and the memory starts empty, saying so")
    func corruptWithoutCopyStartsEmpty() async throws {
        let directory = try W.directory()
        try Data(repeating: 0x5A, count: 8192).write(to: directory.appendingPathComponent("memory.sqlite"))
        let service = MemoryService(directory: directory)
        #expect(try await service.brain(of: W.bundle) == nil)
        let status = await service.status()
        #expect(status.state == .open && status.lastRecovery?.contains("started empty") == true)
        #expect(try files(service, ".corrupt-").count == 1)
        await service.close()
    }

    // MARK: The recorder

    @Test("a call through its recorder is planned, started, sampled, taught to the Brain and completed with its result and effect")
    func actionCall() async throws {
        let service  = try W.service()
        let recorder = W.recorder(service)
        let opened   = SceneEffect.menuOpened(labels: ["Bold", "Italic"])
        await recorder.begin(.act(target: "Format", verb: .click, value: nil, section: nil), app: AppContextIdentity(bundleID: W.bundle))
        await recorder.record(ActionRecord(
            bundleID: W.bundle, element: W.format, verb: .click, effect: opened, windowTitleAfter: "Document",
            before: W.window([W.open, W.format, W.save]),
            after : W.window([W.open, W.format, W.save, W.button("Bold", x: 0.3), W.button("Italic", x: 0.4)])
        ))
        await recorder.end(.completed, result: .outcome(.foundActed, message: "clicked 'Format'"), tool: .act)
        #expect(await service.flush(within: .seconds(10)))
        #expect(await service.status().failed == 0)

        let call = try #require(try await service.call(recorder.eventID))
        #expect(call.progress.status == .completed)
        #expect(call.event.traceID == "trace-1" && call.event.source == .app && call.event.app?.bundleID == W.bundle)
        if case .outcome(let kind, let message)? = call.progress.result {
            #expect(kind == .foundActed && message == "clicked 'Format'")
        } else { Issue.record("no outcome") }
        #expect(call.progress.observedEffect?.sceneEffect == opened)
        #expect(call.durationMS != nil)
        #expect(try await service.sample(CaptureSampleKey(eventID: recorder.eventID, phase: .before)) != nil)
        #expect(try await service.sample(CaptureSampleKey(eventID: recorder.eventID, phase: .after)) != nil)

        let brain = try #require(try await service.brain(of: W.bundle))
        #expect(brain.transitions.contains { $0.effect == opened.encoded }, "the Brain learned the menu the click opened")
        let expected = await W.brain(service).expectedEffect(of: .click, on: W.format, in: W.bundle)
        #expect(expected == opened, "the engine's next click on Format expects the menu, read back from SQLite")
        await service.close()
    }

    @Test("an observation of open_session belongs to an observation event of the application, whose origin is the call")
    func openSessionObservation() async throws {
        let service  = try W.service()
        let recorder = W.recorder(service)
        await recorder.begin(.openSession(app: "Editor", window: nil), app: nil)
        let scene = await recorder.observe(W.window([W.open, W.format, W.save]))
        #expect(scene.elements.count == 3)
        await recorder.end(.completed, result: nil, tool: .openSession)
        #expect(await service.flush(within: .seconds(10)))
        #expect(await service.status().failed == 0)

        let sample = try #require(await recorder.lastObservation)
        #expect(sample.eventID != recorder.eventID)
        let event = try #require(try await service.event(sample.eventID))
        #expect(event.kind == .observation && event.app?.bundleID == W.bundle && event.originEventID == recorder.eventID)
        #expect(try await service.brain(of: W.bundle)?.objects.count == 3, "the scene was ingested into the Brain")
        let call = try #require(try await service.call(recorder.eventID))
        #expect(call.progress.status == .completed && call.event.app == nil)
        await service.close()
    }

    @Test("a call made without the tools still teaches the Brain, under an event of its own")
    func callWithoutTools() async throws {
        let service  = try W.service()
        let recorder = CallRecorder(memory: service, brain: W.brain(service),
                                    context: ActionContext(source: .cli, streamID: "mecum-1", traceID: "cli-trace"))
        _ = await recorder.observe(W.window([W.open, W.format]))
        #expect(await service.flush(within: .seconds(10)))
        #expect(await service.status().failed == 0)
        let event = try #require(try await service.event(recorder.eventID))
        #expect(event.source == .cli && event.app?.bundleID == W.bundle)
        #expect(try await service.brain(of: W.bundle)?.objects.count == 2)
        await service.close()
    }

    @Test("a batch records its steps planned with it; a step that ran ends with its outcome, one that never ran is skipped")
    func batchSteps() async throws {
        let service = try W.service()
        let parent  = W.recorder(service)
        let first   = CallRecorder(memory: service, brain: W.brain(service), context: parent.context.child(0))
        let second  = CallRecorder(memory: service, brain: W.brain(service), context: parent.context.child(1))
        let app     = AppContextIdentity(bundleID: W.bundle)
        await parent.begin(batch: [
            (first, .act(target: "Missing", verb: .click, value: nil, section: nil)),
            (second, .insertText(text: "hello", expectedValue: nil)),
        ], app: app)
        await first.startStep()
        await first.end(.completed, result: .outcome(.honestMiss, message: "no Missing here"), tool: .act)
        await second.skip()
        await parent.end(.completed, result: .batch(stopped: true, attempted: 1, verified: 0), tool: .batch)
        #expect(await service.flush(within: .seconds(10)))
        let written = await service.status()
        #expect(written.failed == 0, "\(written.lastFailure ?? "")")
        let steps = try await service.ready().calls.steps(ofBatch: parent.eventID)
        #expect(steps.map(\.progress.status) == [.completed, .skipped])
        #expect(steps.map(\.request.tool) == [.act, .insertText])
        let batch = try #require(try await service.call(parent.eventID))
        if case .batch(let stopped, let attempted, let verified)? = batch.progress.result {
            #expect(stopped && attempted == 1 && verified == 0)
        } else { Issue.record("no batch summary") }
        await service.close()
    }

    @Test("a Brain read is kept while the archive is unchanged and read again once a write changes it")
    func brainCache() async throws {
        let service  = try W.service()
        let recorder = W.recorder(service, session: nil)
        _ = await recorder.observe(W.window([W.open]))
        #expect(await service.flush(within: .seconds(10)))
        #expect(try await service.brain(of: W.bundle)?.objects.count == 1)
        #expect(try await service.brain(of: W.bundle)?.objects.count == 1)
        let later = W.recorder(service, session: nil)
        _ = await later.observe(W.window([W.open, W.save]))
        #expect(await service.flush(within: .seconds(10)))
        #expect(try await service.brain(of: W.bundle)?.objects.count == 2, "the cache moved with the archive")
        await service.close()
    }

    // MARK: The tools

    @Test("the tools record every call they answer with its typed result, under the producer and its trace")
    @MainActor
    func toolsRecordCalls() async throws {
        let directory = try W.directory()
        let session   = RecordedSession(directory: directory)
        let tools     = AutomationTools(session: session)
        tools.producer = CallProducer(source: .mcp, streamID: "mcp-profile", traceID: "message-7")
        _ = try await tools.call("status", .object([:]))
        _ = try await tools.call("act", .object(["session": .string(session.id!.uuidString), "target": .string("Save")]))
        _ = try? await tools.call("act", .object(["session": .string("stale"), "target": .string("Save")]))
        let service = MemoryService.shared(for: directory)
        #expect(await service.flush(within: .seconds(10)))
        let written = await service.status()
        #expect(written.failed == 0, "\(written.lastFailure ?? "")")
        let calls = try await service.calls(inTrace: "message-7")
        #expect(calls.map(\.request.tool) == [.status, .act, .act])
        #expect(calls.allSatisfy { $0.event.source == .mcp && $0.event.streamID == "mcp-profile" })
        if case .status? = calls[0].progress.result {} else { Issue.record("status result missing") }
        if case .outcome(let kind, _)? = calls[1].progress.result { #expect(kind == .foundActed) }
        else { Issue.record("act outcome missing") }
        #expect(calls[1].event.app?.bundleID == W.bundle)
        #expect(calls[2].progress.status == .failed, "a call the tool refused is recorded as failed")
        await service.close()
    }

    // MARK: What an action waits for

    @Test("an action does not wait for a busy archive: every write of a call is offered at once, and saved once the lock goes")
    func busyArchiveDoesNotHoldTheAction() async throws {
        let service = try W.service()
        _ = try await service.ready()
        let lock = try SQLiteConnection(path: service.url.path)
        try lock.execute("BEGIN IMMEDIATE")
        let started = ContinuousClock.now
        for index in 0..<10 {
            let recorder = W.recorder(service, trace: "busy")
            await recorder.begin(.act(target: "Save", verb: .click, value: nil, section: nil), app: AppContextIdentity(bundleID: W.bundle))
            await recorder.record(ActionRecord(bundleID: W.bundle, element: W.save, verb: .click, effect: nil,
                                               windowTitleAfter: nil, before: W.window([W.save]), after: W.window([W.save])))
            await recorder.end(.completed, result: .outcome(.actedUnverified, message: "clicked \(index)"), tool: .act)
        }
        let offered = started.duration(to: .now)
        print("MEMORY-LATENCY busy archive: 10 calls offered in \(offered)")
        #expect(offered < .milliseconds(50) * 10, "within the 50 ms per action agreed for the memory")
        #expect(await service.status().written == 0, "nothing could be written while the lock was held")
        try lock.execute("COMMIT")
        lock.close()
        #expect(await service.flush(within: .seconds(20)))
        #expect(try await service.calls(inTrace: "busy").count == 10)
        await service.close()
    }

    @Test("the memory adds little to an action when the archive is free: measured per call, written by the end")
    func freeArchiveOverhead() async throws {
        let service = try W.service()
        _ = try await service.ready()
        var offered: [Duration] = []
        for index in 0..<40 {
            let started  = ContinuousClock.now
            let recorder = W.recorder(service, trace: "free")
            await recorder.begin(.act(target: "Save", verb: .click, value: nil, section: nil), app: AppContextIdentity(bundleID: W.bundle))
            await recorder.record(ActionRecord(bundleID: W.bundle, element: W.save, verb: .click, effect: nil,
                                               windowTitleAfter: nil, before: W.window([W.save]), after: W.window([W.save])))
            await recorder.end(.completed, result: .outcome(.actedUnverified, message: "clicked \(index)"), tool: .act)
            offered.append(started.duration(to: .now))
        }
        let sorted = offered.sorted()
        print("MEMORY-LATENCY free archive: p50 \(sorted[sorted.count / 2]), max \(sorted.last!) per call offered")
        #expect(sorted[sorted.count / 2] < .milliseconds(50))
        #expect(await service.flush(within: .seconds(20)))
        #expect(try await service.calls(inTrace: "free").count == 40)
        await service.close()
    }

    @Test("the expectation an action reads before acting costs one projection load after a change and a cache hit otherwise")
    func brainReadLatency() async throws {
        let service = try W.service()
        let brain   = W.brain(service)
        // A window of 300 controls in rows, as a dense editor shows.
        let elements = (0..<300).map { index in
            SceneElement(id: "control|c\(index)", kind: .control, label: "Control \(index)",
                         bounds: NormalizedRect(x: Double(index % 20) * 0.05, y: Double(index / 20) * 0.06,
                                                width: 0.04, height: 0.03), role: "AXButton", labelOrigin: .title)
        }
        _ = await W.recorder(service, session: nil).observe(W.window(elements))
        #expect(await service.flush(within: .seconds(20)))
        let target = elements[150]
        let missStart = ContinuousClock.now
        _ = await brain.expectedEffect(of: .click, on: target, in: W.bundle)
        let miss = missStart.duration(to: .now)
        var hits: [Duration] = []
        for _ in 0..<20 {
            let started = ContinuousClock.now
            _ = await brain.expectedEffect(of: .click, on: target, in: W.bundle)
            hits.append(started.duration(to: .now))
        }
        let hit = hits.sorted()[hits.count / 2]
        print("MEMORY-LATENCY brain read, 300 anchors: first after a change \(miss), cached p50 \(hit)")
        #expect(hit < .milliseconds(50) && miss < .milliseconds(500))
        await service.close()
    }
}

/// RecordedSession is a session with a memory and one application, which acts by answering at once.
@MainActor
final class RecordedSession: AutomationSessionOperating {

    let directory: URL
    let id: UUID? = UUID()

    init(directory: URL) { self.directory = directory }

    var memoryDirectory: URL? { directory }
    var memoryApplication: String? { W.bundle }

    func open(application: String, window: String?) async throws -> SceneSnapshot { throw AutomationFailure("not here") }
    func observe() async throws -> SceneSnapshot { throw AutomationFailure("not here") }
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome {
        ActOutcome(.foundActed, "clicked '\(target)'")
    }
    func select(control: String, item: String) async throws -> ActOutcome { ActOutcome(.foundActed, "selected") }
    func deliver(_ input: InputRequest.Input, section: String?) async throws -> ActOutcome { ActOutcome(.actedUnverified, "typed") }
    func close() async {}
}
