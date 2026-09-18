//
//  FileKnowledgeStore.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
import Memory

/// FileKnowledgeStore is `KnowledgeStoring` over one JSON file per application in a directory,
/// written with the stable knowledge coders. Local only; nothing leaves the disk.
///
/// Mutations are write-behind: the change is visible to every load at once and reaches disk after
/// `flushDelay`, so a scroll burst's fifty ingests become one encode and write. A save takes an
/// exclusive file lock on the directory so a writer in another process cannot interleave, and the
/// first save of a day first copies the file on disk into `.backup`, kept for `keepBackupDays`, so a
/// bad decay or a stray writer is never the last copy of a brain. A corrupt file is quarantined and
/// the newest backup restored, so one bad row never silently switches a writer off. Actor isolation
/// is the serialization the role asks for; the flush task hops back into it.
public actor FileKnowledgeStore: KnowledgeStoring {

    public let directory: URL

    private let clock: @Sendable () -> Date
    private let flushDelay: Duration
    private let keepBackupDays: Int
    private let diagnostics: @Sendable (String) -> Void
    private var pending: [String: AppKnowledge] = [:]
    private var dirty: Set<String> = []
    private var memo: [String: MemoEntry] = [:]
    private var memoGeneration: UInt64 = 0
    private var flushTask: Task<Void, Never>?

    private struct MemoEntry {
        var modified: Date
        var size: Int
        var generation: UInt64
        var knowledge: AppKnowledge
    }

    /// The memo holds at most this many parsed applications.
    private static let memoCapacity = 16

    /// - Parameters:
    ///   - directory: where `<bundleID>.json` files live; created on the first save.
    ///   - clock: the time for backups and pending stamps.
    ///   - flushDelay: how long a mutation may wait before it is written.
    ///   - keepBackupDays: how many days of daily backups to keep per application.
    ///   - diagnostics: receives one line per recovery event, such as a quarantine or a restore.
    public init(
        directory     : URL,
        clock         : @escaping @Sendable () -> Date,
        flushDelay    : Duration = .seconds(2),
        keepBackupDays: Int = 14,
        diagnostics   : @escaping @Sendable (String) -> Void
    ) {
        self.directory      = directory
        self.clock          = clock
        self.flushDelay     = flushDelay
        self.keepBackupDays = keepBackupDays
        self.diagnostics    = diagnostics
    }

    // MARK: KnowledgeStoring

    public func load(bundleID: String) throws -> AppKnowledge? {
        if let pending = pending[bundleID] { return pending }
        return try loadFromDisk(bundleID: bundleID)
    }

    public func save(_ knowledge: AppKnowledge) throws {
        try write(knowledge)
        pending[knowledge.bundleID] = knowledge
        dirty.remove(knowledge.bundleID)
    }

    public func mutate<T: Sendable>(
        bundleID: String,
        _ body  : @Sendable (inout AppKnowledge) throws -> T
    ) throws -> T {
        var knowledge = try pending[bundleID] ?? loadOrRecover(bundleID: bundleID) ?? AppKnowledge(bundleID: bundleID)
        let result = try body(&knowledge)
        pending[bundleID] = knowledge
        dirty.insert(bundleID)
        scheduleFlush()
        return result
    }

    public func bundleIDs() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != FileAllowlistStore.fileName }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    // MARK: Flushing

    /// Writes every pending change now. A write that fails stays dirty for the next flush.
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        for bundleID in dirty.sorted() {
            guard let knowledge = pending[bundleID] else {
                dirty.remove(bundleID)
                continue
            }
            do {
                try write(knowledge)
                dirty.remove(bundleID)
            } catch {
                diagnostics("[knowledge] could not write \(bundleID): \(error.localizedDescription)")
            }
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [flushDelay] in
            try? await Task.sleep(for: flushDelay)
            guard !Task.isCancelled else { return }
            await self.flushFromTask()
        }
    }

    private func flushFromTask() {
        flushTask = nil
        flush()
    }

    // MARK: Disk

    private func url(for bundleID: String) -> URL {
        directory.appendingPathComponent("\(Self.safeName(bundleID)).json")
    }

    private static func safeName(_ bundleID: String) -> String {
        bundleID.replacingOccurrences(of: "/", with: "_")
    }

    private func loadFromDisk(bundleID: String) throws -> AppKnowledge? {
        let file = url(for: bundleID)
        guard let stat = Self.stat(file) else { return nil }
        if let hit = memo[file.path], hit.modified == stat.modified, hit.size == stat.size {
            memoGeneration += 1
            memo[file.path]?.generation = memoGeneration
            return hit.knowledge
        }
        let knowledge = try KnowledgeCoding.makeDecoder().decode(AppKnowledge.self, from: Data(contentsOf: file))
        remember(knowledge, at: file, stat: stat)
        return knowledge
    }

    private func remember(_ knowledge: AppKnowledge, at file: URL, stat: (modified: Date, size: Int)) {
        memoGeneration += 1
        memo[file.path] = MemoEntry(modified: stat.modified, size: stat.size, generation: memoGeneration,
                                    knowledge: knowledge)
        if memo.count > Self.memoCapacity, let oldest = memo.min(by: { $0.value.generation < $1.value.generation }) {
            memo.removeValue(forKey: oldest.key)
        }
    }

    private static func stat(_ file: URL) -> (modified: Date, size: Int)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        return (modified, size)
    }

    /// Encodes and writes atomically under the directory lock, taking the day's backup first.
    private func write(_ knowledge: AppKnowledge) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
        let data = try KnowledgeCoding.makeEncoder().encode(knowledge)
        let file = url(for: knowledge.bundleID)
        let now = clock()
        try Self.withFileLock(in: directory, diagnostics: diagnostics) {
            Self.backupIfNeeded(current: file, bundleID: knowledge.bundleID, in: directory, now: now,
                                keepDays: keepBackupDays)
            try data.write(to: file, options: [.atomic])
        }
        if let stat = Self.stat(file) { remember(knowledge, at: file, stat: stat) }
    }

    /// Loads from disk, or quarantines a file that does not decode and restores the newest backup.
    /// Returns nil when there is nothing on disk and nothing to restore.
    private func loadOrRecover(bundleID: String) throws -> AppKnowledge? {
        do {
            return try loadFromDisk(bundleID: bundleID)
        } catch {
            let file = url(for: bundleID)
            let manager = FileManager.default
            let day = Self.dayFormatter.string(from: clock())
            let quarantine = directory.appendingPathComponent("\(Self.safeName(bundleID)).corrupt-\(day).json")
            try? manager.removeItem(at: quarantine)
            try manager.moveItem(at: file, to: quarantine)
            memo.removeValue(forKey: file.path)
            diagnostics("[knowledge] \(bundleID) failed to decode (\(error.localizedDescription)), "
                + "quarantined as \(quarantine.lastPathComponent)")
            let decoder = KnowledgeCoding.makeDecoder()
            for backup in Self.backups(of: bundleID, in: directory) {
                // A backup that does not decode either is skipped for the next older one.
                guard let data = try? Data(contentsOf: backup),
                      let restored = try? decoder.decode(AppKnowledge.self, from: data) else { continue }
                diagnostics("[knowledge] \(bundleID) restored from \(backup.lastPathComponent)")
                return restored
            }
            return nil
        }
    }

    // MARK: Backups

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone   = TimeZone(identifier: "UTC")
        formatter.locale     = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Copies the current file to `.backup/<bundle>.<day>.json` once per day, then prunes that
    /// application's backups older than `keepDays`. A copy of an old file is still today's backup, so
    /// its modification date is set to now.
    static func backupIfNeeded(current: URL, bundleID: String, in directory: URL, now: Date, keepDays: Int) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: current.path) else { return }
        let backupDirectory = directory.appendingPathComponent(".backup")
        try? manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let prefix = safeName(bundleID) + "."
        let target = backupDirectory.appendingPathComponent("\(prefix)\(dayFormatter.string(from: now)).json")
        guard !manager.fileExists(atPath: target.path) else { return }
        try? manager.copyItem(at: current, to: target)
        try? manager.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let contents = (try? manager.contentsOfDirectory(at: backupDirectory,
                                                         includingPropertiesForKeys: Array(keys))) ?? []
        for file in contents where file.lastPathComponent.hasPrefix(prefix) && file != target {
            let modified = (try? file.resourceValues(forKeys: keys))?.contentModificationDate
            if let modified, modified < cutoff { try? manager.removeItem(at: file) }
        }
    }

    /// This application's backups, newest first by name (the day is in the name).
    private static func backups(of bundleID: String, in directory: URL) -> [URL] {
        let backupDirectory = directory.appendingPathComponent(".backup")
        let manager = FileManager.default
        let contents = (try? manager.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)) ?? []
        let prefix = safeName(bundleID) + "."
        return contents
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: The directory

    /// Runs the body under an exclusive lock on `.knowledge.lock`, so writers in other processes cannot
    /// interleave. A lock that cannot be opened is reported once per call and the body runs unlocked,
    /// because losing the write is worse than an unlocked write.
    private static func withFileLock<T>(
        in directory: URL,
        diagnostics : (String) -> Void,
        _ body      : () throws -> T
    ) throws -> T {
        let lockPath = directory.appendingPathComponent(".knowledge.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o600)
        if descriptor < 0 {
            diagnostics("[knowledge] cannot open \(lockPath), writing unlocked")
            return try body()
        }
        _ = flock(descriptor, LOCK_EX)
        defer {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        return try body()
    }

    /// Keeps the directory (raw UI labels) out of Time Machine. Best effort and idempotent.
    static func excludeFromBackup(_ directory: URL) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
