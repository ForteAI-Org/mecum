import CoreGraphics
import Foundation

/// InteractionEvent is one passive user gesture. Positions and frames use global top-left points.
/// Scroll timestamps span the gesture; revisions bracket all input received, including other apps.
/// It carries neither typed text nor pixels and is independent of perception, storage and agents.
public struct InteractionEvent: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case click, rightClick, scroll, hover, focus
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

    public init(
        kind: Kind, timestamp: Date, startedAt: Double, endedAt: Double,
        precedingRevision: UInt64, revision: UInt64, point: CGPoint,
        window: InteractionWindow?, processID: Int32, deltaX: Double = 0, deltaY: Double = 0, sourceProcessID: Int32? = nil
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
