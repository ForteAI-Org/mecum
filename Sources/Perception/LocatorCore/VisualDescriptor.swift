import Foundation
import CoreGraphics

/// The pixel view of a picked element: crops + a state-invariant edge hash.
///
/// `cropRef`/`contextCropRef` store the PNG *filename only* (e.g. `<uuid>.on.png`), never a path —
/// the absolute path is reconstructed from the store directory at load time. This keeps descriptors
/// portable and avoids leaking absolute paths into persisted JSON.
public struct VisualDescriptor: Codable, Equatable, Sendable {
    public var cropRef: String              // PNG filename, native scale
    public var cropSize: CGSize             // pixels
    public var contextCropRef: String       // element + margin crop (disambiguates identical widgets)
    public var contextMarginPx: CGFloat
    /// pHash of the Sobel edge map — STATE-INVARIANT (a button lighting up changes hue, not structure).
    public var edgeHash: String
    public var stateVariants: [StateVariant] // empty if only one state captured

    public init(
        cropRef: String,
        cropSize: CGSize,
        contextCropRef: String,
        contextMarginPx: CGFloat,
        edgeHash: String,
        stateVariants: [StateVariant] = []
    ) {
        self.cropRef = cropRef
        self.cropSize = cropSize
        self.contextCropRef = contextCropRef
        self.contextMarginPx = contextMarginPx
        self.edgeHash = edgeHash
        self.stateVariants = stateVariants
    }
}

/// An alternate visual state of the same element (e.g. "on"/"off", "open"/"closed").
public struct StateVariant: Codable, Equatable, Sendable {
    public var name: String
    public var cropRef: String
    public var edgeHash: String

    public init(name: String, cropRef: String, edgeHash: String) {
        self.name = name
        self.cropRef = cropRef
        self.edgeHash = edgeHash
    }
}
