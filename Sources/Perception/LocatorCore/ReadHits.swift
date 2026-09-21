import Foundation

/// The five memories, plus the two ledgers, as ACCOUNTING KEYS — one per table the living memory answers
/// questions from. The raw values are the table names, because the number they carry ("scroll_pane was
/// consulted 812 times, 47 of them decisive") is only meaningful next to the rows it is about.
public enum MemoryStore: String, CaseIterable, Sendable {
    case sighting
    case scrollPane = "scroll_pane"
    case wheelPolarity = "wheel_polarity"
    case experience
    case sectionMember = "section_member"
    case sectionList = "section_list"
    case interaction
    /// The UI BRAIN — the one memory that is not a `locator.db` table but a per-app JSON store
    /// (`knowledge/<bundle>.json`, 10,340 anchors). Its accounting lands in the same ledger because the
    /// question the ledger answers ("which memories are worth their rows?") is the same question.
    case brain
}

/// One (store, app) pair's accounting, as the memory view reads it.
public struct ReadHit: Sendable {
    /// The table, as `MemoryStore.rawValue` — a String rather than the enum so a ledger written by a
    /// NEWER engine (one more store than this binary knows) still renders instead of vanishing.
    public let store: String
    /// The bundle id the question was about, or `*` for a store nothing scopes by app (experience, the
    /// interaction ledger, the cross-graph sighting map).
    public let app: String
    public let consulted: Int
    public let useful: Int
    public let last: Date
}

/// READ-HIT ACCOUNTING, buffered. Every store counted its writes and none counted its reads, so no
/// prune-or-keep argument about the memory could cite anything but taste (the learning audit's fifth
/// finding). Two numbers per (store, app): how often the memory was CONSULTED, and how often that
/// consultation CHANGED WHAT THE ENGINE DID.
///
/// Buffered because the natural implementation is a tax: a single `reach` consults the ledger ~30 times
/// (per-candidate pane truth, the sighting, the sibling seed, pitch and px-per-tick), and one WAL commit
/// per consultation would put writes on the scene path this project spends its time removing. Deltas
/// accumulate here and are handed over as ONE batch per `interval`, so the cost is a dictionary bump per
/// read and a handful of upserts per second.
///
/// `on` is the env gate (`LOCATOR_READ_HITS`), read once — the same shape as `StageTimer`'s
/// `LOCATOR_TIMING`: when it is off, every call returns before it allocates anything.
final class ReadHitLedger: @unchecked Sendable {
    /// One (store, app) row's pending delta.
    struct Delta: Sendable {
        let store: String
        let app: String
        let consulted: Int
        let useful: Int
    }

    private struct Key: Hashable { let store: String; let app: String }

    let on: Bool
    private let interval: Double
    private let lock = NSLock()
    private var pending: [Key: (consulted: Int, useful: Int)] = [:]
    private var lastHandover: Date

    init(on: Bool, interval: Double = 1.0, now: Date = Date()) {
        self.on = on
        self.interval = interval
        self.lastHandover = now
    }

    /// Book one consultation (and, when `useful`, one outcome it changed). Returns a batch to WRITE when
    /// the interval has elapsed — the caller owns the SQL, so no database work ever happens under this
    /// lock. `nil` means "still buffering", which is the common case by construction.
    func note(store: MemoryStore, app: String?, useful: Bool, now: Date = Date()) -> [Delta]? {
        guard on else { return nil }
        lock.lock(); defer { lock.unlock() }
        let key = Key(store: store.rawValue, app: app ?? LocatorMemory.anyApp)
        var counts = pending[key] ?? (0, 0)
        // A useful read is a CLAIM ABOUT A READ THAT WAS ALREADY COUNTED (the read method counted it as
        // it happened), so this never adds a consultation of its own — that is what keeps `useful` a
        // subset and the ratio honest.
        if useful { counts.useful += 1 } else { counts.consulted += 1 }
        pending[key] = counts
        guard now.timeIntervalSince(lastHandover) >= interval else { return nil }
        return takeLocked(now: now)
    }

    /// Hand over everything buffered right now (process exit, an explicit flush, a test).
    func drain(now: Date = Date()) -> [Delta] {
        lock.lock(); defer { lock.unlock() }
        return takeLocked(now: now)
    }

    private func takeLocked(now: Date) -> [Delta] {
        lastHandover = now
        guard !pending.isEmpty else { return [] }
        let batch = pending.map { Delta(store: $0.key.store, app: $0.key.app,
                                        consulted: $0.value.consulted, useful: $0.value.useful) }
        pending.removeAll(keepingCapacity: true)
        return batch
    }
}
