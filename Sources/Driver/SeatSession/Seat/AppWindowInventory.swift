//
//  AppWindowInventory.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import CoreGraphics
import SeatCore

/// AppWindowChange is what one pass over the windows of the driven applications
/// found, said in the terms the seat acts on. There is no `moved` case on
/// purpose: a window the person already had on their own display is theirs
/// whether it stands still or not, and moving it because it moved is the
/// retroactive transfer this feature must not do.
nonisolated enum AppWindowChange: Equatable {

    /// A window of a driven process the seat does not hold, outside the Virtual
    /// Display, seen twice at the same frame. It was not there when the seat
    /// took control.
    case appeared(WindowReference)

    /// The same, for a window that had been seen, went out of the on-screen
    /// list, and came back.
    case reappeared(WindowReference)

    /// A window the seat holds whose frame is no longer inside the Virtual
    /// Display.
    case leftVirtualDisplay(WindowReference)

    /// A window the seat holds that this reading no longer carries. One missing
    /// reading is not a destruction: it is the wake-up for whoever owns that
    /// proof.
    case vanished(windowNumber: Int)
}

/// AppWindowInventory is the pure half of following an application's windows:
/// what was there at the start, what is there now, and which of the differences
/// is worth acting on.
///
/// ## The first reading is a baseline and never a transfer
///
/// Everything the first pass sees becomes the inventory and produces nothing.
/// The windows an application already had on the person's displays when the
/// seat took control are the person's, and a feature that hoovered them onto
/// the Virtual Display because it had just started looking would be taking
/// windows nobody offered it.
///
/// ## Two agreeing readings before a candidate is one
///
/// A window is published to the window server before it has settled its
/// geometry, and `kAXWindowCreatedNotification` was measured arriving 79 to
/// 249 ms *before* the window server shows the window at all. So a frame read
/// at the first sighting is a frame that is about to change, and acting on it
/// centres a window by a size it does not have. A surface therefore becomes a
/// candidate only when a second reading carries the same identity at the same
/// frame, which is the same rule `confirmPlacement` uses at the other end of
/// the transaction.
///
/// The rule holds for every change this type emits, a window the seat already
/// holds included. A stale frame is not only a new window's problem: a Qt
/// target was measured publishing (4032, 2390, 1345, 949) for a window whose
/// own body read (1472, 1012, 1345, 949), and a frame like that is outside the
/// display. Acting on one reading there would report an escape that never
/// happened, spend an attempt on it, and eventually stop answering a real one.
///
/// ## Identity, never the Window ID alone
///
/// A record is keyed by Window ID and validated by `WindowIdentity`, so a
/// Window ID reused by another window reads as one window leaving and a
/// different one arriving instead of as the same window moving. Process
/// membership is compared on `ProcessIdentity`, so a PID reused after the
/// application terminated owns nothing the seat was driving.
///
/// It takes no reading and makes no system call: every reading is passed in,
/// which is why the whole of it is a unit test with no display attached. A
/// `nil` reading is `unknown` and changes nothing at all, because an empty list
/// answered for a failed read is how every window of an application reads as
/// destroyed at once.
nonisolated struct AppWindowInventory {

    /// How many times the seat may try to bring one Window ID under control
    /// before it stops. An application that puts its window back on the
    /// physical display after every move is an application that disagrees, and
    /// the third disagreement is the answer rather than a loop.
    static let maximumAttempts = 3

    private struct KnownSurface {

        let identity: WindowIdentity
        var frame   : CGRect

        /// A second reading has carried this identity at this frame, so the
        /// geometry has settled and the surface may be acted on.
        var agreed: Bool

        /// The last reading did not carry it. Kept rather than deleted: the
        /// record is what tells a window coming back from a window that was
        /// never there.
        var isMissing: Bool

        /// It has been missing at least once, which is what separates a
        /// reappearance from a first appearance.
        var hasReturned: Bool
    }

    private var known    : [Int: KnownSurface] = [:]
    private var attempts : [Int: Int]          = [:]

    /// True once the baseline pass has run. Before it, every difference is a
    /// window that was already there.
    private(set) var isPrimed = false

    /// True while a surface is waiting for the second reading that agrees with
    /// it, which is what tells the caller another pass soon is worth its cost.
    private(set) var hasPendingCandidate = false

    /// Records every surface this reading carries that the inventory does not
    /// already know, as one that was already there, and answers nothing.
    ///
    /// It is called at the moment the seat starts driving a process, which is
    /// the moment "already there" is defined. Taking the baseline from the
    /// first periodic pass instead looks the same and is not: the pass runs
    /// whenever the main actor is next free, and a window the application
    /// opened in between would be baselined as the person's and never
    /// transferred. Measured on the Live tier, where the first pass ran after
    /// the second window had already appeared.
    ///
    /// Surfaces it already knows are left exactly as they are, so a candidate
    /// waiting for its second reading is not quietly turned into furniture by a
    /// second window being adopted next to it.
    mutating func baseline(surfaces: [WindowSurface]?, processes: Set<ProcessIdentity>) {

        isPrimed = true
        guard let surfaces else { return }

        for surface in surfaces {
            guard let identity = surface.reference.identity,
                  processes.contains(identity.process),
                  known[identity.windowNumber] == nil
            else { continue }

            known[identity.windowNumber] = KnownSurface(
                identity   : identity,
                frame      : surface.reference.frame,
                agreed     : true,
                isMissing  : false,
                hasReturned: false
            )
        }
    }

    /// Folds one reading in and answers what changed.
    ///
    /// `surfaces` is `nil` for a reading that failed, which leaves the whole
    /// inventory untouched. `adopted` is the Window IDs the seat holds, and a
    /// held window is judged by where it is rather than by whether it is new.
    /// `menuLevel` is the pop up menu level: a contextual menu has exactly one
    /// owner in this kit and it is not this one.
    mutating func changes(
        surfaces            : [WindowSurface]?,
        processes           : Set<ProcessIdentity>,
        adopted             : Set<Int>,
        within virtualBounds: CGRect,
        menuLevel           : Int
    ) -> [AppWindowChange] {

        guard let surfaces else { return [] }

        var changes: [AppWindowChange] = []
        var seen   : Set<Int>          = []
        var pending                    = false

        for surface in surfaces {
            guard let identity = surface.reference.identity,
                  processes.contains(identity.process)
            else { continue }

            let windowNumber = identity.windowNumber
            seen.insert(windowNumber)

            guard let previous = known[windowNumber], previous.identity == identity else {
                // Never seen, or a different window behind a Window ID the
                // server handed out again. The baseline agrees with itself.
                known[windowNumber] = KnownSurface(
                    identity   : identity,
                    frame      : surface.reference.frame,
                    agreed     : !isPrimed,
                    isMissing  : false,
                    hasReturned: false
                )
                if isPrimed { pending = true }
                continue
            }

            var record     = previous
            let wasMissing = record.isMissing
            let sameFrame  = VirtualWindowPlacementCheck.framesMatch(
                record.frame,
                surface.reference.frame
            )
            record.isMissing = false
            record.frame     = surface.reference.frame
            if wasMissing {
                record.hasReturned = true
                record.agreed      = false
            }

            if adopted.contains(windowNumber) {
                // A window the seat holds is judged by the same two agreeing
                // readings as any other surface, and for a sharper reason: a
                // window server frame can be stale, measured on a Qt target as
                // (4032, 2390, 1345, 949) while the window's own body read
                // (1472, 1012, 1345, 949). A frame like that is outside the
                // display, so one reading would report an escape that never
                // happened and spend an attempt on it.
                let hasAgreed = sameFrame && !wasMissing
                record.agreed       = hasAgreed
                known[windowNumber] = record

                guard !virtualBounds.contains(surface.reference.frame) else {
                    // Back under control, so a later escape starts from a full
                    // budget rather than from what this one cost.
                    if hasAgreed { attempts[windowNumber] = nil }
                    continue
                }
                if hasAgreed { changes.append(.leftVirtualDisplay(surface.reference)) }
                else         { pending = true }
                continue
            }

            guard !record.agreed else {
                known[windowNumber] = record
                continue
            }

            guard sameFrame, !wasMissing else {
                known[windowNumber] = record
                pending = true
                continue
            }

            record.agreed       = true
            known[windowNumber] = record

            guard isPrimed, isTransferable(surface, menuLevel: menuLevel),
                  !virtualBounds.contains(surface.reference.frame)
            else { continue }

            changes.append(
                record.hasReturned ? .reappeared(surface.reference)
                                   : .appeared(surface.reference)
            )
        }

        for (windowNumber, previous) in known where !seen.contains(windowNumber) {
            guard !previous.isMissing else { continue }
            var record          = previous
            record.isMissing    = true
            record.agreed       = false
            known[windowNumber] = record
            if adopted.contains(windowNumber) {
                changes.append(.vanished(windowNumber: windowNumber))
            }
        }

        hasPendingCandidate = pending && isPrimed
        isPrimed            = true
        return changes
    }

    /// Whether the seat may spend one more attempt on this Window ID, counting
    /// the attempt when it may. It answers false forever after the budget is
    /// spent, which is the bounded end of an application that keeps putting its
    /// own window back.
    mutating func mayAttempt(_ windowNumber: Int) -> Bool {
        let spent = attempts[windowNumber, default: 0]
        guard spent < Self.maximumAttempts else { return false }
        attempts[windowNumber] = spent + 1
        return true
    }

    /// Forgets what was spent on a window that is now under control, so a
    /// window that leaves the display again later starts from a full budget
    /// rather than from the attempts its first transfer cost.
    mutating func clearAttempts(of windowNumber: Int) {
        attempts[windowNumber] = nil
    }

    /// A surface worth moving: visible, with an area, and not a contextual
    /// menu. A menu is a temporary surface running a modal tracking loop inside
    /// somebody else's process and `useContextMenu` owns it whole; a second
    /// owner deciding to move one is how the tracking loop loses the window it
    /// was drawn for.
    private func isTransferable(_ surface: WindowSurface, menuLevel: Int) -> Bool {
        surface.isVisible && surface.level != menuLevel
            && surface.reference.frame.width > 0 && surface.reference.frame.height > 0
    }
}
