//
//  Probe.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

import EngineCore
import Foundation
import Memory
import PerceptionCore
import SQLiteMemory

/// Probe is the helper's state: at most one store, opened on request, and the commands that drive
/// it. Every command answers exactly one line, except the ones whose point is to answer nothing:
/// `record-and-die` ends the process after its commit and before its answer, and `hold` answers
/// once when the transaction is open and again when the next line ends it.
final class Probe {

    enum Outcome {
        case answered, exit
    }

    /// The commands, one per line, as `measure-memory-store.sh` and the tests send them.
    static let usage = """
        open <path> [lockBudgetMs] [retryPauseMs] [maximumRetryPauseMs]
        waits                              print the store's wait events as `wait ...` lines
        record <id> <key> <occurredAtMs>   committed | alreadyApplied | identity
        record-and-die <id> <key> <occurredAtMs>   commit, then SIGKILL this process before answering
        brain-observe <bundle> <event> <phase> <ordinal> <requestedMs> <label,label,...>
                                           apply an observation once: committed|alreadyApplied id= outcome= effective=
        brain-observe-and-die <same arguments>   apply, commit, then SIGKILL this process before answering
        brain-decode <count> <rows>        rebuild an observation from detection_count and that many detections:
                                           accepted detections=<n> | error brain <refusal>
        brain-application <event> <phase> <ordinal>   read a stored observation: application id= detections= | none
        call-record <event> <session> <target>   record an act call (click) planned: committed | alreadyApplied
        call-record-and-die <same arguments>     record it, commit, then SIGKILL this process before answering
        hold <rows> <bytes> [cacheKiB]     insert rows into brain_apps, answer `held`, wait for commit | abort
        hold-for <ms> <rows> <bytes>       same, but commit by itself after the pause
        increment <stream> <count>         count read-modify-write events on the stream
        count-events <stream>              events <count> distinct=<n> max=<m>
        count-apps                         apps <count>
        write-apps <rows> <bytes>          one write of rows into brain_apps
        limit-file-size <bytes|wal>        RLIMIT_FSIZE for this process; `wal` = the log's current size
        unlimit-file-size
        measure <stream> <count> <bytes>   count writes, latency percentiles and waits
        recover <path>                     recover the archive under its exclusive presence lock:
                                           recovery inUse | notCorrupt | recovered aside=<name> restored=<copy|none>
        recover-after <path> [hold]        open the archive, answer `saw <error>`, wait for `go`, then recover;
                                           with hold, answer `holding` with the exclusive lock held and keep it
                                           until the next line, then answer the recovery
        recover-stop <path> <stage>        recover, and at the stage (recorded, movedAside, published, finished)
                                           answer `stopped <stage>` and wait: `continue` goes on, any other
                                           line stops the recovery there, and a kill ends the process there
        open-recovering <path> [stage]     open as the memory service does: an archive the library calls
                                           corrupt, or a recovery that stopped, is recovered first (answering
                                           `recovery ...`, stopping at the stage if given), then opened
        inspect <path>                     the read-only diagnosis: inspect <shape> version=<n|none>
        checkpoint
        diagnostics
        version
        close
        exit
        """

    private var store        : SQLiteMemoryStore?
    private var printsWaits  = false
    private var fileSizeLimit: rlimit?
    private let clock        = ContinuousClock()

