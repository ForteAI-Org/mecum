import Foundation

/// A TAKE — one recorded run, and the corpus every plane of the harness replays.
///
/// Takes live at `~/.fflow/harness/<flow>/<take-ts>/` and **never in the repo, never in git**. That is
/// not tidiness: a take holds raw pixels of the user's real screen, which is strictly worse than the
/// Slack fixture that already lives privately. Only *reports* leave `~/.fflow` (see `HarnessReport`) —
/// a report may quote the user's own phrase, but it never carries the screen.
public struct TakeManifest: Codable, Sendable, Equatable {

    /// `trace` records only what production already computes (ADR 0010). `film` records full-rate
    /// frames for a bounded burst and therefore CHANGES the cost profile it is measuring — which is
    /// why it stamps `perturbed` and is refused entry to any baseline percentile.
    public enum Mode: String, Codable, Sendable { case trace, film }

    /// A task boundary. Rounds-per-*task* needs a task, and ticket 17's five reference flows are the
    /// task units — so the recorder marks them rather than leaving a replay to guess where one ended.
    public struct TaskMark: Codable, Sendable, Equatable {
        public let label: String
        public let at: Date
        public init(label: String, at: Date) { self.label = label; self.at = at }
    }

    public let flow: String
    public let takeID: String
    public let created: Date
    public let mode: Mode
    public let perturbed: Bool
    public let binary: HarnessReport.BinaryStamp
    public let deploySHA: String?
    /// Model, and the load average at both ends of the run. Both ends on purpose: a run that started
    /// on a quiet machine and finished on a busy one is a fact about the afternoon, not the code.
    public let machine: [String: String]
    public let appsPresent: [String]
    /// Which redaction contract produced this take. A corpus recorded under an older law must be
    /// re-read knowing that, not silently mixed in.
    public let redactionVersion: Int
    public let taskMarks: [TaskMark]

    public static let currentRedactionVersion = 1

    public init(flow: String, takeID: String, created: Date = Date(), mode: Mode, perturbed: Bool,
                binary: HarnessReport.BinaryStamp, deploySHA: String? = nil, machine: [String: String] = [:],
                appsPresent: [String] = [], redactionVersion: Int = TakeManifest.currentRedactionVersion,
                taskMarks: [TaskMark] = []) {
        self.flow = flow; self.takeID = takeID; self.created = created; self.mode = mode
        self.perturbed = perturbed; self.binary = binary; self.deploySHA = deploySHA
        self.machine = machine; self.appsPresent = appsPresent
        self.redactionVersion = redactionVersion; self.taskMarks = taskMarks
    }
}

/// WHY A RECORDING WAS REFUSED. Enforced in the store rather than in its callers, because a rule
/// restated at every call site is a rule the next call site forgets — the same reasoning that put
/// ADR 0004's retention check inside the writer.
public enum RecordingRefusal: Error, Equatable, CustomStringConvertible {
    case ownWindows
    case hardExcluded(app: String)
    case notWatched(app: String)

    public var description: String {
        switch self {
        case .ownWindows:
            return "refused: Locator's own windows — the engine recording its own output is a hall of mirrors, and it corrupts the record it is trying to make"
        case let .hardExcluded(app):
            return "refused: \(app) is hard-excluded from recording (ADR 0018's watching defaults); a pull may still describe it, but nothing is kept"
        case let .notWatched(app):
            return "refused: \(app) is not Watched — recording is retention, and retention is default-deny (ADR 0004)"
        }
    }
}

/// The take directory: creates it, writes the manifest, and owns the append-only streams.
public struct TakeStore: Sendable {

    /// Never recorded, whatever the allowlist says. Dock and Terminal are retention-only exclusions
    /// (ADR 0004) and a take IS retention; Locator's own windows are refused outright everywhere.
    public static let hardExcluded: Set<String> = ["dock", "terminal", "iterm", "iterm2"]
    public static let ownBundlePrefixes: [String] = ["com.forte.locator", "com.forte.fflow"]

