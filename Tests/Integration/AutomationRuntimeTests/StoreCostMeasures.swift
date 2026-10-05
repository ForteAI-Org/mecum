//
//  StoreCostMeasures.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 04/10/2026.
//

import AutomationRuntime
import CoreGraphics
import EngineCore
import Foundation
import Memory
import PerceptionCore
import SQLite3
import SQLiteMemory
import Testing

/// Measures the living memory's cost on a synthetic corpus written through the producers the app and
/// the chat use (`MemoryService`, `BrainMemory`, `CallRecorder`) and the call records the tools write:
/// actions with before and after samples and a Brain record, observations with a current sample and a
/// Brain ingest, and batches of acts, alternated by a seeded generator over eight synthetic applications
/// whose windows have a declared number of elements. Then it reads as the readers do: pages of traces
/// and of a trace's entries and calls, the scenes and the Brain of each application, the catalogue.
///
/// Durations are monotonic and measured around each service call, so they are the store's cost with
/// its repositories, apart from any provider or session. Prints `COST` lines; asserts only the corpus's
/// own structure, never a threshold. Size and seed come from `MECUM_COST_EVENTS` (default 300, the
/// tier's quick pass) and `MECUM_COST_SEED`; `MECUM_COST_CONCURRENT=1` runs a `memory-probe` process
/// writing to the same file meanwhile; `MECUM_COST_KEEP=<directory>` keeps a verified snapshot of the
/// archive there for `EXPLAIN QUERY PLAN`.
@Suite("Measured: the store's cost on a synthetic corpus", .serialized)
struct StoreCostMeasures {

    private static let environment = ProcessInfo.processInfo.environment
    private static let targetEvents = environment["MECUM_COST_EVENTS"].flatMap(Int.init) ?? 300
    private static let seed = environment["MECUM_COST_SEED"].flatMap(UInt64.init) ?? 20_261_003
    private static let concurrent = environment["MECUM_COST_CONCURRENT"] == "1"
    private static let keep = environment["MECUM_COST_KEEP"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// The corpus's shape, declared: eight applications, three windows each of 8, 24 and 64 elements;
    /// 50 % acts, 30 % observations, 20 % batches of two to four acts; a trace every 40 calls.
    private static let applications = 8
    private static let windowSizes = [8, 24, 64]
    private static let callsPerTrace = 40
    private static let readRepetitions = 30

    /// SplitMix64: the same seed, the same corpus, on any machine.
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    /// Durations in microseconds, by what was timed.
    private struct Timings {
        var values: [String: [Int64]] = [:]

        mutating func add(_ name: String, _ duration: Duration) {
            values[name, default: []].append(duration.components.seconds * 1_000_000
                                            + duration.components.attoseconds / 1_000_000_000_000)
        }

        func line(_ name: String) -> String {
            let sorted = (values[name] ?? []).sorted()
            guard !sorted.isEmpty else { return "\(name) n=0" }
            func rank(_ percent: Int) -> Int64 { sorted[max(0, min(sorted.count - 1, (sorted.count * percent + 99) / 100 - 1))] }
            return "\(name) n=\(sorted.count) p50us=\(rank(50)) p95us=\(rank(95)) maxus=\(sorted.last ?? 0)"
        }
    }

    private static func bundle(_ index: Int) -> String { "test.cost.app\(index)" }

    private static func window(app: Int, window: Int, extra: Int = 0) -> PerceivedWindow {
        let size = windowSizes[window]
        let elements = (0..<(size + extra)).map { index in
            SceneElement(id: "control|control \(index)", kind: .control, label: "Control \(index)",
                         bounds: NormalizedRect(x: 0.02 + Double(index % 8) * 0.12, y: 0.05 + Double(index / 8) * 0.04,
                                                width: 0.1, height: 0.03),
                         role: "AXButton")
        }
        let scene = SceneSnapshot(bundleID: bundle(app), appName: "Cost \(app)", windowTitle: "Window \(window)",
                                  viewportPixelSize: ViewportPixelSize(width: 1200, height: 800), elements: elements)
        return PerceivedWindow(scene: scene, frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                               capture: CaptureQuality(walkCompleted: true, windowFound: true, isGrantAvailable: true,
                                                       windowRole: "AXWindow", nodesVisited: size * 2, elementsEmitted: size),
                               surface: .window)
    }

    private static func timed<T>(_ name: String, _ timings: inout Timings, _ body: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        let value = try await body()
        timings.add(name, ContinuousClock.now - start)
        return value
    }

    /// The other writer: real `memory-probe` processes on the same file, one after the other until
    /// `end`, each writing 500 events of 256 bytes in its own transactions (a new process each time,
    /// so its identifiers, made from its pid, never repeat).
    nonisolated private final class ConcurrentWriter: @unchecked Sendable {
        private let executable: URL
        private let path: String
        private let lock = NSLock()
        private var stopped = false
        private var lines: [String] = []
        private let done = DispatchSemaphore(value: 0)

        init?(path: String) {
            var directory = Bundle(for: ConcurrentWriter.self).bundleURL
            var found: URL?
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("memory-probe")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { found = candidate; break }
                directory = directory.deletingLastPathComponent()
            }
            guard let executable = found else { return nil }
            self.executable = executable
            self.path = path
            Thread.detachNewThread { [self] in loop() }
        }

        private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

        private func loop() {
            while !isStopped {
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = executable
                process.standardInput = input
                process.standardOutput = output
                guard (try? process.run()) != nil else { break }
                input.fileHandleForWriting.write(Data("open \(path)\nmeasure concurrent 500 256\nclose\nexit\n".utf8))
                try? input.fileHandleForWriting.close()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                let measured = text.split(separator: "\n").filter { $0.hasPrefix("measured") || $0.hasPrefix("error") }.map(String.init)
                lock.lock(); lines += measured; lock.unlock()
            }
            done.signal()
        }

        /// Stops after the process in flight and answers every process's own `measured` line.
        func end() -> [String] {
            lock.lock(); stopped = true; lock.unlock()
            done.wait()
            lock.lock(); defer { lock.unlock() }
            return lines
        }
    }