    func perform(_ line: String) async -> Outcome {
        let words = line.split(separator: " ").map(String.init)
        guard let command = words.first else { return .answered }
        let arguments = Array(words.dropFirst())
        do {
            switch command {
            case "open"            : try await open(arguments)
            case "waits"           : try await waits()
            case "record"          : try await record(arguments, die: false)
            case "record-and-die"  : try await record(arguments, die: true)
            case "brain-observe"   : try await brainObserve(arguments, die: false)
            case "brain-observe-and-die": try await brainObserve(arguments, die: true)
            case "brain-decode"    : try brainDecode(arguments)
            case "brain-application": try await brainApplication(arguments)
            case "call-record"     : try await callRecord(arguments, die: false)
            case "call-record-and-die": try await callRecord(arguments, die: true)
            case "hold"            : try await hold(arguments, pause: nil)
            case "hold-for":
                let pause = Int(arguments.first ?? "0") ?? 0
                try await hold(Array(arguments.dropFirst()), pause: .milliseconds(pause))
            case "increment"       : try await increment(arguments)
            case "count-events"    : try await countEvents(arguments)
            case "count-apps"      : try await countApps()
            case "write-apps"      : try await writeApps(arguments)
            case "limit-file-size" : try await limitFileSize(arguments)
            case "unlimit-file-size": unlimitFileSize()
            case "measure"         : try await measure(arguments)
            case "recover"         : try recover(arguments, hold: false)
            case "recover-after"   : try await recoverAfter(arguments)
            case "recover-stop":
                guard arguments.count == 2, let stage = SQLiteMemoryRecovery.Stage(rawValue: arguments[1]) else {
                    emit("error usage recover-stop"); return .answered
                }
                try recover([arguments[0]], hold: false, stop: stage)
            case "open-recovering" : try await openRecovering(arguments)
            case "inspect"         : inspect(arguments)
            case "checkpoint"      : try await checkpoint()
            case "diagnostics"     : try await diagnostics()
            case "version"         : emit("sqlite \(SQLiteLibrary.version) \(SQLiteLibrary.sourceID)")
            case "close"           : await end(); emit("closed")
            case "exit"            : return .exit
            default                : emit("error unknown-command \(command)")
            }
        } catch let error as MemoryStoreError {
            emit("error \(Self.describe(error))")
        } catch let error as BrainApplicationError {
            emit("error brain \(error)")
        } catch let error as AgentCallError {
            emit("error call \(error)")
        } catch {
            emit("error other \(type(of: error))")
        }
        return .answered
    }

    func end() async {
        await store?.close()
        store = nil
    }

    // MARK: Commands

    private func open(_ arguments: [String]) async throws {
        guard let path = arguments.first else { emit("error usage open"); return }
        var configuration = SQLiteMemoryStore.Configuration()
        if arguments.count > 1, let budget = Int(arguments[1]) { configuration.lockBudget = .milliseconds(budget) }
        if arguments.count > 2, let pause = Int(arguments[2]) {
            configuration.retryPause = .milliseconds(pause)
        }
        if arguments.count > 3, let maximum = Int(arguments[3]) {
            configuration.maximumRetryPause = .milliseconds(maximum)
        }
        let opened = SQLiteMemoryStore(url: URL(fileURLWithPath: path), configuration: configuration)
        if printsWaits { await observeWaits(of: opened) }
        try await opened.open()
        store = opened
        let diagnostics = try await opened.diagnostics()
        let bootstrapped = diagnostics.bootstrappedNow ? 1 : 0
        emit("opened bootstrapped=\(bootstrapped) version=\(diagnostics.schemaVersion) pid=\(getpid())")
    }

    /// Arms the wait observer: on the open store, or on the one `open` is about to create, so the
    /// waits of the open itself are printed too.
    private func waits() async throws {
        printsWaits = true
        if let store { await observeWaits(of: store) }
        emit("waits on")
    }

    private func observeWaits(of store: SQLiteMemoryStore) async {
        await store.observeWaits { event in
            switch event {
            case .pausing(let phase, let attempt):
                Probe.emit("wait pausing \(phase.rawValue) \(attempt)")
            case .cycleExhausted(let phase, let attempts, let waited):
                Probe.emit("wait exhausted \(phase.rawValue) \(attempts) \(waited.milliseconds)")
            case .yielding(let phase, let remaining):
                Probe.emit("wait yielding \(phase.rawValue) \(remaining)")
            }
        }
    }

    private func record(_ arguments: [String], die: Bool) async throws {
        let store = try opened()
        guard arguments.count == 3, let occurredAt = Int64(arguments[2]) else {
            emit("error usage record")
            return
        }
        let receipt = try await Self.record(id: arguments[0], key: arguments[1], occurredAt: occurredAt, in: store)
        if die {
            // The commit is on disk and the caller has not been answered: the outcome is theirs to look up.
            kill(getpid(), SIGKILL)
        }
        emit(receipt == .committed ? "committed" : "alreadyApplied")
    }

