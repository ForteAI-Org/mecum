import CoreGraphics

/// OverlayGeometry converts global top-left points and clips drawing against covering windows.
/// It is independent of AppKit, capture, perception algorithms, and display scale.
public nonisolated enum OverlayGeometry {

    /// Ignores desktop surfaces and diagnostic layers. Dock's display-sized layer-20 canvas is
    /// transparent despite WindowServer reporting alpha 1; smaller Dock windows still cover pixels.
    public static func canOcclude(frame: CGRect, layer: Int, ownerBundleID: String?, displays: [CGRect]) -> Bool {
        guard layer >= 0, layer < 1000 else { return false }
        let union = displays.reduce(CGRect.null) { $0.union($1) }
        return !(ownerBundleID == "com.apple.dock" && layer == 20 && (displays + [union]).contains(frame))
    }

    /// Converts a WindowServer frame to AppKit's global bottom-left coordinates. The height belongs
    /// to the primary display, including when the target is on a display above or left of it.
    public static func appKitFrame(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    /// Subtracts opaque covering rectangles. The disjoint result contains only visible parts.
    public static func visibleParts(of frame: CGRect, occludedBy covers: [CGRect]) -> [CGRect] {
        covers.reduce([frame]) { pieces, cover in
            pieces.flatMap { piece -> [CGRect] in
                let cut = piece.intersection(cover)
                guard !cut.isNull, !cut.isEmpty else { return [piece] }
                return [
                    CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: cut.minY - piece.minY),
                    CGRect(x: piece.minX, y: cut.maxY, width: piece.width, height: piece.maxY - cut.maxY),
                    CGRect(x: piece.minX, y: cut.minY, width: cut.minX - piece.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: piece.maxX - cut.maxX, height: cut.height)
                ].filter { $0.width > 0 && $0.height > 0 }
            }
        }
    }
}
