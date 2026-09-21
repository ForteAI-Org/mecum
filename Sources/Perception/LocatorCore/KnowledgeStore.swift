import Foundation

/// Atomic, per-app persistence for the ambient UI knowledge base. One JSON file per app bundle ID under
/// the knowledge directory (`<bundleID>.json`), encoded with the same stable encoder as descriptors
/// (sorted keys, ISO-8601 millis dates). Local-only; never leaves disk.
public struct KnowledgeStore: Sendable {
    let directory: URL
    public var directoryURL: URL { directory }

    public init(directory: URL) { self.directory = directory }

    private func url(for bundleID: String) -> URL {
        // Bundle IDs are reverse-DNS (com.avid.ProTools) — safe as a filename, but guard separators.
        let safe = bundleID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    /// Load this app's knowledge, or nil if nothing has been observed yet. PENDING (write-behind) changes
    /// made in this process win over the disk copy, so a reader never sees a stale brain between a
    /// mutation and its flush.
    /// Memoized process-wide: decoding was the single biggest describe_scene cost (Pro Tools'
    /// knowledge is 1.6MB and SceneBuilder loads it twice per build — measured 4.3→10.4s decay).
    /// A (mtime, size) stat validates every hit, so a write from ANOTHER locator process is still
    /// picked up; the common in-process loop never re-parses.
    public func load(bundleID: String) throws -> AppKnowledge? {
        if let pending = KnowledgePending.shared.get(directory: directory, bundleID: bundleID) { return pending }
        return try loadFromDisk(bundleID: bundleID)
    }

    func loadFromDisk(bundleID: String) throws -> AppKnowledge? {
        let u = url(for: bundleID)
        guard let (mtime, size) = KnowledgeMemo.stat(u) else { return nil }   // absent file, as before
        if let hit = KnowledgeMemo.shared.get(u.path, mtime: mtime, size: size) { return hit }
        let app = try DescriptorStore.makeDecoder().decode(AppKnowledge.self, from: Data(contentsOf: u))
        KnowledgeMemo.shared.put(u.path, mtime: mtime, size: size, app: app)
        return app
    }

    /// Atomically persist this app's knowledge (temp + rename within the same dir → atomic on APFS), under
    /// an exclusive `flock` on `<dir>/.knowledge.lock` so writers in OTHER processes (a CLI `kb`/`brain`
    /// command beside the serve) cannot interleave. The first save of a day first copies what is on disk
    /// to `.backup/<bundle>.<date>.json` (14 days kept): a bad decay or a stray writer must never be the
    /// LAST copy of a brain again.
    public func save(_ app: AppKnowledge) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeKnowledgeDirFromBackup(directory)
        let data = try DescriptorStore.makeEncoder().encode(app)
        let u = url(for: app.bundleID)
        try Self.withFileLock(in: directory) {
            Self.backupIfNeeded(current: u, bundleID: app.bundleID, in: directory)
            try data.write(to: u, options: [.atomic])
        }
        // Seed the memo with what we just wrote — the next load is a hit, not a 1.6MB parse.
        if let (mtime, size) = KnowledgeMemo.stat(u) {
            KnowledgeMemo.shared.put(u.path, mtime: mtime, size: size, app: app)
        }
    }

    /// Load → change → WRITE-BEHIND. The body runs against this process's pending copy (or the disk copy)
    /// under one serial queue, so concurrent writers in this process never lose each other's changes; the
    /// result is visible to every `load` immediately and reaches disk within ~2 s (`flushDelay`), coalescing
    /// a scroll burst's fifty ingests into one 1–2 MB encode + write instead of fifty. Nothing here touches
    /// the disk, so a caller on the main actor pays a dictionary update, not an atomic file write.
    /// A corrupt file is quarantined (`<bundle>.corrupt-<date>.json`), the newest daily backup is restored
    /// if there is one, and the write proceeds — a writer must never be silently switched off by one bad
    /// row on disk. The body must not call `mutate` itself.
    @discardableResult
    public func mutate<T>(bundleID: String, _ body: (inout AppKnowledge) throws -> T) throws -> T {
        try Self.writeQueue.sync {
            var app = KnowledgePending.shared.get(directory: directory, bundleID: bundleID)
                ?? loadOrRecover(bundleID: bundleID)
                ?? AppKnowledge(bundleID: bundleID)
            let result = try body(&app)
            KnowledgePending.shared.put(directory: directory, bundleID: bundleID, app: app)
            KnowledgePending.shared.scheduleFlush(store: self)
            return result
        }
    }