    /// Applies an observation through the application repository: control detections labeled as
    /// given, one under the other (x 0.5, y 0.1 + 0.05 i, 0.03 by 0.017), the fixture shape the
    /// tests build the same command from, so a test can offer the very same command afterwards.
    private func brainObserve(_ arguments: [String], die: Bool) async throws {
        let store = try opened()
        guard arguments.count == 6, let ordinal = Int(arguments[3]), let requested = Int64(arguments[4]),
              let phase = CapturePhase(rawValue: arguments[2]) else {
            emit("error usage brain-observe")
            return
        }
        let labels = arguments[5].split(separator: ",").map(String.init)
        let detections = labels.enumerated().map { index, label in
            BrainDetection(kind: .control, label: label,
                           bounds: NormalizedRect(x: 0.5, y: 0.1 + 0.05 * Double(index), width: 0.03, height: 0.017))
        }
        let command = try BrainApplicationCommand.observe(
            detections: detections, window: nil, bundleID: arguments[0],
            sample: CaptureSampleKey(eventID: arguments[1], phase: phase, ordinal: ordinal),
            requestedAt: Date(timeIntervalSince1970: Double(requested) / 1000)
        )
        let result = try await SQLiteBrainApplicationRepository(store: store).apply(command)
        if die {
            // The application is committed and the caller has not been answered: it asks again by the key.
            kill(getpid(), SIGKILL)
        }
        guard case .observed(let created, let updated, _) = result.outcome else {
            emit("error outcome")
            return
        }
        let receipt = result.receipt == .committed ? "committed" : "alreadyApplied"
        emit("\(receipt) id=\(result.applicationID) created=\(created) updated=\(updated) effective=\(result.effectiveAtMS)")
    }

    /// Rebuilds an observation from stored arguments without a store: `detection_count` as given and
    /// `rows` complete detections at positions 0 ..< rows. The decoder the SQL reader calls, run in a
    /// process of its own, so a declared count that ends the process ends only the helper.
    private func brainDecode(_ arguments: [String]) throws {
        guard arguments.count == 2, let count = Int64(arguments[0]), let rows = Int(arguments[1]), rows >= 0 else {
            emit("error usage brain-decode")
            return
        }
        var stored = [BrainArgument(name: "detection_count", position: 0, value: .integer(count))]
        for position in 0..<rows {
            stored += [
                BrainArgument(name: "detection_kind", position: position, value: .text("control")),
                BrainArgument(name: "detection_label", position: position, value: .text("D\(position)")),
                BrainArgument(name: "detection_x", position: position, value: .real(0.5)),
                BrainArgument(name: "detection_y", position: position, value: .real(0.1 + 0.05 * Double(position))),
                BrainArgument(name: "detection_width", position: position, value: .real(0.03)),
                BrainArgument(name: "detection_height", position: position, value: .real(0.017)),
            ]
        }
        let command = try BrainApplicationCommand(
            key: .observe(CaptureSampleKey(eventID: "probe", phase: .after)), bundleID: "test.probe",
            requestedAtMS: 0, arguments: stored, applicationID: 1
        )
        guard case .observe(_, let detections) = command.input else {
            emit("error outcome")
            return
        }
        emit("accepted detections=\(detections.count)")
    }

    /// Reads the stored observation of a sample through the application repository's reader.
    private func brainApplication(_ arguments: [String]) async throws {
        let store = try opened()
        guard arguments.count == 3, let phase = CapturePhase(rawValue: arguments[1]), let ordinal = Int(arguments[2]) else {
            emit("error usage brain-application")
            return
        }
        let key = BrainApplicationKey.observe(CaptureSampleKey(eventID: arguments[0], phase: phase, ordinal: ordinal))
        guard let application = try await SQLiteBrainApplicationRepository(store: store).application(key) else {
            emit("none")
            return
        }
        guard case .observe(_, let detections) = application.command.input else {
            emit("error outcome")
            return
        }
        emit("application id=\(application.applicationID) detections=\(detections.count)")
    }

