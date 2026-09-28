import CoreGraphics
import Foundation

/// InteractionWindowReader resolves OS-routed recipients without activating an application.
/// Popup and desktop surfaces remain eligible; stacking order alone is not evidence of ownership.
public enum InteractionWindowReader {
    public static func windows(excluding processID: Int32) -> [InteractionWindow] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], 0)
            as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let owner = row[kCGWindowOwnerPID as String] as? Int32, owner != processID,
                  let number = row[kCGWindowNumber as String] as? Int,
                  let layer = row[kCGWindowLayer as String] as? Int,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any] else { return nil }
            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame),
                  frame.width > 0, frame.height > 0 else { return nil }
            return InteractionWindow(
                processID: owner, number: number, title: row[kCGWindowName as String] as? String,
                layer: layer, frame: frame
            )
        }
    }

    /// Resolves an exact routed window, or the frontmost surface belonging to the routed process.
    /// A missing recipient stays unresolved. No routing evidence means no inferred owner.
    public static func window(
        at point: CGPoint, in windows: [InteractionWindow],
        recipientWindowNumber: Int? = nil, targetProcessID: Int32? = nil
    ) -> InteractionWindow? {
        if let number = recipientWindowNumber, number > 0 {
            return windows.first {
                $0.number == number && $0.frame.contains(point)
                    && (targetProcessID == nil || targetProcessID == 0 || $0.processID == targetProcessID)
            }
        }
        guard let processID = targetProcessID, processID > 0 else { return nil }
        return windows.first { $0.processID == processID && $0.frame.contains(point) }
    }
}
