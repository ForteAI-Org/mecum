import CoreGraphics

/// PointerRoute retains OS routing metadata without doing a window census on every mouse move.
/// Consumers must match the current pointer position before using it for ambient observations.
struct PointerRoute: Sendable {
    let point: CGPoint
    let recipientWindowNumber: Int
    let targetProcessID: Int32

    func window(at currentPoint: CGPoint, in windows: [InteractionWindow]) -> InteractionWindow? {
        guard abs(currentPoint.x - point.x) <= 3, abs(currentPoint.y - point.y) <= 3 else { return nil }
        return InteractionWindowReader.window(
            at: currentPoint,
            in: windows,
            recipientWindowNumber: recipientWindowNumber,
            targetProcessID: targetProcessID
        )
    }
}
