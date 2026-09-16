//
//  ShortcutRow.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import CoreGraphics
import SeatCore

/// ShortcutRow is one row of the shortcut matrix: what is pressed, what code
/// the target publishes for it, and what is expected to happen.
///
/// The expectation is written down **before** the row runs, because a matrix
/// that predicts nothing is not falsifiable. The prediction is not a guess: the
/// Ledger already records that Command and V is delivered to both target
/// families and acted on by neither, for a structural reason that applies to
/// every key equivalent a menu resolves. If a row marked `.deliveredOnly`
/// passes, the Ledger entry is narrower than we believe and has to be rewritten.
nonisolated enum ShortcutRow: String, CaseIterable {

    case copy
    case paste
    case selectAll
    case undo
    case redo
    case save
    case wordRight
    case cancel

    /// What the target is expected to do, and why.
    enum Expectation {

        /// The events arrive and the target acts on them. These are the
        /// shortcuts a responder or a key binding answers, with no menu in the
        /// path.
        case acts

        /// The events arrive and nothing happens, because the shortcut is a
        /// key equivalent of the application's main menu and a menu belongs to
        /// the frontmost application, which this kit never becomes.
        case deliveredOnly

        /// The events arrive and **this family exposes nothing to look at**.
        ///
        /// It is not a prediction about the target, it is an admission about
        /// the harness: a row marked this way measures delivery and says so.
        /// Calling it a FAIL would report the absence of an oracle as the
        /// absence of an effect, which is the worst kind of row, because it
        /// would go on saying FAIL on the day the target started working.
        case effectNotObservable
    }

    /// The two-character code the target publishes. It is short because the
    /// browser half reports through a window title, which the window server
    /// elides in the middle once it grows.
    var code: String {
        switch self {
            case .copy     : "cc"
            case .paste    : "cv"
            case .selectAll: "ca"
            case .undo     : "cz"
            case .redo     : "cZ"
            case .save     : "cS"
            case .wordRight: "ar"
            case .cancel   : "es"
        }
    }

    /// What is actually pressed.
    ///
    /// The six menu equivalents are written as **characters**, because that is
    /// what a menu item is matched on and because the machine this was written
    /// on has a Dvorak layout, where c is not at the virtual key a QWERTY
    /// keyboard puts it. The two others are **positions**, which mean the same
    /// thing on every layout and need no resolution at all.
    var shortcut: Shortcut {
        switch self {
            case .copy     : .character("c", holding: .command)
            case .paste    : .character("v", holding: .command)
            case .selectAll: .character("a", holding: .command)
            case .undo     : .character("z", holding: .command)
            case .redo     : .character("z", holding: [.command, .shift])
            case .save     : .character("s", holding: [.command, .shift])
            case .wordRight: .physical(Self.arrowRight, holding: .option)
            case .cancel   : .physical(Self.escape)
        }
    }

    func expectation(on family: TargetFamily) -> Expectation {
        switch self {
            // Resolved by the main menu, which belongs to the frontmost
            // application. See `SpiLedger.md` under Discarded.
            case .copy, .paste, .selectAll, .undo, .redo:
                .deliveredOnly

            // A Save panel is observed through the target's WindowServer IDs.
            // Its menu equivalent is delivered without opening a panel in background.
            case .save:
                .deliveredOnly

            // Resolved by the responder chain and the standard key bindings,
            // with no menu in the path.
            case .wordRight:
                .acts

            // AppKit counts cancelOperation:. The browser row prepares a native
            // HTML dialog and observes its cancel event and closed state.
            case .cancel:
                .acts
        }
    }

    /// Whether this row replaces the person's clipboard to be measured at all.
    ///
    /// Only the paste row does: something has to be on the general pasteboard
    /// for a paste to have anything to insert, and the Ledger already records
    /// that no private pasteboard is reachable from a posted event. So the row
    /// is opt-in and saves and restores what it found. Copy only reads
    /// `changeCount`, a monotonic integer that says something changed without
    /// reading anything of the person's.
    var replacesTheClipboard: Bool { self == .paste }

    /// Command and Shift and S opens a native panel rather than changing
    /// anything a page or a text field could report, so its oracle is the
    /// window server: a new window owned by the target appeared.
    var oracleIsANewWindow: Bool { self == .save }

    /// The number a published code becomes in a target's counters.
    ///
    /// `MatrixTarget.state()` answers numbers, and the page publishes two
    /// readable characters so a human looking at the window title can see which
    /// shortcut arrived. The mapping lives here so both halves of the matrix,
    /// the browser's title and the fixture's report, agree on one table.
    /// Anything unrecognised, `--` included, is -1: absent, never row zero.
    static let absent = -1.0

    var number: Double { Double(Self.allCases.firstIndex(of: self) ?? -1) }

    static func number(ofCode code: String) -> Double {
        allCases.first { $0.code == code }?.number ?? absent
    }

    private static let arrowRight = PhysicalKey(name: "ArrowRight", virtualKey: 124)
    private static let escape     = PhysicalKey(name: "Escape",     virtualKey: 53)
}
