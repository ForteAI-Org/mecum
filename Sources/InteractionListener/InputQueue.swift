import Dispatch
import Synchronization

/// InputQueue is the preallocated single-producer single-consumer ring between the tap thread and the
/// consumer thread. The producer never waits. Short of room it degrades in order: it keeps the last
/// hover, aggregates compatible scrolls, keeps clicks and focus in capacity reserved for them and, once
/// that is full too, owes a gap record published as soon as a slot frees. Nothing is dropped uncounted.
///
/// A sequence is assigned when a record is published or declared lost, never when it is coalesced, so
/// the consumer sees contiguous numbers: each is a delivered record or inside a gap. Nothing is published
/// while a gap is owed. A held hover or scroll may follow critical records that arrived after it; its own
/// timestamps and revisions stay true.
///
/// Head and tail live 128 bytes apart, one Apple Silicon cache line each, in memory aligned to 128.
/// Records are ordered by release stores and acquire loads of those indices. Wakeups are edge triggered:
/// the producer signals only after publishing into a ring the consumer had emptied, and a sequentially
/// consistent fence on both sides closes the race with a consumer going to sleep. Producer calls come
/// from one thread until `close()`; after it the consumer finishes the producer's leftovers itself.
final class InputQueue: @unchecked Sendable {
    /// One word per index, grouped so each 128-byte line has a single writer.
    private enum Word: Int {
        case head = 0, cachedTail, nextSequence
        case tail = 16, cachedHead
        case closed = 32, spaceWanted, coalescedHovers, aggregatedScrolls, lostCritical, lostCoalescible, gaps

        static let count = 48
    }

    let capacity: Int
    let reserved: Int
    private let mask: Int
    private let slots: UnsafeMutablePointer<InputRecord>
    private let words: UnsafeMutablePointer<Atomic<Int>>
    private let dataReady = DispatchSemaphore(value: 0)
    // Producer only, and touched only while the ring is short of room.
    private var held: InputRecord?
    private var owedGap: InputRecord?

    init(capacity: Int, reserved: Int) {
        precondition(capacity > 1 && capacity & (capacity - 1) == 0, "capacity must be a power of two")
        precondition(reserved > 0 && reserved < capacity, "reserved capacity must leave room for coalescible input")
        self.capacity = capacity
        self.reserved = reserved
        mask = capacity - 1
        slots = .allocate(capacity: capacity)
        slots.initialize(repeating: InputRecord(), count: capacity)
        words = UnsafeMutableRawPointer.allocate(byteCount: Word.count * MemoryLayout<Int>.stride, alignment: 128)
            .bindMemory(to: Atomic<Int>.self, capacity: Word.count)
        for index in 0..<Word.count { (words + index).initialize(to: Atomic(0)) }
        store(1, .nextSequence)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
        words.deinitialize(count: Word.count)
        UnsafeMutableRawPointer(words).deallocate()
    }

    // MARK: Producer

    /// Publishes, coalesces or declares the record lost. Never blocks, never allocates.
    func push(_ record: InputRecord) {
        flushPending()
        if record.isCritical {
            if owedGap == nil, hasRoom(below: capacity) { publish(record) } else { lose(record) }
        } else if owedGap == nil, held == nil, hasRoom(below: capacity - reserved) {
            publish(record)
        } else {
            hold(record)
        }
        requestSpaceIfPending()
    }

    /// Publishes an owed gap and a held record once room exists; the consumer asks for this.
    func retry() {
        flushPending()
        requestSpaceIfPending()
    }

    /// Ends production. Records already pushed stay readable; the consumer publishes leftovers.
    func close() {
        word(.closed).pointee.store(1, ordering: .releasing)
        dataReady.signal()
    }

    private func flushPending() {
        if let gap = owedGap, hasRoom(below: capacity) {
            owedGap = nil
            publish(gap)
            add(.gaps)
        }
        if owedGap == nil, let record = held, hasRoom(below: capacity - reserved) {
            held = nil
            publish(record)
        }
    }

    private func requestSpaceIfPending() {
        guard owedGap != nil || held != nil else { return }
        word(.spaceWanted).pointee.store(1, ordering: .relaxed)
        atomicMemoryFence(ordering: .sequentiallyConsistent)
        // A consumer that freed room before it could see the request will not answer it: look again.
        flushPending()
    }

    private func hold(_ record: InputRecord) {
        guard let current = held else {
            held = record
            return
        }
        if current.kind == .hover, record.kind == .hover {
            held = record
            add(.coalescedHovers)
        } else if let merged = ScrollGesture.merge(current, record) {
            held = merged
            add(.aggregatedScrolls)
        } else {
            lose(current)
            held = record
        }
    }

