//
//  PopupRowHarvest.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import Foundation

/// PopupRowHarvest finds the menu an application has open and reads its items, over the generic
/// accessibility reader, so a test decides the walk with a tree of plain objects.
///
/// A native menu is the one place accessibility beats pixels outright: `PopupRowSegmenter` can only
/// cut the page that is painted, while the tree lists every item at once, the scrolled-out ones
/// included. Measured on TextEdit's font list: 20 families painted, "Helvetica" two pages below,
/// and an act on it honestly missed.
///
/// Two measured rules shape the walk. The frame is read BEFORE the children, because an application's
/// menu bar holds one closed menu per title, eight of them on TextEdit, all reporting a zero-size
/// frame; and while a menu is tracking, the application's main thread is running it, so every
/// request queues behind it and a walk that fetched children for all of those could spend the whole
/// budget and come back with nothing. And a menu with no children is not the one on screen.
public enum PopupRowHarvest {

    /// What bounds one walk. The deadline is a closure the caller supplies: this reads no clock.
    public struct Limits: Sendable {
        public var maxDepth     : Int
        public var maxCandidates: Int
        public var maxRows      : Int
        public var isPastDeadline: @Sendable () -> Bool

        public init(
            maxDepth      : Int = 8,
            maxCandidates : Int = 8,
            maxRows       : Int = 400,
            isPastDeadline: @escaping @Sendable () -> Bool = { false }
        ) {
            self.maxDepth       = maxDepth
            self.maxCandidates  = maxCandidates
            self.maxRows        = maxRows
            self.isPastDeadline = isPastDeadline
        }
    }

    /// The rows of the open pop-up under `roots`, or an empty list when no menu on screen was found.
    /// Roots are searched in order, so the cheapest place to look goes first.
    public static func rows<Reader: AccessibilityTreeReading>(
        among roots: [Reader.Node],
        popupFrame : CGRect?,
        reader     : Reader,
        limits     : Limits = Limits()
    ) -> [PopupRow] {
        guard let menu = menu(among: roots, popupFrame: popupFrame, reader: reader, limits: limits) else {
            return []
        }
        return self.rows(of: menu, popupFrame: popupFrame, reader: reader, limits: limits)
    }

    /// The menu that is actually on screen, or nil.
    ///
    /// Menus live in three places depending on how one was opened: under the application element
    /// (a context menu), under the menu bar (a menu-bar title pulled down), and under a window's
    /// pop-up button (a dropdown's list). With a pop-up frame to compare against, the winner is the
    /// menu whose own frame matches what the window server says is on screen, and nothing else is
    /// accepted: a toolkit that paints its own list exposes no menu for it at all, and handing back
    /// some other populated menu would name rows that are not there and tell the caller
    /// accessibility answered, so the row cut that CAN read those pixels gets skipped.
    ///
    /// Without a frame to compare, a single populated menu is unambiguous and anything else is not,
    /// so several candidates yield none rather than the wrong one.
    public static func menu<Reader: AccessibilityTreeReading>(
        among roots: [Reader.Node],
        popupFrame : CGRect?,
        reader     : Reader,
        limits     : Limits = Limits()
    ) -> Reader.Node? {

        var scored  : [(node: Reader.Node, score: Double)] = []
        var frameless: [Reader.Node] = []
        var settled = false

        func consider(_ node: Reader.Node) {
            guard let frame = reader.frame(node), frame.width > 1, frame.height > 1 else {
                frameless.append(node)
                return
            }
            guard let popupFrame else { return }
            let score = overlap(frame, popupFrame)
            guard score > 0.3, !reader.children(node).isEmpty else { return }
            scored.append((node, score))
            // The menu whose frame IS the pop-up window: nothing can beat it.
            if score > 0.9 { settled = true }
        }

        func walk(_ node: Reader.Node, _ depth: Int) {
            guard depth < limits.maxDepth, !settled, !limits.isPastDeadline(),
                  scored.count < limits.maxCandidates else { return }
            for child in reader.children(node) {
                guard !settled, !limits.isPastDeadline() else { return }
                // Never descend INTO a menu here: its items are read separately.
                if reader.role(child) == "AXMenu" { consider(child); continue }
                walk(child, depth + 1)
            }
        }

        for root in roots where !settled {
            walk(root, 0)
        }
        if let best = scored.max(by: { $0.score < $1.score })?.node { return best }
        guard popupFrame == nil else { return nil }
        let populated = frameless.filter { !reader.children($0).isEmpty }
        return populated.count == 1 ? populated[0] : nil
    }

    /// The menu's items, in menu order. Separators and titleless decoration are dropped, and a row
    /// whose frame is missing or outside the painted pop-up is kept but marked off screen: it is a
    /// real item the caller must select by name rather than click.
    public static func rows<Reader: AccessibilityTreeReading>(
        of menu   : Reader.Node,
        popupFrame: CGRect?,
        reader    : Reader,
        limits    : Limits = Limits()
    ) -> [PopupRow] {

        var out   = [PopupRow]()
        var order = 0
        for child in reader.children(menu) {
            guard !limits.isPastDeadline(), out.count < limits.maxRows else { break }
            guard reader.role(child) == "AXMenuItem" else { continue }
            let title = (reader.title(child) ?? reader.descriptionText(child) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            defer { order += 1 }
            guard isSelectable(title) else { continue }
            let frame = reader.frame(child)
            let framed = (frame?.width ?? 0) > 1 && (frame?.height ?? 0) > 1 ? frame : nil
            out.append(PopupRow(
                title     : title,
                isEnabled : reader.isEnabled(child) ?? true,
                isOnScreen: isOnScreen(framed, in: popupFrame),
                frame     : framed,
                order     : order
            ))
        }
        return out
    }

    /// A row a person could pick. A separator carries an empty title and no description either, and
    /// applications pad menus with titleless decoration rows.
    public static func isSelectable(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...64).contains(trimmed.count) else { return false }
        return LabelText.isNameworthy(trimmed)
    }

    /// Whether a row is painted right now. A row whose frame accessibility withheld, or whose frame
    /// sits outside the pop-up's painted box, is never a coordinate to click. With no pop-up frame
    /// to judge against, a framed row is taken at its word.
    public static func isOnScreen(_ frame: CGRect?, in popupFrame: CGRect?) -> Bool {
        guard let frame, frame.width > 1, frame.height > 1 else { return false }
        guard let popupFrame else { return true }
        return popupFrame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// The fraction of the SMALLER rect the intersection covers. A menu's accessibility frame and
    /// its window-server frame differ by the window's shadow and padding, so intersection over
    /// union is needlessly strict here.
    public static func overlap(_ first: CGRect, _ second: CGRect) -> Double {
        let shared = first.intersection(second)
        guard !shared.isNull, shared.width > 0, shared.height > 0 else { return 0 }
        let smaller = min(first.width * first.height, second.width * second.height)
        return smaller > 0 ? Double((shared.width * shared.height) / smaller) : 0
    }
}
