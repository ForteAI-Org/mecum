//
//  WindowServerIdentityMemoTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 17/09/2026.
//

import PrivateSymbols
import SeatCore
import Testing
@testable import WindowPlacement

/// What the per-walk memo of owner connections does, driven with the kit's own
/// three functions replaced by arithmetic ones.
///
/// This is the whole of what the Unit tier can pin here. The chain the shipping
/// code runs needs a real window server and a real process to answer at all, so
/// every reading against a live owner connection belongs to the Live tier; what
/// is provable without one is that the memo answers exactly what the functions
/// answer, that it is keyed by owner connection, and that it holds nothing
/// between two calls.
@Suite("The owner connection memo")
struct WindowServerIdentityMemoTests {

    /// Windows 10 to 19 belong to connection 1, 20 to 29 to connection 2.
    private static let windowOwner: SymbolABI.GetWindowOwner = { _, windowID, ownerConnectionID in
        guard let ownerConnectionID, windowID >= 10 else { return -1 }
        ownerConnectionID.pointee = Int32(windowID / 10)
        return 0
    }

    private static let connectionPSN: SymbolABI.GetConnectionPSN = { connection, psn in
        guard let psn else { return -1 }
        let words = psn.assumingMemoryBound(to: UInt32.self)
        words[0] = 0xA000 &+ UInt32(bitPattern: connection)
        words[1] = UInt32(bitPattern: connection) &* 7
        return 0
    }

    private static let processPID: WindowServerProbe.GetProcessPID = { psn, processID in
        guard let psn, let processID else { return -1 }
        processID.pointee = Int32(psn.load(fromByteOffset: 4, as: UInt32.self)) &+ 100
        return 0
    }

    private static let refusingConnectionPSN: SymbolABI.GetConnectionPSN = { _, _ in -1 }

    private func identity(
        of windowNumber: UInt32,
        memoizing processes: inout WindowServerProbe.OwnerProcesses,
        connectionPSN: SymbolABI.GetConnectionPSN = WindowServerIdentityMemoTests.connectionPSN
    ) -> WindowIdentity? {

        WindowServerProbe.identity(
            windowNumber    : windowNumber,
            connectionID    : 55,
            getWindowOwner  : Self.windowOwner,
            getConnectionPSN: connectionPSN,
            getProcessPID   : Self.processPID,
            memoizing       : &processes
        )
    }

    @Test("a memoized reading is the reading the chain gives unmemoized")
    func memoizedMatchesUnmemoized() throws {
        var fresh11 = WindowServerProbe.OwnerProcesses()
        var fresh12 = WindowServerProbe.OwnerProcesses()
        let unmemoized11 = try #require(identity(of: 11, memoizing: &fresh11))
        let unmemoized12 = try #require(identity(of: 12, memoizing: &fresh12))

        // One walk over two windows of the same application: the second row is
        // answered from the memo and has to be the same answer.
        var walk = WindowServerProbe.OwnerProcesses()
        let memoized11 = try #require(identity(of: 11, memoizing: &walk))
        let memoized12 = try #require(identity(of: 12, memoizing: &walk))

        #expect(memoized11 == unmemoized11)
        #expect(memoized12 == unmemoized12)
        #expect(memoized11.process == memoized12.process)
        #expect(memoized11.windowNumber != memoized12.windowNumber)
    }

    @Test("the memo holds one process per owner connection, not one per window")
    func oneEntryPerConnection() throws {
        var walk = WindowServerProbe.OwnerProcesses()
        _ = try #require(identity(of: 11, memoizing: &walk))
        _ = try #require(identity(of: 12, memoizing: &walk))
        _ = try #require(identity(of: 13, memoizing: &walk))
        #expect(walk.count == 1)
        #expect(walk[1]?.processID == 107)

        _ = try #require(identity(of: 25, memoizing: &walk))
        #expect(walk.count == 2)
        #expect(walk[2]?.processID == 114)
    }

    @Test("a memo of one owner connection says nothing about another")
    func keyedByOwnerConnection() throws {
        let stranger = ProcessIdentity(processID: 999, serialNumberHigh: 9, serialNumberLow: 9)
        var walk: WindowServerProbe.OwnerProcesses = [2: stranger]

        let resolved = try #require(identity(of: 11, memoizing: &walk))
        #expect(resolved.processID == 107)
        #expect(walk[2] == stranger)
    }

    @Test("nothing survives the call the memo was made for")
    func nothingLeaksBetweenCalls() throws {
        let stranger = ProcessIdentity(processID: 999, serialNumberHigh: 9, serialNumberLow: 9)
        var primed: WindowServerProbe.OwnerProcesses = [1: stranger]
        let fromMemo = try #require(identity(of: 11, memoizing: &primed))
        #expect(fromMemo.processID == 999)

        // The next walk starts empty and goes back to the functions: the memo
        // has no storage of its own to carry the stranger forward.
        var next = WindowServerProbe.OwnerProcesses()
        let resolved = try #require(identity(of: 11, memoizing: &next))
        #expect(resolved.processID == 107)
    }

    @Test("an owner that cannot be read is still refused, memo or no memo")
    func refusalsAreUnchanged() {
        var walk = WindowServerProbe.OwnerProcesses()
        #expect(identity(of: 9, memoizing: &walk) == nil)
        #expect(walk.isEmpty)

        // A connection the window server will not describe leaves nothing
        // behind: a failed leg never becomes a remembered process.
        #expect(identity(of: 11, memoizing: &walk, connectionPSN: Self.refusingConnectionPSN) == nil)
        #expect(walk.isEmpty)
    }
}