    /// Records an `act` call (click on the target) through the call repository, in the shape the
    /// tests build the same record in: source app, stream `worker`, trace `trace-1`, the session
    /// given, application `test.fixture.calls`, occurred at 1 700 000 000 000 ms.
    private func callRecord(_ arguments: [String], die: Bool) async throws {
        let store = try opened()
        guard arguments.count == 3 else {
            emit("error usage call-record")
            return
        }
        let call = try AgentCallRecord(
            event: MemoryEventRecord(eventID: arguments[0], source: .app, streamID: "worker", traceID: "trace-1",
                                     sessionID: arguments[1], kind: .action, app: AppContextIdentity(bundleID: "test.fixture.calls"),
                                     occurredAtMS: 1_700_000_000_000),
            request: .act(target: arguments[2], verb: .click, value: nil, section: nil)
        )
        let receipt = try await SQLiteAgentCallRepository(store: store).record(call)
        if die {
            // The call is committed and the caller has not been answered: it offers the same record again.
            kill(getpid(), SIGKILL)
        }
        emit(receipt == .committed ? "committed" : "alreadyApplied")
    }

    private func hold(_ arguments: [String], pause: Duration?) async throws {
        let store = try opened()
        guard arguments.count >= 2, let rows = Int(arguments[0]), let bytes = Int(arguments[1]) else {
            emit("error usage hold")
            return
        }
        let cacheKiB = arguments.count > 2 ? Int(arguments[2]) : nil
        let padding  = String(repeating: "h", count: bytes)
        let outcome  = try await store.write { transaction in
            if let cacheKiB {
                // A small cache and spill threshold make the writer put its pages into the log before the commit.
                try transaction.execute("PRAGMA cache_size = -\(cacheKiB)")
                try transaction.execute("PRAGMA cache_spill = 1")
            }
            for index in 0..<rows {
                try transaction.execute(
                    "INSERT INTO brain_apps (bundle_id) VALUES (?)",
                    [.text("hold.\(getpid()).\(index).\(padding)")]
                )
            }
            Probe.emit("held rows=\(rows)")
            if let pause {
                // A slow writer of another process: the lock stays held for this long, then commits.
                Thread.sleep(forTimeInterval: Double(pause.milliseconds) / 1000)
                return "committed"
            }
            // Blocked on purpose inside the transaction: the next line, or a signal, decides the end.
            switch readLine() {
            case "commit"?: return "committed"
            default       : throw HoldAborted()
            }
        }
        emit(outcome)
    }

    private struct HoldAborted: Error {}

    // MARK: Recovery and diagnosis

    /// Recovers the archive at the path from the copies beside it (`<name>.backup-*`, newest name
    /// first), as `MemoryService` does; `hold` keeps the exclusive lock until the next line.
    private struct Stopped: Error {}

    private func recover(_ arguments: [String], hold: Bool, stop: SQLiteMemoryRecovery.Stage? = nil) throws {
        guard let path = arguments.first else { emit("error usage recover"); return }
        let archive = URL(fileURLWithPath: path)
        let copies  = {
            let directory = archive.deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.filter { $0.hasPrefix("\(archive.lastPathComponent).backup-") }.sorted(by: >)
                .map { directory.appendingPathComponent($0) }
        }
        let outcome = try SQLiteMemoryRecovery.recover(archive, copies: copies, stamp: "probe-\(getpid())") { stage in
            if hold, stage == .finished {
                Probe.emit("holding")
                _ = readLine()
            }
            if stage == stop {
                // Blocked on purpose: a kill ends the process at this stage, `continue` goes on.
                Probe.emit("stopped \(stage.rawValue)")
                guard readLine() == "continue" else { throw Stopped() }
            }
        }
        switch outcome {
        case .inUse                            : emit("recovery inUse")
        case .notCorrupt                       : emit("recovery notCorrupt")
        case .recovered(let aside, let restored): emit("recovery recovered aside=\(aside) restored=\(restored ?? "none")")
        case .resumed(let aside, let restored)  : emit("recovery resumed aside=\(aside) restored=\(restored ?? "none")")
        }
    }

