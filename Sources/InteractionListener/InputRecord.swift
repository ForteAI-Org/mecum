import CoreGraphics
import Foundation

/// InputRecord is one classified input as a fixed-width value the queue copies without retain or release.
/// Fields are fixed-width primitives in wire order with no implicit padding: `size` equals the stride
/// and a test pins every offset. It holds no String, reference or optional; titles resolve off the hot path.
/// Times are CLOCK_UPTIME_RAW nanoseconds, the clock behind `ProcessInfo.systemUptime`.
///
/// Wire layout, 104 bytes, 8-byte aligned, host byte order:
///
///     0 sequence          UInt64     56 attributionGeneration UInt32   80 valueA        Float32
///     8 timestamp         UInt64     60 lostCritical          UInt32   84 valueB        Float32
///    16 startTimestamp    UInt64     64 lostCoalescible       UInt32   88 windowX       Float32
///    24 precedingRevision UInt64     68 type                  UInt16   92 windowY       Float32
///    32 revision          UInt64     70 flags                 UInt16   96 windowWidth   Float32
///    40 targetPID         Int32      72 x                     Float32 100 windowHeight  Float32
///    44 sourcePID         Int32      76 y                     Float32
///    48 windowNumber      UInt32
///    52 windowLayer       Int32
///
/// A gap stands for records the queue could not keep: `sequence` is the last lost one and the range
/// starts `lostCritical + lostCoalescible - 1` before it. Its timestamps and revisions span the loss.
public struct InputRecord: Sendable, Equatable {
    public enum Kind: UInt16, Sendable {
        case empty = 0, click = 1, rightClick = 2, scrollDelta = 3, hover = 4, focus = 5, gap = 6
    }

    public enum Flag: UInt16, Sendable {
        /// The window fields describe the surface the attribution snapshot confirmed.
        case windowResolved = 1
        /// Routing named a surface the snapshot could not confirm; window number and pid are as routed.
        case staleAttribution = 2
        /// `sourcePID` is Quartz's source process; hover and focus have none.
        case hasSourceProcess = 4
    }

    public static let size = 104

    public var sequence: UInt64 = 0
    public var timestamp: UInt64 = 0
    public var startTimestamp: UInt64 = 0
    public var precedingRevision: UInt64 = 0
    public var revision: UInt64 = 0
    public var targetPID: Int32 = 0
    public var sourcePID: Int32 = 0
    public var windowNumber: UInt32 = 0
    public var windowLayer: Int32 = 0
    public var attributionGeneration: UInt32 = 0
    public var lostCritical: UInt32 = 0
    public var lostCoalescible: UInt32 = 0
    public var type: UInt16 = 0
    public var flags: UInt16 = 0
    public var x: Float32 = 0
    public var y: Float32 = 0
    public var valueA: Float32 = 0
    public var valueB: Float32 = 0
    public var windowX: Float32 = 0
    public var windowY: Float32 = 0
    public var windowWidth: Float32 = 0
    public var windowHeight: Float32 = 0

    public init() {}

    public init(kind: Kind, timestamp: UInt64, precedingRevision: UInt64, revision: UInt64) {
        type = kind.rawValue
        self.timestamp = timestamp
        startTimestamp = timestamp
        self.precedingRevision = precedingRevision
        self.revision = revision
    }

    public var kind: Kind { Kind(rawValue: type) ?? .empty }

    /// Clicks, focus and loss markers take reserved capacity; hovers and scrolls may be coalesced.
    public var isCritical: Bool { kind != .hover && kind != .scrollDelta }

    public var startedAt: Double { Double(startTimestamp) / 1e9 }
    public var endedAt: Double { Double(timestamp) / 1e9 }
    public var firstLostSequence: UInt64 { sequence &- UInt64(lostCritical) &- UInt64(lostCoalescible) &+ 1 }

    public func has(_ flag: Flag) -> Bool { flags & flag.rawValue != 0 }
    public mutating func set(_ flag: Flag) { flags |= flag.rawValue }

    /// Two records address one surface when every attribution field agrees; generations may differ.
    func sameTarget(as other: InputRecord) -> Bool {
        flags == other.flags && targetPID == other.targetPID && sourcePID == other.sourcePID
            && windowNumber == other.windowNumber && windowLayer == other.windowLayer
            && windowX == other.windowX && windowY == other.windowY
            && windowWidth == other.windowWidth && windowHeight == other.windowHeight
    }
}

extension InteractionEvent {
    /// Rebuilds the public value off the hot path. Wall time derives from the monotonic stamp and the
    /// title is whatever the consumer read for the record's window. A stale record's window is the one
    /// the consumer confirmed from the routed window's own row at delivery, with that moment's frame,
    /// or nil. An empty slot, which the queue never publishes, has no event.
    init?(record: InputRecord, title: String?, lateWindow: InteractionWindow? = nil) {
        let kind: Kind
        switch record.kind {
        case .empty: return nil
        case .click: kind = .click
        case .rightClick: kind = .rightClick
        case .scrollDelta: kind = .scroll
        case .hover: kind = .hover
        case .focus: kind = .focus
        case .gap: kind = .gap
        }
        let window = record.has(.windowResolved) ? InteractionWindow(
            processID: record.targetPID, number: Int(record.windowNumber), title: title,
            layer: Int(record.windowLayer),
            frame: CGRect(x: Double(record.windowX), y: Double(record.windowY),
                          width: Double(record.windowWidth), height: Double(record.windowHeight))
        ) : lateWindow
        let gap = record.kind == .gap ? Gap(
            firstSequence: record.firstLostSequence, lastSequence: record.sequence,
            lostCritical: record.lostCritical, lostCoalescible: record.lostCoalescible
        ) : nil
        self.init(
            kind: kind, timestamp: Date(timeIntervalSinceNow: record.startedAt - ProcessInfo.processInfo.systemUptime),
            startedAt: record.startedAt, endedAt: record.endedAt,
            precedingRevision: record.precedingRevision, revision: record.revision,
            point: CGPoint(x: Double(record.x), y: Double(record.y)), window: window,
            processID: window?.processID ?? record.targetPID,
            deltaX: Double(record.valueA), deltaY: Double(record.valueB),
            sourceProcessID: record.has(.hasSourceProcess) ? record.sourcePID : nil,
            sequence: record.sequence, gap: gap
        )
    }
}
