import Foundation
import CoreGraphics

/// A recognized text run, with its box already converted to image pixels (top-left). No Vision-space
/// (bottom-left normalized) coordinates ever leave the OCR layer.
public struct OCRResult: Sendable, Equatable {
    public var text: String
    public var boxImagePx: CGRect

    public init(text: String, boxImagePx: CGRect) {
        self.text = text
        self.boxImagePx = boxImagePx
    }
}
