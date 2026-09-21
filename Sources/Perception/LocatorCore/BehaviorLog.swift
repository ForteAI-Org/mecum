import Foundation

/// One observed user action, logged as TEXT (no images) — the raw timeline an LLM mines for workflows.
public struct BehaviorEvent: Codable, Equatable, Sendable {
    public var ts: Date
    public var kind: String           // "click" | "focus"
    public var bundleID: String
    public var app: String
    public var label: String?         // what was clicked (element label); nil for a focus event
    public var pos: [Double]?         // normalized click position within the window

    public init(ts: Date, kind: String, bundleID: String, app: String, label: String? = nil, pos: [Double]? = nil) {
        self.ts = ts; self.kind = kind; self.bundleID = bundleID; self.app = app; self.label = label; self.pos = pos
    }

    /// Compact one-line rendering for the LLM timeline.
    public func line(relativeTo ref: Date? = nil) -> String {
        let t = ISO8601DateFormatter().string(from: ts)
        switch kind {
        case "focus": return "\(t)  ▸ focus \(app)"
        default:      return "\(t)  • click \"\(label ?? "?")\" in \(app)"
        }
    }
}

/// An LLM-labeled (or user-labeled) recurring workflow — a named pattern mined from the behavior timeline.
/// The shareable payoff of behavior analysis; later compilable into a replayable Flow.
public struct Workflow: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var app: String?
    public var summary: String
    public var steps: [String]
    public var created: Date

    public init(id: UUID = UUID(), name: String, app: String? = nil, summary: String, steps: [String], created: Date) {
        self.id = id; self.name = name; self.app = app; self.summary = summary; self.steps = steps; self.created = created
    }
}

/// Append-only behavior timeline (`events.ndjson`, one JSON per line) + the labeled `workflows.json`. Local.
public struct BehaviorStore: Sendable {
    public let directory: URL
    /// The interaction ledger this store dual-writes into. Injected, like `WheelPolarity`'s and
    /// `SceneBuilder`'s, so the SQLite half of ``append`` cannot land somewhere the caller did not choose
    /// — it silently landed in the operator's live memory for 235 test runs.
    private let memory: LocatorMemory
    public init(directory: URL, memory: LocatorMemory = .shared) {
        self.directory = directory
        self.memory = memory
    }

    private var eventsURL: URL { directory.appendingPathComponent("events.ndjson") }
    private var workflowsURL: URL { directory.appendingPathComponent("workflows.json") }

    /// Append one event: the SQLite interaction ledger is primary (queryable, multi-process-safe);
    /// the ndjson stays as the shareable/backup line format.
    public func append(_ event: BehaviorEvent) {
        memory.recordBehavior(event)
        guard let data = try? DescriptorStore.makeCompactEncoder().encode(event),   // single line (NDJSON)
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: eventsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: eventsURL, options: [.atomic])   // first write
        }
    }

    /// The most recent `limit` events (chronological), decoding the NDJSON tail.
    public func recent(_ limit: Int) -> [BehaviorEvent] {
        guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return [] }
        let decoder = DescriptorStore.makeDecoder()
        let events = text.split(separator: "\n").compactMap {
            (try? decoder.decode(BehaviorEvent.self, from: Data($0.utf8)))
        }
        return Array(events.suffix(limit))
    }

    public func loadWorkflows() -> [Workflow] {
        guard let data = try? Data(contentsOf: workflowsURL),
              let ws = try? DescriptorStore.makeDecoder().decode([Workflow].self, from: data) else { return [] }
        return ws
    }

    public func addWorkflow(_ workflow: Workflow) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ws = loadWorkflows()
        ws.append(workflow)
        try DescriptorStore.makeEncoder().encode(ws).write(to: workflowsURL, options: [.atomic])
    }
}