    @Test("a seeded corpus written through the producers, then read as the readers read it: timings, sizes, rows per event")
    func measure() async throws {
        let directory = Fixtures.directory()
        let memory = MemoryService(directory: directory)
        try await memory.open()
        let clock = memory.clock
        let brain = BrainMemory(brains: memory, applications: memory, clock: { clock.brainNow() })
        let writer = Self.concurrent ? ConcurrentWriter(path: memory.url.path) : nil
        if Self.concurrent, writer == nil { Issue.record("memory-probe is not built beside the tests; run swift build --product memory-probe") }

        var random = Generator(state: Self.seed)
        var timings = Timings()
        var events = 0, calls = 0, acts = 0, observations = 0, batches = 0, steps = 0
        var traces: [String] = []
        let started = ContinuousClock.now

        func context(_ index: Int) -> ActionContext {
            let trace = index / Self.callsPerTrace
            if traces.count <= trace { traces.append("cost-trace-\(trace)") }
            return ActionContext(eventID: "cost-\(Self.seed)-\(index)", source: .app, streamID: "cost-worker",
                                 traceID: "cost-trace-\(trace)", sessionID: "cost-session-\(trace)")
        }

        func act(_ context: ActionContext, app: Int, window: Int, timings: inout Timings) async throws -> ObservedEffect {
            let before = Self.window(app: app, window: window)
            let after  = Self.window(app: app, window: window, extra: 2)
            let effect = SceneEffect.elementsAppeared(labels: ["Control \(Self.windowSizes[window])", "Control \(Self.windowSizes[window] + 1)"])
            let recorder = CallRecorder(memory: memory, brain: brain, context: context, sessionRevision: 1, requestedAt: clock.brainNow())
            await Self.timed("recorder-act(5 commits)", &timings) {
                await recorder.record(ActionRecord(bundleID: Self.bundle(app), element: before.scene.elements[0], verb: .click,
                                                   effect: effect, windowTitleAfter: after.scene.windowTitle,
                                                   before: before, after: after, attempt: .delivered))
            }
            let notes = await recorder.report().notes
            #expect(notes.isEmpty, "\(notes)")
            return ObservedEffect(effect)
        }

        var index = 0
        while events < Self.targetEvents {
            let app = random.below(Self.applications), window = random.below(Self.windowSizes.count)
            let roll = random.below(100)
            let ctx = context(index)
            let identity = AppContextIdentity(bundleID: Self.bundle(app), version: "1.0")
            if roll < 50 {
                let record = try AgentCallRecord(event: ctx.event(app: identity, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS()),
                                                 request: .act(target: "Control 0", verb: .click, value: nil, section: nil))
                _ = try await Self.timed("plan(1 commit)", &timings) { try await memory.record(record) }
                _ = try await Self.timed("start(1 commit)", &timings) {
                    try await memory.advance([AgentCallTransition(ctx.eventID, .started(atMS: clock.calendarMS()))])
                }
                let effect = try await act(ctx, app: app, window: window, timings: &timings)
                _ = try await Self.timed("conclude(1 commit)", &timings) {
                    try await memory.advance([AgentCallTransition(ctx.eventID, AgentCallProgress(
                        .completed, result: .outcome(.foundActed, message: "synthetic"), endedAtMS: clock.calendarMS(),
                        durationMS: 1, observedEffect: effect))])
                }
                acts += 1; events += 1
            } else if roll < 80 {
                let record = try AgentCallRecord(event: ctx.event(app: identity, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS()),
                                                 request: .observe)
                _ = try await Self.timed("plan(1 commit)", &timings) { try await memory.record(record) }
                _ = try await Self.timed("start(1 commit)", &timings) {
                    try await memory.advance([AgentCallTransition(ctx.eventID, .started(atMS: clock.calendarMS()))])
                }
                let recorder = CallRecorder(memory: memory, brain: brain, context: ctx, sessionRevision: 1, requestedAt: clock.brainNow())
                _ = await Self.timed("recorder-observe(3 commits)", &timings) { await recorder.observe(Self.window(app: app, window: window)) }
                #expect(await recorder.report().notes.isEmpty)
                _ = try await Self.timed("conclude(1 commit)", &timings) {
                    try await memory.advance([AgentCallTransition(ctx.eventID, AgentCallProgress(
                        .completed, result: .observation(ObservationResult(sessionID: ctx.sessionID ?? "", sessionRevision: 1,
                                                                          observedAtMS: clock.calendarMS(),
                                                                          sample: CaptureSampleKey(eventID: ctx.eventID, phase: .current))),
                        endedAtMS: clock.calendarMS(), durationMS: 1))])
                }
                observations += 1; events += 1
            } else {
                let count = 2 + random.below(3)
                let children = (0..<count).map { ctx.child($0, eventID: "\(ctx.eventID)-\($0)") }
                let parent = try AgentCallRecord(event: ctx.event(app: identity, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS()),
                                                 request: .batch)
                let stepRecords = try children.map {
                    try AgentCallRecord(event: $0.event(app: identity, occurredAtMS: clock.calendarMS(), monotonicNS: clock.monotonicNS()),
                                        request: .act(target: "Control 0", verb: .click, value: nil, section: nil))
                }
                _ = try await Self.timed("plan-batch(1 commit)", &timings) { try await memory.record(batch: parent, steps: stepRecords) }
                _ = try await Self.timed("start(1 commit)", &timings) {
                    try await memory.advance([AgentCallTransition(ctx.eventID, .started(atMS: clock.calendarMS()))])
                }
                for child in children {
                    _ = try await Self.timed("start(1 commit)", &timings) {
                        try await memory.advance([AgentCallTransition(child.eventID, .started(atMS: clock.calendarMS()))])
                    }
                    let effect = try await act(child, app: app, window: window, timings: &timings)
                    _ = try await Self.timed("conclude(1 commit)", &timings) {
                        try await memory.advance([AgentCallTransition(child.eventID, AgentCallProgress(
                            .completed, result: .outcome(.foundActed, message: "synthetic"), endedAtMS: clock.calendarMS(),
                            durationMS: 1, observedEffect: effect))])
                    }
                }
                _ = try await Self.timed("conclude(1 commit)", &timings) {
                    try await memory.advance([AgentCallTransition(ctx.eventID, AgentCallProgress(
                        .completed, result: .batch(stopped: false, attempted: count, verified: count), endedAtMS: clock.calendarMS(),
                        durationMS: 1))])
                }
                batches += 1; steps += count; events += 1 + count
            }
            calls += 1
            index += 1
        }
        let written = ContinuousClock.now - started
        let writtenStatus = await memory.status()
        let concurrentLines = writer?.end() ?? []

        // Sizes and one explicit passive checkpoint while the writer's service is still open (the last
        // connection's close folds the log into the file, so the log is only seen while one is open).
        let file = memory.url
        func size(_ path: String) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? -1 }
        let dbBefore = size(file.path), walBefore = size(file.path + "-wal")
        let store = SQLiteMemoryStore(url: file)
        try await store.open(.existingArchive)
        let checkpoint = try await store.checkpoint()
        let dbAfter = size(file.path), walAfter = size(file.path + "-wal")
        await store.close()
        await memory.close()

