import CoreGraphics
import Foundation

/// InteractionWindowReader resolves OS-routed recipients without activating an application.
/// Popup and desktop surfaces remain eligible; stacking order alone is not evidence of ownership.
public enum InteractionWindowReader {
    public static func windows(excluding processID: Int32) -> [InteractionWindow] {
        guard let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], 0)
            as? [[String: Any]] else { return [] }
        return rows.compactMap(window(row:)).filter { $0.processID != processID }
    }

    /// Rebuilds a record's event off the hot path, on the listener's consumer thread. One window read per
    /// record that names a window: the title of a confirmed surface, or the routed window the snapshot
    /// predated, such as a popup opened just before the click.
    package static func event(for record: InputRecord, excluding processID: Int32) -> InteractionEvent? {
        let named = record.windowNumber > 0 && (record.has(.windowResolved) || record.has(.staleAttribution))
        let row = named ? row(of: Int(record.windowNumber)) : nil
        let late = lateWindow(for: record, row: row, excluding: processID)
        let title = record.has(.windowResolved) ? row?[kCGWindowName as String] as? String : nil
        return InteractionEvent(record: record, title: title, lateWindow: late)
    }

    /// Reads one window's row for a record delivered off the hot path: its title, and its geometry
    /// when the snapshot could not confirm it.
    static func row(of number: Int) -> [String: Any]? {
        let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(clamping: number))
        return (rows as? [[String: Any]])?.first
    }

    /// Resolves a stale record's routed window from that window's own row, read at delivery. The
    /// identity is the event's routing field, so this confirms the recipient rather than choosing one:
    /// the window must be on screen, visible, owned by the routed process when one was reported and
    /// contain the point. Process-only routing stays unresolved; there is no late frontmost guess.
    static func lateWindow(
        for record: InputRecord, row: [String: Any]?, excluding processID: Int32
    ) -> InteractionWindow? {
        guard record.has(.staleAttribution), record.windowNumber > 0, let row,
              row[kCGWindowIsOnscreen as String] as? Bool == true,
              let window = window(row: row), window.number == Int(record.windowNumber),
              window.processID != processID, record.targetPID == 0 || window.processID == record.targetPID,
              window.frame.contains(CGPoint(x: Double(record.x), y: Double(record.y))) else { return nil }
        return window
    }

    private static func window(row: [String: Any]) -> InteractionWindow? {
        guard let owner = row[kCGWindowOwnerPID as String] as? Int32,
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

/// AttributionSnapshot is the window geometry the tap thread hit-tests, listed off the hot path and
/// published whole under a new generation. Entries hold no references, so a lookup never retains,
/// releases or frees on the tap thread. Order is CGWindowList's front to back; titles are not kept.
struct AttributionSnapshot: Sendable {
    struct Window: Sendable, Equatable {
        let number: Int
        let processID: Int32
        let layer: Int32
        let frame: CGRect
    }

    let generation: UInt32
    let windows: [Window]

    init(generation: UInt32 = 0, windows: [InteractionWindow] = []) {
        self.generation = generation
        self.windows = windows.map {
            Window(number: $0.number, processID: $0.processID, layer: Int32(clamping: $0.layer), frame: $0.frame)
        }
    }

    /// Mirrors `InteractionWindowReader.window(at:in:recipientWindowNumber:targetProcessID:)` over the
    /// snapshot, with 0 standing for an absent routing field as Quartz reports it.
    func window(at point: CGPoint, recipientWindowNumber: Int, targetProcessID: Int32) -> Window? {
        if recipientWindowNumber > 0 {
            return windows.first {
                $0.number == recipientWindowNumber && $0.frame.contains(point)
                    && (targetProcessID == 0 || $0.processID == targetProcessID)
            }
        }
        guard targetProcessID > 0 else { return nil }
        return windows.first { $0.processID == targetProcessID && $0.frame.contains(point) }
    }

    /// Stamps the confirmed surface, or the routed number and pid flagged stale when this generation
    /// cannot confirm them: a new, moved or vanished window. It never substitutes another window.
    func attribute(_ record: inout InputRecord, at point: CGPoint, recipientWindowNumber: Int, targetProcessID: Int32) {
        record.attributionGeneration = generation
        guard let window = window(at: point, recipientWindowNumber: recipientWindowNumber,
                                  targetProcessID: targetProcessID) else {
            record.targetPID = targetProcessID
            record.windowNumber = UInt32(clamping: recipientWindowNumber)
            if recipientWindowNumber > 0 || targetProcessID > 0 { record.set(.staleAttribution) }
            return
        }
        record.set(.windowResolved)
        record.targetPID = window.processID
        record.windowNumber = UInt32(clamping: window.number)
        record.windowLayer = window.layer
        record.windowX = Float32(window.frame.origin.x)
        record.windowY = Float32(window.frame.origin.y)
        record.windowWidth = Float32(window.frame.size.width)
        record.windowHeight = Float32(window.frame.size.height)
    }
}