    /// Opens as `MemoryService` does: when the open finds a file the library calls corrupt, or the record
    /// of a recovery that stopped, it recovers first and opens again. Every other error is answered.
    private func openRecovering(_ arguments: [String]) async throws {
        guard let path = arguments.first else { emit("error usage open-recovering"); return }
        do {
            try await open([path])
            return
        } catch let error as MemoryStoreError {
            guard Self.needsRecovery(error, at: URL(fileURLWithPath: path)) else { throw error }
        }
        try recover([path], hold: false, stop: arguments.count > 1 ? SQLiteMemoryRecovery.Stage(rawValue: arguments[1]) : nil)
        try await open([path])
    }

    private static func needsRecovery(_ error: MemoryStoreError, at url: URL) -> Bool {
        let fault: MemoryStoreFault
        switch error {
        case .unavailable(.interruptedRecovery)                         : return true
        case .open(let found), .failed(let found), .locked(let found), .contract(let found): fault = found
        case .unavailable(.failed(let found))                           : fault = found
        default                                                         : return false
        }
        return (fault.code.primary == 11 || fault.code.primary == 26) && FileManager.default.fileExists(atPath: url.path)
    }

    /// Sees the archive's error as an open does, then waits for `go` before recovering: two helpers
    /// that both saw the old error before either took the lock.
    private func recoverAfter(_ arguments: [String]) async throws {
        guard let path = arguments.first else { emit("error usage recover-after"); return }
        do {
            let store = try await SQLiteMemoryStore.open(at: URL(fileURLWithPath: path))
            await store.close()
            emit("saw nothing")
        } catch let error as MemoryStoreError {
            emit("saw \(Self.describe(error))")
        }
        guard readLine() == "go" else { emit("error expected go"); return }
        try recover([path], hold: arguments.count > 1 && arguments[1] == "hold")
    }

    private func inspect(_ arguments: [String]) {
        guard let path = arguments.first else { emit("error usage inspect"); return }
        let report = SQLiteMemoryInspection.inspect(URL(fileURLWithPath: path))
        let shape: String
        switch report.shape {
        case .missing    : shape = "missing"
        case .empty      : shape = "empty"
        case .current    : shape = "current"
        case .refused    : shape = "refused"
        case .unreadable : shape = "unreadable"
        case .unavailable: shape = "unavailable"
        case .interruptedRecovery: shape = "interruptedRecovery"
        }
        emit("inspect \(shape) version=\(report.schemaVersion.map(String.init) ?? "none")")
    }

