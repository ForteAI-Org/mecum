//
//  SeatWindowSession.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import CoreGraphics
import SeatCore
import SeatInput

/// WindowRecord is the seat's own record of an Adopted Window: the public
/// handle plus the facts the caller does not need to carry around.
/// A held window is three separate facts and the record keeps them apart:
/// `window.originalFrame` is the geometry the seat owes the person back,
/// `operationalSize` is the geometry the seat is working with right now, and
/// `isStaged` is the staging evidence, which is read from the window server and
/// never remembered.
nonisolated struct WindowRecord {

    var window  : AdoptedWindow
    let platform: any InputPlatform
    var isStaged: Bool

    /// What full size means for this window right now: the size the seat is
    /// operating it at, which the adoption starts at the size it took the
    /// window in at and a legitimate resize replaces.
    ///
    /// It is not `originalFrame.size`: a window too large for the Virtual
    /// Display is adapted to fit and still owes the person the frame it had
    /// before, so comparing a reading with what it is owed would read every
    /// adapted window as stashed forever and refuse every Command on it.
    ///
    /// It is not immutable either. A person who resizes the window leaves the
    /// record describing a size the window no longer has, which every later
    /// reading then disagrees with: the staging refresh called it a thumbnail
    /// and `stage` waited for a size it would never see again.
    var operationalSize: CGSize
}

