import Foundation
import CryptoKit

/// THE HARNESS REPORT — the artifact the whole measuring effort exists to produce, and the only thing
/// that leaves `~/.fflow`. Takes are raw pixels of the user's real screen and stay private; a report
/// carries numbers (and at most the user's own phrase), so it lands in the repo where it can be diffed
/// across days.
///
/// Two refusals live here rather than in the callers, because a rule restated at every call site is a
/// rule a new call site skips:
///   • **STALE** — a report whose binary is older than `Sources/` is not evidence. `check-fixtures.sh`
///     already makes this check for the same reason: a stale binary once sailed through it, and a live
///     acceptance was once declared against a deploy 34 minutes older than the feature it proved.
///   • **PERTURBED** — a `--film` take changes the cost profile it is measuring (ADR 0010), so it may
///     answer a pixel question but may never enter a baseline percentile.
public struct HarnessReport: Codable, Sendable, Equatable {

    /// Which plane produced this. The planes answer different questions and only one of them gates
    /// (ADR 0011): `replay` is the deterministic offline gate, `probe` is a live milestone, `session`
    /// is the headline and is never deterministic.
    public enum Plane: String, Codable, Sendable { case replay, probe, session, sweep }

    /// One measured number. `p50`/`p95` are present for latency-shaped metrics and nil for shares and
    /// counts; `n` is the sample size, because a p95 over 4 reads is not a p95 and the diff says so.
    public struct Metric: Codable, Sendable, Equatable {
        public let value: Double?
        public let p50: Double?
        public let p95: Double?
        public let unit: String
        public let n: Int
        public init(value: Double? = nil, p50: Double? = nil, p95: Double? = nil, unit: String, n: Int) {
            self.value = value; self.p50 = p50; self.p95 = p95; self.unit = unit; self.n = n
        }
        /// The number a diff compares. p95 is the gate's shape, so it wins when present.
        public var headline: Double? { p95 ?? value ?? p50 }
    }

    /// What the binary was when this was measured. A number is only as fresh as the code that produced it.
    public struct BinaryStamp: Codable, Sendable, Equatable {
        public let sha256: String
        public let mtime: Date
        /// The newest mtime under `Sources/` at report time, when it could be read. Nil outside a checkout.
        public let sourcesNewest: Date?
        public init(sha256: String, mtime: Date, sourcesNewest: Date?) {
            self.sha256 = sha256; self.mtime = mtime; self.sourcesNewest = sourcesNewest
        }
        /// STALE: source changed after the binary was built, so this report measures code nobody is running.
        public var isStale: Bool {
            guard let newest = sourcesNewest else { return false }
            return newest > mtime
        }
    }

    public let plane: Plane
    public let created: Date
    public let takes: [String]
    public let binary: BinaryStamp
    /// True when any take in this report was recorded with `--film` (ADR 0010).
    public let perturbed: Bool
    /// Machine state at measurement. A p95 taken on a shared tree at load 13 is a fact about the
    /// afternoon, which is exactly why the live probe is a milestone and never a gate (ADR 0011).
    public let machine: [String: String]
    public let metrics: [String: Metric]

    public init(plane: Plane, created: Date = Date(), takes: [String], binary: BinaryStamp,
                perturbed: Bool, machine: [String: String] = [:], metrics: [String: Metric]) {
        self.plane = plane; self.created = created; self.takes = takes; self.binary = binary
        self.perturbed = perturbed; self.machine = machine; self.metrics = metrics
    }

    // MARK: admission

    /// Why this report may not become (or join) a baseline — nil when it may.
    ///
    /// Both reasons are refusals rather than warnings on purpose. A warning is a thing a tired person
    /// clicks past at 2am, and the whole point of the freeze rule (ADR 0011) is that the numbers cannot
    /// be talked into being better than they are.
    public var baselineRefusal: String? {
        if perturbed {
            return "perturbed: true — recorded with --film, which changes the cost profile it measures (ADR 0010); it answers pixel questions, never percentiles"
        }
        if binary.isStale {
            return "STALE — Sources/ is newer than the binary that produced this report; rebuild and re-measure"
        }
        if plane == .probe {
            return "plane: probe — a live measurement is a milestone, never a gate (ADR 0011); the gate is the offline replay's compute_ms"
        }
        return nil
    }

    // MARK: stamping

    /// Stamp the binary at `binaryPath` against the checkout at `repoRoot`.
    public static func stamp(binaryPath: URL, repoRoot: URL?) -> BinaryStamp {
        let attrs = try? FileManager.default.attributesOfItem(atPath: binaryPath.path)
        let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
        var sha = "unknown"
        if let data = try? Data(contentsOf: binaryPath, options: .mappedIfSafe) {
            sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return BinaryStamp(sha256: sha, mtime: mtime, sourcesNewest: repoRoot.flatMap(newestMTime(under:)))
    }

    /// Newest modification time under `Sources/`. Walks files only; a directory's mtime changes for
    /// reasons that are not source edits (a `.DS_Store`, an editor's swap file appearing and vanishing).
    public static func newestMTime(under repoRoot: URL) -> Date? {
        let sources = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        guard let e = FileManager.default.enumerator(at: sources,
                                                     includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return nil }
        var newest: Date?
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true, let m = v.contentModificationDate else { continue }
            if newest == nil || m > newest! { newest = m }
        }
        return newest
    }

    // MARK: io

