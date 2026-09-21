import Foundation
import CoreGraphics

/// The text view of a picked element: the element's own text plus nearby text with relative offsets.
/// Neighbors power the "find 'Vox Lead', look 86px right" constellation match in relocation stage 3b.
public struct TextDescriptor: Codable, Equatable, Sendable {
    public var selfText: String?            // OCR/AX text of the element itself
    public var neighbors: [TextNeighbor]

    public init(selfText: String? = nil, neighbors: [TextNeighbor] = []) {
        self.selfText = selfText
        self.neighbors = neighbors
    }
}

/// A nearby text label and where it sits relative to the element origin.
public struct TextNeighbor: Codable, Equatable, Sendable {
    public var text: String
    /// px, relative to element origin (e.g. (-86, 2) == "to my left").
    public var offset: CGPoint
    public var tolerancePx: CGFloat

    public init(text: String, offset: CGPoint, tolerancePx: CGFloat) {
        self.text = text
        self.offset = offset
        self.tolerancePx = tolerancePx
    }
}