    private func increment(_ arguments: [String]) async throws {
        let store = try opened()
        guard arguments.count == 2, let count = Int(arguments[1]) else {
            emit("error usage increment")
            return
        }
        let stream = arguments[0]
        var last: Int64 = 0
        for index in 0..<count {
            let id = "\(getpid())-\(index)"
            last = try await store.write { transaction in
                let highest = try transaction.query(
                    "SELECT coalesce(max(occurred_at_ms), 0) FROM memory_events WHERE source_stream_id = ?",
                    [.text(stream)]
                ) { $0.integer(0) ?? 0 }.first ?? 0
                try transaction.execute(
                    """
                    INSERT INTO memory_events
                        (event_id, source, source_stream_id, source_key, event_kind, occurred_at_ms, capture_status)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(id), .text("app"), .text(stream), .text(id), .text("action"),
                     .integer(highest + 1), .text("complete")]
                )
                return highest + 1
            }
        }
        emit("incremented \(count) last=\(last)")
    }

    private func countEvents(_ arguments: [String]) async throws {
        let store = try opened()
        guard let stream = arguments.first else { emit("error usage count-events"); return }
        let counts = try await store.read { snapshot in
            try snapshot.query(
                """
                SELECT count(*), count(DISTINCT occurred_at_ms), coalesce(max(occurred_at_ms), 0)
                FROM memory_events WHERE source_stream_id = ?
                """,
                [.text(stream)]
            ) { ($0.integer(0) ?? 0, $0.integer(1) ?? 0, $0.integer(2) ?? 0) }.first ?? (0, 0, 0)
        }
        emit("events \(counts.0) distinct=\(counts.1) max=\(counts.2)")
    }

    private func countApps() async throws {
        let store = try opened()
        let count = try await store.read { snapshot in
            try snapshot.query("SELECT count(*) FROM brain_apps") { $0.integer(0) ?? 0 }.first ?? 0
        }
        emit("apps \(count)")
    }

    private func writeApps(_ arguments: [String]) async throws {
        let store = try opened()
        guard arguments.count == 2, let rows = Int(arguments[0]), let bytes = Int(arguments[1]) else {
            emit("error usage write-apps")
            return
        }
        let padding = String(repeating: "w", count: bytes)
        _ = try await store.write { transaction in
            for index in 0..<rows {
                try transaction.execute(
                    "INSERT INTO brain_apps (bundle_id) VALUES (?)",
                    [.text("apps.\(getpid()).\(index).\(padding)")]
                )
            }
        }
        emit("committed")
    }

    private func limitFileSize(_ arguments: [String]) async throws {
        guard let word = arguments.first else { emit("error usage limit-file-size"); return }
        let bytes: UInt64
        if word == "wal" {
            let store = try opened()
            let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path + "-wal")
            bytes = (attributes[.size] as? UInt64) ?? 0
        } else {
            guard let given = UInt64(word) else { emit("error usage limit-file-size"); return }
            bytes = given
        }
        var limit = rlimit()
        getrlimit(RLIMIT_FSIZE, &limit)
        if fileSizeLimit == nil { fileSizeLimit = limit }
        // Without this the kernel ends the process with SIGXFSZ instead of failing the write.
        signal(SIGXFSZ, SIG_IGN)
        limit.rlim_cur = rlim_t(bytes)
        guard setrlimit(RLIMIT_FSIZE, &limit) == 0 else { emit("error setrlimit \(errno)"); return }
        emit("limited \(bytes)")
    }

    private func unlimitFileSize() {
        guard var limit = fileSizeLimit else { emit("unlimited"); return }
        setrlimit(RLIMIT_FSIZE, &limit)
        fileSizeLimit = nil
        emit("unlimited")
    }

    private func measure(_ arguments: [String]) async throws {
        let store = try opened()
        guard arguments.count == 3, let count = Int(arguments[1]), let bytes = Int(arguments[2]) else {
            emit("error usage measure")
            return
        }
        let stream  = arguments[0]
        let padding = String(repeating: "m", count: bytes)
        var latencies: [Int64] = []
        latencies.reserveCapacity(count)
        let started = clock.now
        for index in 0..<count {
            let id  = "\(getpid())-m-\(index)"
            let key = "\(id)-\(padding)"
            let began = clock.now
            _ = try await store.write { transaction in
                try transaction.execute(
                    """
                    INSERT INTO memory_events
                        (event_id, source, source_stream_id, source_key, event_kind, occurred_at_ms, capture_status)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    [.text(id), .text("app"), .text(stream), .text(key), .text("action"),
                     .integer(Int64(index)), .text("complete")]
                )
            }
            latencies.append((clock.now - began).microseconds)
        }
        let elapsed = (clock.now - started).milliseconds
        latencies.sort()
        let diagnostics = try await store.diagnostics()
        emit("measured count=\(count) bytes=\(bytes) p50us=\(Self.percentile(latencies, 50)) "
             + "p95us=\(Self.percentile(latencies, 95)) maxus=\(latencies.last ?? 0) elapsedMs=\(elapsed) "
             + "commits=\(diagnostics.commits) busyRetries=\(diagnostics.busyRetries) "
             + "waitedMs=\(diagnostics.waited.milliseconds) exhaustedCycles=\(diagnostics.exhaustedCycles)")
    }

    private func checkpoint() async throws {
        let store  = try opened()
        let report = try await store.checkpoint()
        emit("checkpoint frames=\(report.frames) checkpointed=\(report.checkpointedFrames) "
             + "outcome=\(report.outcome) durationUs=\(report.duration.microseconds)")
    }

    private func diagnostics() async throws {
        let store = try opened()
        let d = try await store.diagnostics()
        emit("diagnostics commits=\(d.commits) busyRetries=\(d.busyRetries) "
             + "waitedMs=\(d.waited.milliseconds) retainedWrites=\(d.retainedWrites) "
             + "exhaustedCycles=\(d.exhaustedCycles) checkpoints=\(d.checkpoints) "
             + "autoCheckpointFrames=\(d.autoCheckpointFrames) journal=\(d.journalMode) "
             + "synchronous=\(d.synchronous)")
    }