    public let root: URL
    public let manifest: TakeManifest

    /// The streams, named exactly as `.scratch/harness/spec.md` names them.
    public var traceURL: URL   { root.appendingPathComponent("trace.ndjson") }
    public var readsURL: URL   { root.appendingPathComponent("reads.ndjson") }
    public var ingestURL: URL  { root.appendingPathComponent("ingest.ndjson") }
    public var sessionURL: URL { root.appendingPathComponent("session.ndjson") }
    public var eventsURL: URL  { root.appendingPathComponent("events.ndjson") }
    public var keysDir: URL    { root.appendingPathComponent("keys", isDirectory: true) }
    public var brainDir: URL   { root.appendingPathComponent("brain", isDirectory: true) }
    public var manifestURL: URL { root.appendingPathComponent("manifest.json") }

    /// `~/.fflow/harness` — beside the fixtures, under the same privacy rules, never the repo.
    public static func harnessRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fflow/harness", isDirectory: true)
    }

    public static func takeID(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// Refuse before anything is written. Returns nil when recording this app is allowed.
    public static func refusal(forApp app: String, bundleID: String?, watched: Bool) -> RecordingRefusal? {
        if let b = bundleID?.lowercased(), ownBundlePrefixes.contains(where: { b.hasPrefix($0) }) { return .ownWindows }
        let name = app.lowercased()
        if name.contains("locator") { return .ownWindows }
        if hardExcluded.contains(where: { name == $0 || name.hasPrefix($0) }) { return .hardExcluded(app: app) }
        if !watched { return .notWatched(app: app) }
        return nil
    }

    /// Create a take on disk. Throws `RecordingRefusal` before creating anything if any app in the
    /// run is refused — a half-written take of a refused app is still a recording of it.
    public static func create(flow: String, mode: TakeManifest.Mode, binary: HarnessReport.BinaryStamp,
                              apps: [(name: String, bundleID: String?, watched: Bool)],
                              deploySHA: String? = nil, machine: [String: String] = [:],
                              at date: Date = Date(), root overrideRoot: URL? = nil) throws -> TakeStore {
        for a in apps {
            if let r = refusal(forApp: a.name, bundleID: a.bundleID, watched: a.watched) { throw r }
        }
        let id = takeID(at: date)
        let dir = (overrideRoot ?? harnessRoot()).appendingPathComponent(flow, isDirectory: true)
                                                 .appendingPathComponent(id, isDirectory: true)
        let m = TakeManifest(flow: flow, takeID: id, created: date, mode: mode,
                             perturbed: mode == .film, binary: binary, deploySHA: deploySHA,
                             machine: machine, appsPresent: apps.map(\.name))
        let store = TakeStore(root: dir, manifest: m)
        try FileManager.default.createDirectory(at: store.keysDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.brainDir, withIntermediateDirectories: true)
        try store.writeManifest()
        return store
    }

    public func writeManifest() throws {
        try HarnessReport.encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }

    public static func open(_ dir: URL) throws -> TakeStore {
        let m = try HarnessReport.decoder.decode(TakeManifest.self, from: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        return TakeStore(root: dir, manifest: m)
    }

    /// Append one NDJSON record. Opened and closed per append: a take is written across a long run and
    /// must survive the process dying mid-take — a corpus that only exists if the run ends cleanly is
    /// a corpus that vanishes exactly when something interesting happened.
    public func append<T: Encodable>(_ record: T, to url: URL) throws {
        let line = try HarnessReport.compactEncoder.encode(record) + Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    /// Machine facts worth stamping. Load average is read at both ends of a run by the caller.
    public static func machineFacts() -> [String: String] {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        var loads = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loads, 3)
        let modelBytes = model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return ["model": String(decoding: modelBytes, as: UTF8.self),
                "load_start": String(format: "%.2f", loads[0])]
    }
}
