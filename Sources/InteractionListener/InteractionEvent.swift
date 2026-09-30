import CoreGraphics
import Foundation

/// InteractionEvent is one passive user gesture. Positions and frames use global top-left points.
/// Scroll timestamps span the gesture; revisions bracket all input received, including other apps.
/// It carries neither typed text nor pixels and is independent of perception, storage and agents.
/// Sequences are contiguous: a `gap` event stands for the records the listener's queue could not keep.
public struct InteractionEvent: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case click, rightClick, scroll, hover, focus, gap
    }

    /// Gap is the sequence range lost under pressure, split into clicks/focus and hovers/scrolls.
    public struct Gap: Sendable, Codable, Equatable {
        public let firstSequence: UInt64
        public let lastSequence: UInt64
        public let lostCritical: UInt32
        public let lostCoalescible: UInt32

        public init(firstSequence: UInt64, lastSequence: UInt64, lostCritical: UInt32, lostCoalescible: UInt32) {
            self.firstSequence = firstSequence
            self.lastSequence = lastSequence
            self.lostCritical = lostCritical
            self.lostCoalescible = lostCoalescible
        }
    }

    public let kind: Kind
    public let timestamp: Date
    public let startedAt: Double
    public var endedAt: Double
    public let precedingRevision: UInt64
    public var revision: UInt64
    public var point: CGPoint
    public let window: InteractionWindow?
    public let processID: Int32
    /// Quartz source process when available; input from another tool is not proof of a physical gesture.
    public let sourceProcessID: Int32?
    public var deltaX: Double
    public var deltaY: Double
    public let sequence: UInt64
    public let gap: Gap?

    public init(
        kind: Kind, timestamp: Date, startedAt: Double, endedAt: Double,
        precedingRevision: UInt64, revision: UInt64, point: CGPoint,
        window: InteractionWindow?, processID: Int32, deltaX: Double = 0, deltaY: Double = 0, sourceProcessID: Int32? = nil,
        sequence: UInt64 = 0, gap: Gap? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.precedingRevision = precedingRevision
        self.revision = revision
        self.point = point
        self.window = window
        self.processID = processID
        self.sourceProcessID = sourceProcessID
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.sequence = sequence
        self.gap = gap
    }
}

/// InteractionWindow is the surface under the pointer at input delivery, including menu layers.
/// A process id alone cannot distinguish a popup, dialog and document owned by the same application.
public struct InteractionWindow: Sendable, Codable, Equatable {
    public let processID: Int32
    public let number: Int
    public let title: String?
    public let layer: Int
    public let frame: CGRect

    public init(processID: Int32, number: Int, title: String?, layer: Int, frame: CGRect) {
        self.processID = processID
        self.number = number
        self.title = title
        self.layer = layer
        self.frame = frame
    }
}