        // Reads, as the readers do, on a service opened anew: the first of each kind after the open, then warm.
        let reader = MemoryService(directory: directory)
        try await reader.openForReading()
        var reads = Timings()
        var random2 = Generator(state: Self.seed ^ 0xA5A5)
        for repetition in 0..<(Self.readRepetitions + 1) {
            let prefix = repetition == 0 ? "first-" : ""
            let trace = traces[random2.below(traces.count)]
            let app = Self.bundle(random2.below(Self.applications))
            _ = try await Self.timed("\(prefix)read-traces-page(20)", &reads) { try await reader.traces(before: nil, limit: 20) }
            _ = try await Self.timed("\(prefix)read-trace-entries(50)", &reads) { try await reader.entries(inTrace: trace, after: nil, limit: 50) }
            _ = try await Self.timed("\(prefix)read-trace-calls(50)", &reads) { try await reader.calls(inTrace: trace, after: nil, limit: 50) }
            _ = try await Self.timed("\(prefix)read-scenes-of-app", &reads) { try await reader.scenes(of: app) }
            let projected = try await Self.timed("\(prefix)read-brain-projection-of-app", &reads) { try await reader.brain(of: app) }
            #expect(projected != nil)
            _ = try await Self.timed("\(prefix)read-overview", &reads) { try await reader.overview() }
        }
        let catalogue = try await reader.overview()
        await reader.close()