    /// ISO8601 **with fractional seconds**, both ways. Foundation's stock `.iso8601` truncates to whole
    /// seconds, which silently loses the millisecond a trace is made of: at 10 fps every frame in a
    /// tenth of a second collapses onto one timestamp, and the settle latency the corpus exists to
    /// measure becomes unrecoverable. Caught by a round-trip test whose two sides printed identically.
    /// TIMESTAMPS ARE MILLISECOND-PRECISION, deliberately. `Date` holds sub-millisecond precision that
    /// no fixed-precision text format round-trips exactly, and the alternative — writing raw epoch
    /// doubles — would make a corpus a human has to read unreadable. A millisecond is far finer than
    /// anything measured here: frames arrive every 100 ms at 10 fps and latencies are tens of ms. So the
    /// guarantee is a FIXED POINT (re-reading and re-writing a take changes nothing), not bit equality
    /// with an in-memory `Date`.
    ///
    /// One formatter per encoder/decoder instance, captured by its own strategy closure — a shared
    /// `static let` is not `Sendable` under strict concurrency, and a per-*date* formatter would cost
    /// an allocation for every frame in a 10 fps trace. A hot recorder should hoist the encoder itself
    /// rather than reach for `compactEncoder` per record.
    static func makeISO8601ms() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static func applyDateStrategy(_ e: JSONEncoder) {
        // Built per call: ISO8601DateFormatter is not Sendable and the strategy closure is.
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(makeISO8601ms().string(from: date))
        }
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        applyDateStrategy(e)
        e.outputFormatting = [.prettyPrinted, .sortedKeys]   // sorted: a report diffs as text too
        return e
    }
    /// NDJSON is ONE RECORD PER LINE, so the stream encoder must never pretty-print — a newline
    /// inside a record silently turns one row into several unparseable ones.
    static var compactEncoder: JSONEncoder {
        let e = JSONEncoder()
        applyDateStrategy(e)
        e.outputFormatting = [.sortedKeys]
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = makeISO8601ms().date(from: s) else {
                throw DecodingError.dataCorruptedError(in: try dec.singleValueContainer(),
                                                       debugDescription: "not an ISO8601 timestamp with fractional seconds: \(s)")
            }
            return date
        }
        return d
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }
    public static func read(_ url: URL) throws -> HarnessReport {
        try decoder.decode(HarnessReport.self, from: Data(contentsOf: url))
    }
}

/// THE SAME-DAY JUDGMENT — what moved between two reports. Ticket 02's rule is that a change which
/// cannot be judged by a number the same day is not done; this is the number.
public struct ReportDiff: Sendable, Equatable {

    public struct Row: Sendable, Equatable {
        public let metric: String
        public let before: Double?
        public let after: Double?
        public let unit: String
        /// Sample sizes, so a "regression" measured over 3 reads announces itself as one.
        public let nBefore: Int
        public let nAfter: Int

        public var delta: Double? {
            guard let b = before, let a = after else { return nil }
            return a - b
        }
        public var pctChange: Double? {
            guard let b = before, let a = after, b != 0 else { return nil }
            return (a - b) / b * 100
        }
        /// Present in one report and not the other — a metric appearing or disappearing is itself news.
        public var isOneSided: Bool { before == nil || after == nil }
    }

    public let rows: [Row]
    public let notes: [String]

    /// Metrics whose headline moved by more than `threshold` percent, worst first.
    public func moved(threshold: Double = 0.0) -> [Row] {
        rows.filter { r in
            if r.isOneSided { return true }
            guard let p = r.pctChange else { return false }
            return abs(p) > threshold
        }.sorted { (abs($0.pctChange ?? .infinity)) > (abs($1.pctChange ?? .infinity)) }
    }

    public static func between(_ a: HarnessReport, _ b: HarnessReport) -> ReportDiff {
        var notes: [String] = []
        if a.plane != b.plane {
            notes.append("planes differ (\(a.plane.rawValue) vs \(b.plane.rawValue)) — these answer different questions and their numbers are not comparable")
        }
        if let r = a.baselineRefusal { notes.append("before: \(r)") }
        if let r = b.baselineRefusal { notes.append("after: \(r)") }
        if a.binary.sha256 == b.binary.sha256 && a.binary.sha256 != "unknown" {
            notes.append("same binary sha — any movement here is the machine or the corpus, not the code")
        }
        let keys = Set(a.metrics.keys).union(b.metrics.keys).sorted()
        let rows = keys.map { k -> Row in
            let x = a.metrics[k], y = b.metrics[k]
            return Row(metric: k, before: x?.headline, after: y?.headline,
                       unit: y?.unit ?? x?.unit ?? "", nBefore: x?.n ?? 0, nAfter: y?.n ?? 0)
        }
        return ReportDiff(rows: rows, notes: notes)
    }

    /// A table a human reads at a glance. Markdown, because reports live in the repo beside the map.
    public func markdownTable() -> String {
        var out = "| metric | before | after | Δ | % | n |\n|---|---:|---:|---:|---:|---:|\n"
        let f = { (d: Double?) -> String in d.map { String(format: "%.3g", $0) } ?? "—" }
        for r in moved() {
            let pct = r.pctChange.map { String(format: "%+.1f%%", $0) } ?? "—"
            out += "| `\(r.metric)` | \(f(r.before)) | \(f(r.after)) \(r.unit) | \(f(r.delta)) | \(pct) | \(r.nBefore)→\(r.nAfter) |\n"
        }
        if moved().isEmpty { out += "| _(nothing moved)_ | | | | | |\n" }
        for n in notes { out += "\n> ⚠︎ \(n)\n" }
        return out
    }
}
