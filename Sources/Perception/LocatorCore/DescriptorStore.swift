import Foundation

/// Errors thrown by the descriptor / crop stores.
public enum StoreError: Error, Equatable {
    case notFound(UUID)
    case noPriorVersion(UUID)
    case corruptFilename(String)
    /// A descriptor on disk declares a schema newer than this build understands.
    case unsupportedSchemaVersion(found: Int, supported: Int)
}

/// On-disk descriptor store: one `<uuid>.json` per descriptor, written atomically, with a bounded
/// history of prior versions so a bad self-heal can be rolled back.
///
/// Crops (`<uuid>.<state>.png`, `<uuid>.context.png`) live alongside the JSON in the same directory
/// and are managed by ``CropStore``; ``delete(id:)`` cleans them up too.
public struct DescriptorStore: Sendable {
    public let directory: URL
    /// How many prior versions to retain per descriptor (oldest pruned first).
    public let maxVersions: Int

    private var versionsRoot: URL { directory.appendingPathComponent("versions", isDirectory: true) }
    private func canonicalURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    private func archiveDir(_ id: UUID) -> URL { versionsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }

    public init(directory: URL, maxVersions: Int = 5) {
        self.directory = directory
        self.maxVersions = maxVersions
    }

    // MARK: Encoder/decoder (created per call so the store stays a Sendable value type)

    // ISO-8601 *with fractional seconds* (millisecond precision): human-readable + diff-friendly,
    // and — unlike the stock `.iso8601` strategy, which truncates to whole seconds — exact round-trip
    // for millisecond-quantized timestamps (produce them via `LocatorTime.now()`). The formatter is
    // built inside each closure (not captured) so the closures stay trivially Sendable under Swift 6.
    private static func iso8601WithMillis() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    /// Stable, diff-friendly encoding: sorted keys + millisecond ISO-8601 dates.
    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(iso8601WithMillis().string(from: date))
        }
        return e
    }

    /// Like `makeEncoder` but SINGLE-LINE (no pretty-printing) — for NDJSON logs (one JSON object per line).
    public static func makeCompactEncoder() -> JSONEncoder {
        let e = makeEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = iso8601WithMillis().date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO-8601 date: \(s)")
            }
            return date
        }
        return d
    }

    // MARK: CRUD

    /// Atomically persist a descriptor. If one already exists for this id, the existing file is
    /// archived to the bounded version history before being overwritten.
    public func save(_ descriptor: Descriptor) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = canonicalURL(descriptor.id)

        // Encode FIRST: an encode failure (e.g. a non-finite coordinate) must abort before any
        // archive side effect, so the bounded history can't gain a spurious/duplicate entry.
        let data = try Self.makeEncoder().encode(descriptor)

        // Archive the existing canonical so a bad self-heal can be rolled back. Skip archiving ONLY
        // when the file is genuinely absent — a present-but-unreadable file must surface as an error,
        // never be silently overwritten (which would destroy the rollback safety net).
        if FileManager.default.fileExists(atPath: dest.path) {
            let existing = try Data(contentsOf: dest)
            try archive(existing, id: descriptor.id)
        }

        // .atomic writes to an auxiliary file in the SAME directory and renames → atomic on APFS.
        try data.write(to: dest, options: [.atomic])
    }

    public func load(id: UUID) throws -> Descriptor {
        let url = canonicalURL(id)
        guard let data = try? Data(contentsOf: url) else { throw StoreError.notFound(id) }
        return try Self.makeDecoder().decode(Descriptor.self, from: data)
    }

    /// All descriptor ids present, sorted by UUID string for deterministic output. Ignores anything
    /// that is not a `<uuid>.json` file (stray temp/partial writes, the `versions/` dir, crops, …).
    public func list() throws -> [UUID] {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        } catch CocoaError.fileReadNoSuchFile {
            return []   // store directory not created yet → genuinely no descriptors
        }
        return entries
            // Only real files (a directory literally named "<uuid>.json" would otherwise be reported
            // as an id that load() then can't read).
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
            .filter { $0.pathExtension == "json" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// Remove the descriptor, its version history, and its crops.
    public func delete(id: UUID) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: canonicalURL(id))
        try? fm.removeItem(at: archiveDir(id))
        // Best-effort crop cleanup: anything named "<uuid>.*.png" in the same directory.
        if let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in entries where url.pathExtension == "png" && url.lastPathComponent.hasPrefix("\(id.uuidString).") {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: Version history / rollback

    /// Newest → oldest archived versions for a descriptor (excludes the current canonical file).
    public func archivedVersions(id: UUID) throws -> [Descriptor] {
        let dec = Self.makeDecoder()
        return archiveIndices(id: id)
            .reversed()
            .compactMap { idx in
                (try? Data(contentsOf: archiveDir(id).appendingPathComponent("\(idx).json")))
                    .flatMap { try? dec.decode(Descriptor.self, from: $0) }
            }
    }

    /// Restore the most recent archived version as the canonical descriptor, consuming it from the
    /// history (so successive rollbacks walk further back). Throws if there is no prior version.
    @discardableResult
    public func rollback(id: UUID) throws -> Descriptor {
        let dec = Self.makeDecoder()
        // Walk newest → oldest, discarding any archive that can't be read/decoded so a single corrupt
        // entry can't permanently block access to the older valid versions behind it.
        for idx in archiveIndices(id: id).reversed() {
            let archiveURL = archiveDir(id).appendingPathComponent("\(idx).json")
            guard let data = try? Data(contentsOf: archiveURL),
                  let descriptor = try? dec.decode(Descriptor.self, from: data) else {
                try? FileManager.default.removeItem(at: archiveURL)  // drop the poison pill
                continue
            }
            try data.write(to: canonicalURL(id), options: [.atomic])
            // Propagating remove → consume the archive exactly once (no silent double-consume).
            try FileManager.default.removeItem(at: archiveURL)
            return descriptor
        }
        throw StoreError.noPriorVersion(id)
    }

    // MARK: Internals

    private func archive(_ data: Data, id: UUID) throws {
        let dir = archiveDir(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let next = (archiveIndices(id: id).last ?? 0) + 1
        try data.write(to: dir.appendingPathComponent("\(next).json"), options: [.atomic])
        prune(id: id)
    }

    /// Existing archive indices, ascending (oldest → newest).
    private func archiveIndices(id: UUID) -> [Int] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: archiveDir(id), includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { Int($0.deletingPathExtension().lastPathComponent) }
            .sorted()
    }

    private func prune(id: UUID) {
        let indices = archiveIndices(id: id)
        guard indices.count > maxVersions else { return }
        let fm = FileManager.default
        for idx in indices.prefix(indices.count - maxVersions) {
            try? fm.removeItem(at: archiveDir(id).appendingPathComponent("\(idx).json"))
        }
    }
}
