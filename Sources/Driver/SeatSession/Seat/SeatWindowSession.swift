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
nonisolated struct WindowRecord {

    var window  : AdoptedWindow
    let platform: any InputPlatform
    var isStaged: Bool
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

    /// Adds a window and makes it the current target.
    mutating func adopt(_ record: WindowRecord) {
        records[record.window.id] = record
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

    /// Re-reads which of the **other** windows are still on stage after one of
    /// them was staged.
    ///
    /// Stage Manager keeps one window on stage per host, but several windows
    /// stay visible together in the ordinary case, so "the last window `stage`
    /// was called for is the only staged one" is not a fact about Stage
    /// Manager: it is a fact about this process's call order. The reading is
    /// the size, because a stashed window reads as a thumbnail. A reading that
    /// is unavailable leaves the previous value alone: not readable is not
    /// evidence of stashed.
    mutating func refreshStaging(besides windowNumber: Int, reading: (Int) -> CGSize?) {
        for id in records.keys where id != windowNumber {
            guard let record = records[id], let size = reading(id) else { continue }
            records[id]?.isStaged = Self.readsAsStaged(
                serverSize: size,
                fullSize  : record.window.originalFrame.size
            )
        }
    }

    /// True when a window server reading still shows the window at the size it
    /// had in the User Seat. Measured at 90 by 97 points for a stashed window,
    /// so the size is the whole signal that separates staged from stashed.
    static func readsAsStaged(serverSize: CGSize, fullSize: CGSize) -> Bool {
        VirtualWindowPlacementCheck.framesMatch(
            CGRect(origin: .zero, size: serverSize),
            CGRect(origin: .zero, size: fullSize)
        )
    }
}
