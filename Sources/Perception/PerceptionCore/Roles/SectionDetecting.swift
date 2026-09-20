import CoreGraphics

/// SectionDetecting finds panel boundaries from pixels, independently of control detection.
/// Rectangles use top-left image pixels. Empty means no supported partition, not a failed read.
/// A section is context only; it never implies an actionable control, label, or state.
/// `protecting` contains OCR bounds that a proposed seam must not cut through.
public protocol SectionDetecting: Sendable {
    func sections(in image: CGImage, protecting text: [CGRect]) throws -> [CGRect]
}