        // Rows per event, with a read-only connection of its own.
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let handle = try #require(db)
        func scalar(_ sql: String) -> Int64 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : -1
        }
        var tables: [String] = []
        var statement: OpaquePointer?
        sqlite3_prepare_v2(handle, "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name", -1, &statement, nil)
        while sqlite3_step(statement) == SQLITE_ROW { tables.append(String(cString: sqlite3_column_text(statement, 0))) }
        sqlite3_finalize(statement)
        var totalRows: Int64 = 0
        var perTable: [String] = []
        for table in tables {
            let rows = scalar("SELECT count(*) FROM \"\(table)\"")
            totalRows += rows
            if rows > 0 { perTable.append("\(table)=\(rows)") }
        }
        // The catalogue's evidence per application against a count of its own, applications without any included.
        var evidence: [String: Int] = [:]
        sqlite3_prepare_v2(handle, """
            SELECT a.bundle_id, count(e.evidence_id) FROM brain_apps a LEFT JOIN brain_evidence e ON e.app_id = a.app_id
            GROUP BY a.bundle_id
            """, -1, &statement, nil)
        while sqlite3_step(statement) == SQLITE_ROW {
            evidence[String(cString: sqlite3_column_text(statement, 0))] = Int(sqlite3_column_int64(statement, 1))
        }
        sqlite3_finalize(statement)
        #expect(Dictionary(uniqueKeysWithValues: catalogue.apps.map { ($0.bundleID, $0.brainEvidence) }) == evidence,
                "the catalogue's evidence per application is the table's own count")
        let storedEvents = scalar("SELECT count(*) FROM memory_events WHERE event_id LIKE 'cost-%'")
        let otherEvents = scalar("SELECT count(*) FROM memory_events WHERE event_id NOT LIKE 'cost-%'")
        let pageSize = scalar("PRAGMA page_size"), pageCount = scalar("PRAGMA page_count")
        sqlite3_close(handle)
        if let keep = Self.keep {
            let copier = SQLiteMemoryStore(url: file)
            try await copier.open(.existingArchive)
            try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
            _ = try await copier.snapshot(to: keep.appendingPathComponent("cost-\(Self.targetEvents)-\(Self.seed)\(Self.concurrent ? "-concurrent" : "").sqlite"))
            await copier.close()
        }

        let ms = written.components.seconds * 1000 + written.components.attoseconds / 1_000_000_000_000_000
        print("COST corpus seed=\(Self.seed) targetEvents=\(Self.targetEvents) storedEvents=\(storedEvents) calls=\(calls) acts=\(acts) "
              + "observations=\(observations) batches=\(batches) batchSteps=\(steps) traces=\(traces.count) "
              + "apps=\(Self.applications) windowElements=\(Self.windowSizes) concurrentProcess=\(Self.concurrent)")
        print("COST write wallMs=\(ms) eventsPerSecond=\(ms > 0 ? Int64(events) * 1000 / ms : -1) "
              + "commits=\(writtenStatus.diagnostics?.commits ?? -1) busyRetries=\(writtenStatus.diagnostics?.busyRetries ?? -1) "
              + "waitedMs=\(writtenStatus.diagnostics.map { $0.waited.components.seconds * 1000 + $0.waited.components.attoseconds / 1_000_000_000_000_000 } ?? -1) "
              + "exhaustedCycles=\(writtenStatus.diagnostics?.exhaustedCycles ?? -1)")
        for name in timings.values.keys.sorted() { print("COST write \(timings.line(name))") }
        for name in reads.values.keys.sorted() { print("COST read \(reads.line(name))") }
        print("COST size (writer open, before the explicit checkpoint) dbBytes=\(dbBefore) walBytes=\(walBefore) pageSize=\(pageSize) pageCount=\(pageCount) "
              + "bytesPerEvent=\(storedEvents > 0 ? (dbBefore + max(walBefore, 0)) / storedEvents : -1)")
        print("COST checkpoint frames=\(checkpoint.frames) checkpointed=\(checkpoint.checkpointedFrames) outcome=\(checkpoint.outcome) "
              + "durationUs=\(checkpoint.duration.components.seconds * 1_000_000 + checkpoint.duration.components.attoseconds / 1_000_000_000_000) "
              + "dbBytesAfter=\(dbAfter) walBytesAfter=\(walAfter) (writer's service still open)")
        print("COST rows total=\(totalRows) perEvent=\(storedEvents > 0 ? String(format: "%.2f", Double(totalRows) / Double(storedEvents)) : "-") tables=\(perTable.joined(separator: " "))")
        print("COST concurrent-process processes=\(concurrentLines.count) eventsWritten=\(otherEvents) (counted apart from the corpus; rows per event include theirs)")
        for line in concurrentLines.prefix(5) { print("COST concurrent-process \(line)") }
        if concurrentLines.count > 5 { print("COST concurrent-process ... \(concurrentLines.count - 5) more") }

        #expect(storedEvents == Int64(events), "every event of the corpus is stored once")
        #expect(writtenStatus.diagnostics?.retainedWrites == 0)
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    /// What the catalogue and the pages of traces answer, as text in a fixed order, so two builds or two
    /// openings of the same archive can be compared by a digest without printing the content.
    private static func digest(_ overview: MemoryOverview) -> String {
        let apps = overview.apps.map { app in
            [app.bundleID, "\(app.contexts)", "\(app.projectionAnchors)", "\(app.projectionGroups)", "\(app.projectionTransitions)",
             "\(app.structuralScenes)", "\(app.sceneElements)", "\(app.generalArcs)", "\(app.menuCommands)",
             "\(app.brainEvidence)", "\(app.events)", "\(app.samples)"].joined(separator: ",")
        }
        let routes = overview.routes.keys.map(\.rawValue).sorted().map { key in
            "\(key)=\(overview.routes.first { $0.key.rawValue == key }?.value ?? 0)"
        }
        return (apps + routes + ["\(overview.experiences)", "\(overview.taskOccurrences)", "\(overview.stepOccurrences)",
                                 "\(overview.eventsWithoutApp)"]).joined(separator: ";")
    }

    private static func digest(_ pages: [TraceSummary]) -> String {
        pages.map { "\($0.traceID),\($0.events),\($0.calls),\($0.firstLocalOrder),\($0.lastLocalOrder),"
            + "\($0.firstOccurredAtMS),\($0.lastOccurredAtMS),\($0.source.rawValue),\($0.streamID)" }.joined(separator: ";")
    }

    /// FNV-1a, 64 bits: a short, stable name for a long text.
    private static func fnv(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return String(hash, radix: 16)
    }

    /// The whole pagination, `limit` at a time, newest first.
    private static func allPages(_ reader: MemoryService, limit: Int) async throws -> [TraceSummary] {
        var all: [TraceSummary] = []
        var before: Int64?
        while true {
            let page = try await reader.traces(before: before, limit: limit)
            if page.isEmpty { return all }
            all += page
            before = page.last?.lastLocalOrder
        }
    }

    /// Reads of a corpus kept by `measure` (`MECUM_COST_ARCHIVE=<snapshot>`), on a copy so the snapshot is
    /// never opened: the catalogue and pages of traces, the first after an open and then repeated, with a
    /// `memory-probe` process writing to the same copy meanwhile when `MECUM_COST_CONCURRENT=1`. The same
    /// snapshot read by two builds compares them on identical content. Prints `COST-READ` lines and digests
    /// of what was answered (catalogue, first page, middle page, the whole pagination), read again after a
    /// second opening; asserts only that the two openings answered the same.
    @Test("reads of a kept corpus, on a copy: catalogue and pages of traces, first after an open and repeated, digests of what they answer",
          .enabled(if: ProcessInfo.processInfo.environment["MECUM_COST_ARCHIVE"] != nil,
                   "MECUM_COST_ARCHIVE=<snapshot> names the corpus to read"))
    func readsOfAKeptCorpus() async throws {
        let source = URL(fileURLWithPath: try #require(Self.environment["MECUM_COST_ARCHIVE"]))
        let directory = Fixtures.directory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let copy = directory.appendingPathComponent("memory.sqlite")
        try FileManager.default.copyItem(at: source, to: copy)

        func opened() async throws -> MemoryService {
            let reader = MemoryService(directory: directory)
            try await reader.openForReading()
            return reader
        }
        func ms(_ duration: Duration) -> Int64 { duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000 }

        var reads = Timings()
        let reader = try await opened()
        let overview = try await Self.timed("first-read-overview", &reads) { try await reader.overview() }
        let firstPage = try await Self.timed("first-read-traces-page(20)", &reads) { try await reader.traces(before: nil, limit: 20) }
        let started = ContinuousClock.now
        let all = try await Self.allPages(reader, limit: 20)
        let paginated = ContinuousClock.now - started
        let middle = all.isEmpty ? nil : all[all.count / 2].lastLocalOrder
        let middlePage = try await reader.traces(before: middle, limit: 20)
        let writer = Self.concurrent ? ConcurrentWriter(path: copy.path) : nil
        if Self.concurrent, writer == nil { Issue.record("memory-probe is not built beside the tests; run swift build --product memory-probe") }
        for _ in 0..<Self.readRepetitions {
            _ = try await Self.timed("read-overview", &reads) { try await reader.overview() }
            _ = try await Self.timed("read-traces-page(20)", &reads) { try await reader.traces(before: nil, limit: 20) }
            _ = try await Self.timed("read-traces-middle-page(20)", &reads) { try await reader.traces(before: middle, limit: 20) }
        }
        let concurrentLines = writer?.end() ?? []
        await reader.close()

        // A second opening of the same copy: the same answers, the probe's events aside (they carry no trace
        // and belong to no application of the corpus, so they change neither the catalogue's applications
        // nor the pages; the catalogue's count of events without an application is compared apart).
        let again = try await opened()
        let overviewAgain = try await again.overview()
        let allAgain = try await Self.allPages(again, limit: 20)
        await again.close()

        print("COST-READ archive=\(source.lastPathComponent) concurrentProcess=\(Self.concurrent) traces=\(all.count) "
              + "middleCursor=\(middle.map(String.init) ?? "none") fullPaginationMs=\(ms(paginated))")
        for name in reads.values.keys.sorted() { print("COST-READ \(reads.line(name))") }
        print("COST-READ digest overview=\(Self.fnv(Self.digest(overview))) firstPage=\(Self.fnv(Self.digest(firstPage))) "
              + "middlePage=\(Self.fnv(Self.digest(middlePage))) allPages=\(Self.fnv(Self.digest(all)))")
        print("COST-READ concurrent-process processes=\(concurrentLines.count)")
        #expect(Self.digest(allAgain) == Self.digest(all), "the second opening pages the same traces")
        #expect(overviewAgain.apps.map(\.bundleID) == overview.apps.map(\.bundleID))
        if !Self.concurrent { #expect(Self.digest(overviewAgain) == Self.digest(overview), "the second opening answers the same catalogue") }
    }
}
