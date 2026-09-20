import AppKit
import CoreGraphics
import Foundation
import PerceptionCore
import SceneOverlay

/// PeekTarget records the window census and visible areas used to reject an in-flight stale scene.
struct PeekTarget: Equatable {
    let processID: pid_t
    let windows: [WindowRow]
    let frame: CGRect
    let visibleRegions: [CGRect]
}

/// PeekTargetReader reads frontmost identity and stacking order without activating anything.
enum PeekTargetReader {
    static func current(excluding processID: pid_t) -> PeekTarget? {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != processID,
              let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let census: [(owner: pid_t, row: WindowRow)] = infos.compactMap { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != processID,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { return nil }
            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame),
                  frame.width > 0, frame.height > 0 else { return nil }
            return (owner, WindowRow(layer: layer, frame: frame,
                                    title: info[kCGWindowName as String] as? String, number: number))
        }
        let rows = census.filter { $0.owner == front.processIdentifier }.map(\.row)
        let surfaces = WindowSurfaceClassifier.classify(rows)
        guard let target = surfaces.interaction else { return nil }
        let selected = surfaces.verdicts.filter {
            $0.row.number == target.number || $0.kind == .popupLayer || $0.kind == .floatingList
        }.map(\.row)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let displays = NSScreen.screens.map { OverlayGeometry.appKitFrame($0.frame, primaryHeight: primaryHeight) }
        let visible = selected.flatMap { row -> [CGRect] in
            let covers = census.prefix { $0.row.number != row.number }.filter {
                let bundle = $0.row.layer == 20 ? NSRunningApplication(processIdentifier: $0.owner)?.bundleIdentifier : nil
                return OverlayGeometry.canOcclude(frame: $0.row.frame, layer: $0.row.layer,
                                                  ownerBundleID: bundle, displays: displays)
            }.map { $0.row.frame }
            return OverlayGeometry.visibleParts(of: row.frame, occludedBy: covers)
        }
        return PeekTarget(processID: front.processIdentifier, windows: rows,
                          frame: surfaces.popups.reduce(target.frame) { $0.union($1) }, visibleRegions: visible)
    }
}