    /// Write every pending change of this directory to disk now (a CLI command about to exit; tests).
    public func flush() { KnowledgePending.shared.flush(store: self) }
    /// Seconds a pending change may wait before it is written.
    public static let flushDelay: TimeInterval = 2

    func loadOrRecover(bundleID: String) -> AppKnowledge? {
        do { return try loadFromDisk(bundleID: bundleID) }
        catch {
            let u = url(for: bundleID)
            let fm = FileManager.default
            let quarantine = directory.appendingPathComponent("\(u.deletingPathExtension().lastPathComponent).corrupt-\(Self.backupDay.string(from: Date())).json")
            try? fm.removeItem(at: quarantine)
            try? fm.moveItem(at: u, to: quarantine)
            FileHandle.standardError.write(Data("[knowledge] \(bundleID) failed to decode (\(error.localizedDescription)) — quarantined as \(quarantine.lastPathComponent)\n".utf8))
            // Newest daily backup, if any.
            let safe = bundleID.replacingOccurrences(of: "/", with: "_")
            let backups = ((try? fm.contentsOfDirectory(at: directory.appendingPathComponent(".backup"), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(safe + ".") && $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for b in backups {
                if let app = try? DescriptorStore.makeDecoder().decode(AppKnowledge.self, from: Data(contentsOf: b)) {
                    FileHandle.standardError.write(Data("[knowledge] \(bundleID) restored from \(b.lastPathComponent)\n".utf8))
                    return app
                }
            }
            return nil
        }
    }

    private static let writeQueue = DispatchQueue(label: "locator.knowledge.write")

    /// Exclusive cross-process lock for the directory's files. `open` failure proceeds unlocked (and says so
    /// once) rather than losing the write.
    static func withFileLock<T>(in directory: URL, _ body: () throws -> T) throws -> T {
        let lockPath = directory.appendingPathComponent(".knowledge.lock").path
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o600)
        if fd < 0 {
            if !lockWarned.swap(true) { FileHandle.standardError.write(Data("[knowledge] cannot open \(lockPath) — writing unlocked\n".utf8)) }
            return try body()
        }
        _ = flock(fd, LOCK_EX)
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        return try body()
    }
    private static let lockWarned = AtomicFlag()

    private static let backupDay: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static func backupIfNeeded(current: URL, bundleID: String, in directory: URL, now: Date = Date(), keepDays: Int = 14) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: current.path) else { return }
        let dir = directory.appendingPathComponent(".backup")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = bundleID.replacingOccurrences(of: "/", with: "_")
        let target = dir.appendingPathComponent("\(safe).\(backupDay.string(from: now)).json")
        guard !fm.fileExists(atPath: target.path) else { return }
        try? fm.copyItem(at: current, to: target)
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: target.path)   // a copy of an old file is still TODAY's backup
        // Prune this bundle's backups older than `keepDays`.
        let cutoff = now.addingTimeInterval(-Double(keepDays) * 86400)
        for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where f.lastPathComponent.hasPrefix(safe + ".") && f != target {
            if let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m < cutoff {
                try? fm.removeItem(at: f)
            }
        }
    }

    /// Bundle IDs with stored knowledge.
    public func bundleIDs() throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "allowlist.json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}

/// Process-wide memo of parsed AppKnowledge, keyed by file path and validated by (mtime, size).
/// Bounded LRU (16 apps ≈ a few MB worst case) so a watch-everything session can't hoard memory.
/// `@unchecked Sendable` is carried by the NSLock around every entry access.
final class KnowledgeMemo: @unchecked Sendable {
    static let shared = KnowledgeMemo()
    private let lock = NSLock()
    private var entries: [String: (mtime: Date, size: Int, gen: UInt64, app: AppKnowledge)] = [:]
    private var gen: UInt64 = 0
    private let cap = 16

    static func stat(_ u: URL) -> (mtime: Date, size: Int)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path),
              let m = a[.modificationDate] as? Date,
              let s = (a[.size] as? NSNumber)?.intValue else { return nil }
        return (m, s)
    }

    func get(_ path: String, mtime: Date, size: Int) -> AppKnowledge? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[path], e.mtime == mtime, e.size == size else { return nil }
        gen += 1; entries[path]?.gen = gen
        return e.app
    }

    func put(_ path: String, mtime: Date, size: Int, app: AppKnowledge) {
        lock.lock(); defer { lock.unlock() }
        gen += 1
        entries[path] = (mtime, size, gen, app)
        if entries.count > cap, let evict = entries.min(by: { $0.value.gen < $1.value.gen })?.key {
            entries.removeValue(forKey: evict)
        }
    }
}