    // ponytail: UInt32 per-gap counts wrap after four billion losses in one unbroken gap, about 49 days
    // of a fully stalled consumer at 1000 records per second; split the gap if that ever matters.
    private func lose(_ record: InputRecord) {
        var gap = owedGap ?? InputRecord(kind: .gap, timestamp: record.timestamp,
                                         precedingRevision: record.precedingRevision, revision: record.revision)
        gap.sequence = takeSequence()
        gap.startTimestamp = min(gap.startTimestamp, record.startTimestamp)
        gap.timestamp = max(gap.timestamp, record.timestamp)
        gap.precedingRevision = min(gap.precedingRevision, record.precedingRevision)
        gap.revision = max(gap.revision, record.revision)
        if record.isCritical {
            gap.lostCritical &+= 1
            add(.lostCritical)
        } else {
            gap.lostCoalescible &+= 1
            add(.lostCoalescible)
        }
        owedGap = gap
    }

    private func publish(_ record: InputRecord) {
        var record = record
        // A gap already carries the last sequence it stands for.
        if record.kind != .gap { record.sequence = takeSequence() }
        let index = load(.head)
        slots[index & mask] = record
        word(.head).pointee.store(index &+ 1, ordering: .releasing)
        atomicMemoryFence(ordering: .sequentiallyConsistent)
        let tail = word(.tail).pointee.load(ordering: .acquiring)
        store(tail, .cachedTail)
        if tail == index { dataReady.signal() }
    }

    private func hasRoom(below limit: Int) -> Bool {
        let head = load(.head)
        if head &- load(.cachedTail) < limit { return true }
        let tail = word(.tail).pointee.load(ordering: .acquiring)
        store(tail, .cachedTail)
        return head &- tail < limit
    }

    private func takeSequence() -> UInt64 {
        let sequence = load(.nextSequence)
        store(sequence &+ 1, .nextSequence)
        return UInt64(sequence)
    }

    // MARK: Consumer

    func pop() -> InputRecord? {
        let index = load(.tail)
        if index == load(.cachedHead) {
            store(word(.head).pointee.load(ordering: .acquiring), .cachedHead)
            if index == load(.cachedHead) { return nil }
        }
        let record = slots[index & mask]
        word(.tail).pointee.store(index &+ 1, ordering: .releasing)
        return record
    }

    /// Blocks until a record is readable or the queue is closed. An empty ring is the most room the
    /// producer will get, so a pending request for space is answered here before sleeping.
    func waitForRecords(onSpace: () -> Void) {
        while true {
            atomicMemoryFence(ordering: .sequentiallyConsistent)
            if word(.head).pointee.load(ordering: .acquiring) != load(.tail) || isClosed { return }
            if load(.spaceWanted) != 0, word(.spaceWanted).pointee.exchange(0, ordering: .acquiringAndReleasing) != 0 {
                onSpace()
                continue
            }
            dataReady.wait()
        }
    }

    var isClosed: Bool { word(.closed).pointee.load(ordering: .acquiring) != 0 }

    /// The last sequence assigned, to a published record or inside a gap: every record the producer
    /// classified. Coalesced input takes no sequence; the counters count it apart.
    var observed: UInt64 { UInt64(load(.nextSequence) &- 1) }

    /// Once closed, the producer thread is gone: the consumer publishes its held record and owed gap
    /// and drains them too, so a shutdown under pressure still reports what was lost.
    func drainAfterClose(_ body: (InputRecord) -> Void) {
        precondition(isClosed, "only a closed queue has no producer")
        repeat {
            while let record = pop() { body(record) }
            flushPending()
        } while load(.tail) != load(.head)
    }

    var counters: InputQueueCounters {
        InputQueueCounters(
            published: UInt64(load(.head)),
            coalescedHovers: UInt64(load(.coalescedHovers)),
            aggregatedScrolls: UInt64(load(.aggregatedScrolls)),
            lostCritical: UInt64(load(.lostCritical)),
            lostCoalescible: UInt64(load(.lostCoalescible)),
            gaps: UInt64(load(.gaps))
        )
    }

    // MARK: Words

    private func word(_ word: Word) -> UnsafeMutablePointer<Atomic<Int>> { words + word.rawValue }

    // Relaxed access is enough for a word only one thread writes, or a counter read as a snapshot.
    private func load(_ word: Word) -> Int { self.word(word).pointee.load(ordering: .relaxed) }
    private func store(_ value: Int, _ word: Word) { self.word(word).pointee.store(value, ordering: .relaxed) }
    private func add(_ word: Word) { store(load(word) &+ 1, word) }
}

/// InputQueueCounters is what the listener's queue has done under pressure since it started.
/// Losses also reach the stream as gap events; coalescing is counted only here.
public struct InputQueueCounters: Sendable, Equatable {
    public var published: UInt64
    public var coalescedHovers: UInt64
    public var aggregatedScrolls: UInt64
    public var lostCritical: UInt64
    public var lostCoalescible: UInt64
    public var gaps: UInt64
}
