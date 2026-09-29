//
//  ClickAttribution.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import CoreGraphics
import EngineCore
import PerceptionCore

/// ClickAttribution names the one effect a delivered click, double-click or right-click can be credited with, from
/// the window census before the gesture and the census and perception after it, or says why none can. It is the one
/// rule `ClickEvidence` is built from, so a scene that merely changed is never taken for the surface the gesture
/// was meant to open.
///
/// Windows are told apart by their window-server number: a surface is new when its number was not listed before the
/// gesture. The listing before the gesture must show the window the gesture was delivered in, by its title or its
/// frame; one that answers without it, empty included, cannot tell new from old, so nothing is attributed. A new
/// pop-up is the target's menu only when it is the one new surface and it opened at the target: its frame, widened
/// by the target's own height, holds the point the gesture was delivered at, and its items are read from a capture
/// of it rather than of the window clicked in, every readable row of it (`menuItems`), whatever their number or
/// length. A capture of the window and its pop-ups together, as the Seat takes one while a pop-up is open, holds
/// the window's own controls too: there the items are only the elements lying mostly inside the new pop-up's frame,
/// so the target the pop-up opened at is not one. A new window is the gesture's only when it is the one new
/// surface, has a title, and is the window perceived afterwards, so the origin and the destination are linked; a
/// new window with the origin's title while the origin is no longer listed is the origin re-created, not opened.
enum ClickAttribution {

    /// The effect attributed to a gesture delivered at `point` on `target`, resolved in `before` and
    /// perceived afterwards in `afterWindow`. `change` is the effect the engine read from the scenes,
    /// pop-up rows included (`ActionEngine.gatedEffect`), so a menu is named by the same reading the
    /// outcome reports, narrowed to the new pop-up's rows when the capture also holds the window.
    static func effect(
        on target        : SceneElement,
        at point         : CGPoint,
        in before        : PerceivedWindow,
        census           : [SurfaceVerdict],
        after afterWindow: PerceivedWindow,
        surfaces         : WindowSurfaces,
        change           : SceneEffect?
    ) -> ClickEvidence.Effect {
        let after = afterWindow.scene
        let origins = census.filter { isOrigin($0.row, of: before) }
        guard !origins.isEmpty else { return .unattributed(.originNotListed) }
        let listed = Set(census.map(\.row.number))
        let opened = surfaces.verdicts.filter { !listed.contains($0.row.number) }
        let menus = opened.filter { $0.kind == .popupLayer || $0.kind == .floatingList }
        let windows = opened.filter { $0.kind == .window }
        if let menu = menus.first {
            guard menus.count == 1, windows.isEmpty else { return .unattributed(.severalSurfaces) }
            let margin = max(target.bounds.height * before.frame.height, 1)
            guard menu.row.frame.insetBy(dx: -margin, dy: -margin).contains(point) else {
                return .unattributed(.surfaceElsewhere)
            }
            // The items must come from a capture of the menu: one the provider says holds its pop-ups, or
            // one of another surface than the window clicked in. That window's own labels are not the menu's,
            // so a capture that holds the window too names only the rows inside the new pop-up's frame.
            let capturesPopups = after.coverage == .windowAndPopups
            let capturesAnotherSurface = LabelText.letters(after.windowTitle) != LabelText.letters(before.scene.windowTitle)
            let rows = capturesPopups ? after.elements.filter { isInside($0, of: afterWindow, menu.row.frame) }
                : after.elements
            let items = menuItems(rows)
            guard case .menuOpened? = change, items.count >= 2 else { return .unattributed(.unreadableSurface) }
            guard capturesPopups || capturesAnotherSurface else { return .unattributed(.menuNotCaptured) }
            return .menuOpened(items: items)
        }
        if let window = windows.first {
            guard windows.count == 1 else { return .unattributed(.severalSurfaces) }
            let title = LabelText.letters(window.row.title ?? "")
            guard !title.isEmpty, LabelText.letters(after.windowTitle) == title else {
                return .unattributed(.otherWindow)
            }
            let originNumbers = Set(origins.map(\.row.number))
            let originListed = surfaces.verdicts.contains { originNumbers.contains($0.row.number) }
            if !originListed, title == LabelText.letters(before.scene.windowTitle) {
                return .unattributed(.originRecreated)
            }
            return .windowOpened(title: after.windowTitle)
        }
        if after.token == before.scene.token { return .unattributed(.noChange) }
        return .unattributed(change == nil ? .repaint : .otherChange)
    }

    /// The items a menu's rows read, as its evidence keeps them: every labelled row that is not an icon, not
    /// recalled from memory, and reads a letter or a digit, once each, sorted. Unlike an outcome's sentence,
    /// which names a few, the evidence neither caps their number nor their length.
    static func menuItems(_ rows: [SceneElement]) -> [String] {
        let labels = rows.filter { !$0.isUnlabeled && !$0.isRecalled && $0.kind != .icon }
            .map(\.label)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
        return Array(Set(labels)).sorted()
    }

    /// Whether more than half of an element of `window` lies inside `surface`: a row of that pop-up, not a
    /// control of the window beneath, such as the target the pop-up opened at, whose center is its corner.
    private static func isInside(_ element: SceneElement, of window: PerceivedWindow, _ surface: CGRect) -> Bool {
        let rect = CGRect(x: window.frame.minX + element.bounds.x * window.frame.width,
                          y: window.frame.minY + element.bounds.y * window.frame.height,
                          width: element.bounds.width * window.frame.width,
                          height: element.bounds.height * window.frame.height)
        let inside = rect.intersection(surface)
        return !inside.isNull && inside.width * inside.height > rect.width * rect.height * 0.5
    }

    /// Whether a listed window is the one the gesture was delivered in: the same title, or the frame
    /// it was perceived in, within a point.
    private static func isOrigin(_ row: WindowRow, of window: PerceivedWindow) -> Bool {
        let title = LabelText.letters(window.scene.windowTitle)
        if !title.isEmpty, LabelText.letters(row.title ?? "") == title { return true }
        let (a, b) = (row.frame, window.frame)
        return abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1
            && abs(a.height - b.height) <= 1
    }
}