    // MARK: Support

    private func opened() throws -> SQLiteMemoryStore {
        guard let store else { throw MemoryStoreError.unavailable(.notOpened) }
        return store
    }

    /// The idempotent fixture writer of the tests, in this process too: the same identity with
    /// the same content is already applied, the same identity with other content is a conflict.
    /// The typed repositories will own this; until then it lives in the fixtures.
    private static func record(
        id        : String,
        key       : String,
        occurredAt: Int64,
        in store  : SQLiteMemoryStore
    ) async throws -> MemoryReceipt {
        try await store.write { transaction in
            let stored = try transaction.query(
                """
                SELECT source, source_stream_id, source_key, event_kind, occurred_at_ms, capture_status
                FROM memory_events WHERE event_id = ?
                """,
                [.text(id)]
            ) { row in
                [try row.text(0) ?? "", try row.text(1) ?? "", try row.text(2) ?? "", try row.text(3) ?? "",
                 String(row.integer(4) ?? 0), try row.text(5) ?? ""].joined(separator: "|")
            }.first
            let offered = ["app", "worker-1", key, "action", String(occurredAt), "complete"].joined(separator: "|")
            if let stored {
                guard stored == offered else {
                    throw MemoryStoreError.identity(MemoryIdentityConflict(
                        identity          : id,
                        storedFingerprint : stored,
                        offeredFingerprint: offered
                    ))
                }
                return .alreadyApplied
            }
            try transaction.execute(
                """
                INSERT INTO memory_events
                    (event_id, source, source_stream_id, source_key, event_kind, occurred_at_ms, capture_status)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(id), .text("app"), .text("worker-1"), .text(key), .text("action"),
                 .integer(occurredAt), .text("complete")]
            )
            return .committed
        }
    }

    private static func percentile(_ sorted: [Int64], _ percent: Int) -> Int64 {
        guard !sorted.isEmpty else { return 0 }
        let rank = max(0, min(sorted.count - 1, (sorted.count * percent + 99) / 100 - 1))
        return sorted[rank]
    }

    /// One compact line for a store error: the case, codes, phase and cleanup, never a value.
    static func describe(_ error: MemoryStoreError) -> String {
        switch error {
        case .open(let fault)                 : "open \(describe(fault))"
        case .schema(let mismatch)            : "schema \(mismatch)"
        case .contract(let fault)             : "contract \(describe(fault))"
        case .identity                        : "identity"
        case .malformedText(let fault):
            "malformedText column=\(fault.column) bytes=\(fault.byteCount) offset=\(fault.invalidByteOffset)"
        case .contention(let fault, let attempts, let waited):
            "contention \(describe(fault)) attempts=\(attempts) waitedMs=\(waited.milliseconds)"
        case .locked(let fault)               : "locked \(describe(fault))"
        case .failed(let fault)               : "failed \(describe(fault))"
        case .snapshot(let refusal)           : "snapshot \(refusal)"
        case .unavailable(.failed(let fault)) : "unavailable failed \(describe(fault))"
        case .unavailable(let why)            : "unavailable \(why)"
        case .cancelled(let phase)            : "cancelled \(phase.rawValue)"
        }
    }

    private static func describe(_ fault: MemoryStoreFault) -> String {
        let cleanup: String
        switch fault.cleanup {
        case .notNeeded                : cleanup = "notNeeded"
        case .alreadyRolledBack        : cleanup = "alreadyRolledBack"
        case .rolledBack               : cleanup = "rolledBack"
        case .failed(let code, _)      : cleanup = "failed(\(code.primary)/\(code.extended))"
        }
        return "code=\(fault.code.primary)/\(fault.code.extended) phase=\(fault.phase.rawValue) cleanup=\(cleanup)"
    }

    private func emit(_ line: String) { Self.emit(line) }

    // One write per line, unbuffered, so a reader sees the line the moment it is answered.
    static func emit(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

extension Duration {

    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    }

    var microseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1_000_000 + attoseconds / 1_000_000_000_000
    }
}
