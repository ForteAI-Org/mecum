//
//  ContextMenuChoice.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/09/2026.
//

import CoreGraphics
import Foundation
import TargetReader

/// What choosing one item of an open contextual menu by its title came to: the
/// point to click, or the sentence the planner's history carries in its place.
///
/// It is a pure function over a reading and a wanted title, and that is the
/// point: the interesting part of a menu action is which row the title names,
/// and deciding it here keeps it out of the interaction, where nothing can be
/// tested and a wrong answer runs somebody's command.
///
/// A refusal is always a sentence and never a point. The three readings
/// `ObservedContextMenu` distinguishes are three different situations for the
/// planner, so each of them refuses in its own words rather than through a
/// shared "no".
enum ContextMenuChoice: Equatable {

    /// The centre of the row's own rectangle, in the Quartz coordinates the
    /// reader answered with.
    case click(CGPoint)

    /// Why no item was chosen, written for the planner's step history.
    case refused(String)

    /// Matching is whole-title, ignoring case and accents.
    ///
    /// Whole-title because a menu item is a command: "Copia" and "Copia
    /// indirizzo" do two different things, and a prefix or substring rule would
    /// silently run the second when the planner asked for the first. Case and
    /// accents are ignored instead because they carry no such distinction:
    /// these titles are localised and this Mac is Italian, so the row Finder
    /// draws is "Copia", and a planner that wrote "copia" or typed "piu" for
    /// "più" named that row and no other. A trailing ellipsis is dropped for
    /// the same reason: macOS prints it to say a dialog follows, and "Salva con
    /// nome…" is the item a planner means by "Salva con nome".
    static func choosing(_ wanted: String, in menu: ObservedContextMenu) -> ContextMenuChoice {
        switch menu {
        case .notOpen:
            return .refused("The right click opened no contextual menu on this element, so there was "
                + "nothing to choose from.")

        case .drawnOutsideTheAccessibilityTree:
            // Not a failure of the reading, and a rectangle is not a title:
            // guessing a row inside it clicks a command nobody read.
            return .refused("This application's contextual menu cannot be read by title: it is drawn "
                + "outside the accessibility tree, so its items have no titles to match and none of "
                + "them can be chosen. Reaching \"\(wanted)\" needs another route in this application; "
                + "opening the menu again will read the same.")

        case .items(let items):
            guard let item = items.first(where: { matches($0.title, wanted) }) else {
                let offered = items.map(\.title).filter { !$0.isEmpty }
                return .refused("No item of this contextual menu is titled \"\(wanted)\". "
                    + (offered.isEmpty
                        ? "The menu exposed no titled items at all."
                        : "The menu offered: \(offered.joined(separator: ", "))."))
            }
            guard !item.hasSubmenu else {
                return .refused("\"\(item.title)\" opens a submenu rather than running a command, so "
                    + "clicking it chooses nothing. Name an item of that submenu instead.")
            }
            guard item.isEnabled else {
                return .refused("\"\(item.title)\" is in this contextual menu and is disabled, so the "
                    + "application will not run it on what is selected here.")
            }
            guard let frame = item.frame else {
                return .refused("\"\(item.title)\" is in this contextual menu and the application "
                    + "publishes no position for it, so there is nowhere to aim the click.")
            }
            return .click(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    /// The same row in the menu the **observation** delivered.
    ///
    /// `choosing` answers in the coordinates of the rectangle the accessibility
    /// reader saw, and the click is admitted against the rectangle the capture
    /// delivered. Those are two readings of one menu taken a moment apart and
    /// they are not owed agreement, so what carries over is the offset into the
    /// menu and never the absolute point: an absolute point from the first
    /// reading lands outside the second the instant they differ, and
    /// `InputLocation(screenPoint:observedIn:)` refuses it.
    static func screenPoint(_ chosen: CGPoint, readAt read: CGRect, observedAt observed: CGRect) -> CGPoint {
        CGPoint(x: chosen.x - read.minX + observed.minX, y: chosen.y - read.minY + observed.minY)
    }

    private static func matches(_ title: String, _ wanted: String) -> Bool {
        let title = normalized(title)
        // An empty title is a separator, and an empty wanted title would match
        // every one of them.
        guard !title.isEmpty else { return false }
        return title.compare(normalized(wanted),
                             options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static func normalized(_ title: String) -> String {
        var title = title.trimmingCharacters(in: .whitespaces)
        for ellipsis in ["…", "..."] where title.hasSuffix(ellipsis) { title.removeLast(ellipsis.count) }
        return title.trimmingCharacters(in: .whitespaces)
    }
}
