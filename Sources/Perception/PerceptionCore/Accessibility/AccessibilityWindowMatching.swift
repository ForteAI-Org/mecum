import CoreGraphics

/// AccessibilityWindowMatching binds a tree to the captured window instead of the focused window.
/// A unique near-exact frame wins. A capture including a popup may contain one slightly smaller
/// window. The optional identity predicate narrows the candidates before geometry is checked.
/// Unmatched or tied frames yield nil, so another window's controls cannot contaminate it.
public enum AccessibilityWindowMatching {
    public static func window<Reader: AccessibilityTreeReading>(
        among windows: [Reader.Node], capturedFrame: CGRect, reader: Reader,
        isCapturedWindow: (Reader.Node) -> Bool = { _ in true }
    ) -> Reader.Node? {
        guard capturedFrame.width > 0, capturedFrame.height > 0 else { return nil }
        let framed = windows.compactMap { node -> (Reader.Node, CGRect)? in
            guard isCapturedWindow(node) else { return nil }
            guard let frame = reader.frame(node), frame.width > 0, frame.height > 0 else { return nil }
            return (node, frame)
        }
        let exact = framed.filter {
            abs($0.1.minX - capturedFrame.minX) <= 2 && abs($0.1.minY - capturedFrame.minY) <= 2
                && abs($0.1.width - capturedFrame.width) <= 2 && abs($0.1.height - capturedFrame.height) <= 2
        }
        if exact.count == 1 { return exact.first?.0 }
        if !exact.isEmpty { return nil }
        let contained = framed.filter {
            capturedFrame.contains($0.1)
                && $0.1.width * $0.1.height >= 0.8 * capturedFrame.width * capturedFrame.height
        }
        return contained.count == 1 ? contained.first?.0 : nil
    }
}