/// SeatWindowSession is the pure half of coordinating several windows: which
/// ones the seat holds, which of them is the operating target right now, and
/// which earlier target takes over when the current one is destroyed.
///
/// ## The link between windows is a succession of interactions
///
/// There is no native parentage to read here, and deriving one from titles or
/// coinciding geometry would be a guess dressed as a fact. So the predecessor
/// of a target is simply the window that was the target before it and is still
/// held. A to B to C with B released before C falls back to A, and a seat with
/// nothing left answers nil rather than picking a window nobody asked for.
///
/// A window reached twice keeps one place in the succession, its most recent
/// one, which is what makes A to B to A leave B behind as A's predecessor
/// instead of A being its own.
///
/// It takes no reading and makes no system call: every reading it folds in is
/// passed to it. That is why it is a value type in its own file, and why the
/// whole of A to B to C, out of order releases and the empty case is a unit
/// test with no display attached.
nonisolated struct SeatWindowSession {

    private(set) var records: [Int: WindowRecord] = [:]

    /// Every window that has been the target, oldest first, each at most once.
    /// The last entry is the current target.
    private(set) var targetHistory: [Int] = []

    subscript(windowNumber: Int) -> WindowRecord? {
        get { records[windowNumber] }
        set { records[windowNumber] = newValue }
    }

    var currentTargetNumber: Int? { targetHistory.last }

    var currentTarget: WindowRecord? { currentTargetNumber.flatMap { records[$0] } }

    /// Every window the seat holds, in Window ID order.
    var adoptedWindows: [AdoptedWindow] {
        records.keys.sorted().compactMap { records[$0]?.window }
    }

    /// The processes behind the held windows, each once: two windows of one
    /// application are one process and counting it twice is a wrong answer
    /// about held keys.
    var processIDs: Set<Int32> { Set(records.values.map(\.window.reference.processID)) }

    /// The same processes as attested lifetimes rather than as numbers. A PID
    /// is reused after the application it named terminated, so a window whose
    /// PID matches and whose process serial number does not belongs to a
    /// different application that happened to inherit the number.
    var processIdentities: Set<ProcessIdentity> {
        Set(records.values.compactMap { $0.window.reference.identity?.process })
    }

    /// The platform the seat is already driving this window's own application
    /// with, from any window it holds of the same process lifetime, and nil
    /// when it holds none.
    ///
    /// A preparation policy is a fact about the application and not about the
    /// seat: a dialog Finder opens is the same AppKit application as the window
    /// the consumer adopted, and driving it with another family's recipe
    /// prepares a window that never needed preparing. The match is the attested
    /// lifetime for the reason `processIdentities` is: a reused PID names a
    /// different application, whose platform is not this one's.
    ///
    /// Window ID order, so that a seat which was somehow given two platforms
    /// for one application answers the same way every time rather than by
    /// dictionary order.
    func platform(drivingSameInstanceAs window: WindowReference) -> (any InputPlatform)? {
        guard let process = window.identity?.process else { return nil }
        return records.keys.sorted()
            .compactMap { records[$0] }
            .first { $0.window.reference.identity?.process == process }?
            .platform
    }

    /// Adds a window the seat holds without touching the succession.
    ///
    /// Holding and targeting are two decisions: a window the seat detected by
    /// itself is owned, contained and released like any other, and whether it
    /// becomes the window the seat guards and observes is the selection's
    /// answer and not the adoption's.
    mutating func hold(_ record: WindowRecord) {
        records[record.window.id] = record
    }

    /// Adds a window and makes it the current target.
    mutating func adopt(_ record: WindowRecord) {
        hold(record)
        makeCurrent(record.window.id)
    }

    /// Moves the target, keeping the window's earlier place out of the
    /// succession so that a target is never its own predecessor.
    mutating func makeCurrent(_ windowNumber: Int) {
        targetHistory.removeAll { $0 == windowNumber }
        targetHistory.append(windowNumber)
    }

    /// The most recent earlier target the seat still holds, or nil when there
    /// is none. A window that is no longer held is skipped rather than
    /// answered: the point of the history is a target that still exists.
    func predecessor(of windowNumber: Int) -> Int? {
        guard let position = targetHistory.lastIndex(of: windowNumber) else {
            return targetHistory.last { records[$0] != nil }
        }
        return targetHistory[..<position].last { records[$0] != nil }
    }

    /// Forgets a window and answers the target that takes over. Nil means
    /// either that the window was not the target, or that nothing usable is
    /// left, which the caller reads off `currentTargetNumber`.
    mutating func forget(_ windowNumber: Int) -> Int? {
        let wasTarget = currentTargetNumber == windowNumber
        let successor = wasTarget ? predecessor(of: windowNumber) : nil
        records[windowNumber] = nil
        targetHistory.removeAll { $0 == windowNumber }
        if let successor { makeCurrent(successor) }
        return successor
    }

    /// Re-reads which of the held windows are on stage, from the window server.
    ///
    /// Staging is read and never remembered. Stage Manager stashes a window
    /// whenever another window of the same application is raised, and it tells
    /// nobody, so a flag written at adoption describes the moment of the
    /// adoption and not the window. The reading is the size, because a stashed
    /// window reads as a thumbnail. A reading that is unavailable leaves the
    /// previous value alone: not readable is not evidence of stashed.
    ///
    /// ## Only pertinent evidence moves the flag
    ///
    /// Three readings and not two. At the operational size the window is on
    /// stage; at a thumbnail's share of it the window is stashed; anything
    /// between the two is a window being resized, and it is evidence of
    /// neither, so it leaves the flag where it was for the same reason an
    /// unreadable window does. Treating every disagreement as stashed is what
    /// turned a 20 point resize into a refusal of every Command on a window
    /// nobody had stashed.
    ///
    /// `besides` is the one window whose staging the caller has just
    /// established itself, with a confirmation the window server has not
    /// necessarily caught up with. Every other caller refreshes all of them.
    mutating func refreshStaging(besides windowNumber: Int? = nil, reading: (Int) -> CGSize?) {
        for id in records.keys where id != windowNumber {
            guard let record = records[id], let size = reading(id) else { continue }
            if Self.readsAsStaged(serverSize: size, fullSize: record.operationalSize) {
                records[id]?.isStaged = true
            } else if Self.readsAsThumbnail(serverSize: size, fullSize: record.operationalSize) {
                records[id]?.isStaged = false
            }
        }
    }

    /// Writes a geometry the seat has accepted into a held record.
    ///
    /// The reading becomes the record's reference and, in the same step, what
    /// full size means for the window from now on. They are one write because
    /// they cannot disagree: a record carrying a new frame and the old
    /// operational size describes a window that reads as stashed at the size it
    /// is standing at. What the window is owed on its return is untouched, and
    /// `withReference` is what guarantees that along with the rest of the
    /// record's identity and obligations.
    ///
    /// A reading of another window, or of another lifetime of this one, writes
    /// nothing: accepting geometry is not how a record changes identity.
    mutating func acceptGeometry(_ reference: WindowReference) {
        guard var record = records[reference.windowNumber],
              record.window.reference.hasSameIdentity(as: reference)
        else { return }
        record.window          = record.window.withReference(reference)
        record.operationalSize = reference.frame.size
        record.isStaged        = true
        records[reference.windowNumber] = record
    }

    /// True when a window server reading still shows the window at the size the
    /// seat took it in at. A stashed window reads as a thumbnail whose size is
    /// no constant, measured at 90 by 97 points and at 120 by 121, which is why
    /// the comparison is against the window's own size and never a literal.
    ///
    /// Cross-source: `serverSize` is the window server's and `fullSize` comes
    /// from the accessibility body the adoption recorded, so it takes the
    /// wider tolerance. MarkEdit's 3 pt of width read as stashed at 2, which
    /// refused every Command on a window that was on stage.
    static func readsAsStaged(serverSize: CGSize, fullSize: CGSize) -> Bool {
        VirtualWindowPlacementCheck.sizesMatchAcrossSources(serverSize, fullSize)
    }

    /// True when a window server reading is the positive evidence of a stashed
    /// window: a thumbnail, at a share of the window's own size no resize
    /// reaches. It is asked instead of negating `readsAsStaged`, because the
    /// two together leave the resize in the middle answering neither.
    static func readsAsThumbnail(serverSize: CGSize, fullSize: CGSize) -> Bool {
        VirtualWindowPlacementCheck.sizeReadsAsThumbnail(serverSize, fullSize: fullSize)
    }
}