/// Persistence for the opt-in observation allowlist (`allowlist.json` in the knowledge dir). Default-deny:
/// an absent file means "observe nothing".
public struct AllowlistStore {
    let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var url: URL { directory.appendingPathComponent("allowlist.json") }

    public func load() -> Allowlist {
        guard let data = try? Data(contentsOf: url),
              let a = try? DescriptorStore.makeDecoder().decode(Allowlist.self, from: data) else { return Allowlist() }
        return a
    }

    public func save(_ allowlist: Allowlist) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        excludeKnowledgeDirFromBackup(directory)
        try DescriptorStore.makeEncoder().encode(allowlist).write(to: url, options: [.atomic])
    }
}

/// Keep the knowledge dir (raw UI labels / observed text) OUT of Time Machine backups — the
/// macOS-meaningful at-rest mitigation for the ambient store. (NSFileProtection is an iOS no-op on macOS;
/// full app-level CryptoKit encryption is a separate, later task that would change the on-disk format.)
/// Best-effort + idempotent: a filesystem that doesn't support the flag just leaves it unset.
func excludeKnowledgeDirFromBackup(_ directory: URL) {
    var url = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
}

/// A tiny lock-free boolean for one-time warnings.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func swap(_ new: Bool) -> Bool { lock.lock(); defer { lock.unlock() }; let old = value; value = new; return old }
}

/// The WRITE-BEHIND overlay: pending `AppKnowledge` per (directory, bundle), visible to every `load` in
/// this process at once and flushed to disk after `KnowledgeStore.flushDelay` (coalesced) or at exit.
/// `@unchecked Sendable` is carried by the NSLock around every access.
final class KnowledgePending: @unchecked Sendable {
    static let shared = KnowledgePending()
    private let lock = NSLock()
    private var pending: [String: AppKnowledge] = [:]          // key: "<dir>|<bundle>"
    private var dirty = Set<String>()
    private var flushScheduled = Set<String>()                  // per directory path
    private init() { atexit { KnowledgePending.shared.flushAll() } }

    private func key(_ d: URL, _ b: String) -> String { d.path + "|" + b }

    func get(directory: URL, bundleID: String) -> AppKnowledge? {
        lock.lock(); defer { lock.unlock() }
        return pending[key(directory, bundleID)]
    }
    func put(directory: URL, bundleID: String, app: AppKnowledge) {
        lock.lock(); defer { lock.unlock() }
        let k = key(directory, bundleID)
        pending[k] = app; dirty.insert(k)
    }
    func scheduleFlush(store: KnowledgeStore) {
        lock.lock()
        let path = store.directoryURL.path
        let already = flushScheduled.contains(path)
        if !already { flushScheduled.insert(path) }
        lock.unlock()
        guard !already else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + KnowledgeStore.flushDelay) { [self] in
            self.flush(store: store)
        }
    }
    /// Write this directory's dirty entries. Entries stay in the overlay as clean copies (the memo is seeded
    /// by `save`, so a later load is a hit either way).
    func flush(store: KnowledgeStore) {
        lock.lock()
        let path = store.directoryURL.path
        flushScheduled.remove(path)
        let toWrite = dirty.filter { $0.hasPrefix(path + "|") }.compactMap { k in pending[k].map { (k, $0) } }
        for (k, _) in toWrite { dirty.remove(k) }
        lock.unlock()
        for (k, app) in toWrite {
            do { try store.save(app) }
            catch {
                lock.lock(); dirty.insert(k); lock.unlock()   // try again next flush
                FileHandle.standardError.write(Data("[knowledge] could not write \(app.bundleID): \(error.localizedDescription)\n".utf8))
            }
        }
    }
    func flushAll() {
        lock.lock()
        let dirs = Set(dirty.map { String($0.split(separator: "|", maxSplits: 1).first ?? "") })
        lock.unlock()
        for d in dirs where !d.isEmpty { flush(store: KnowledgeStore(directory: URL(fileURLWithPath: d))) }
    }
}
