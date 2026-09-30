//
//  HiddenWindowReturnsTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 29/09/2026.
//

import CoreGraphics
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// The ledger of windows a release left hidden, read one pass at a time: no
/// watch runs here, and no window belongs to a person.
@MainActor
@Suite("Windows hidden by their application at release")
struct HiddenWindowReturnsTests {

    static let home   = CGRect(x: 100, y: 100, width: 910, height: 640)
    static let away   = CGRect(x: 2337, y: 1382, width: 910, height: 640)
    static let number = 74_212

    static var hidden: AdoptedWindow {
        AdoptedWindow(
            reference    : FakeGeometry.reference(frame: away, windowNumber: number),
            originalFrame: home
        )
    }

    /// A ledger over one window whose readings the test writes.
    @MainActor
    final class Server {
        var frame: CGRect?
        var exists = true
        let placing = FakePlacing()

        func ledger() -> HiddenWindowReturns {
            HiddenWindowReturns(
                placing : placing,
                geometry: { [unowned self] number in
                    frame.map { FakeGeometry.reference(frame: $0, windowNumber: number) }
                },
                identity: { [unowned self] number in
                    exists ? FakeGeometry.reference(frame: .zero, windowNumber: number).identity : nil
                },
                cadence : .seconds(3_600)
            )
        }
    }

    @Test("a window still hidden is kept, and one shown again is moved home and then let go")
    func shownAgainGoesHome() {
        let server = Server()
        let ledger = server.ledger()
        ledger.owe(Self.hidden)

        ledger.check()
        #expect(ledger.owedWindowNumbers == [Self.number])
        #expect(server.placing.moves.isEmpty)

        server.frame = Self.away
        ledger.check()
        #expect(server.placing.moves == [Self.home.origin])

        server.frame = Self.home
        ledger.check()
        #expect(ledger.owedWindowNumbers.isEmpty)
        #expect(server.placing.moves.count == 1)
    }

    @Test("a destroyed window and one a seat took in are forgotten without a move")
    func destroyedOrTakenInIsForgotten() {
        let server = Server()
        let ledger = server.ledger()
        ledger.owe(Self.hidden)
        server.exists = false
        server.frame  = Self.away
        ledger.check()
        #expect(ledger.owedWindowNumbers.isEmpty)

        server.exists = true
        ledger.owe(Self.hidden)
        ledger.forgive(Self.number)
        ledger.check()
        #expect(ledger.owedWindowNumbers.isEmpty)
        #expect(server.placing.moves.isEmpty)
    }

    @Test("an application that keeps its own position is not fought past the move limit")
    func theMoveLimitEndsTheReturn() {
        let server = Server()
        let ledger = server.ledger()
        ledger.owe(Self.hidden)
        server.frame = Self.away
        for _ in 0...HiddenWindowReturns.moveLimit { ledger.check() }

        #expect(server.placing.moves.count == HiddenWindowReturns.moveLimit)
        #expect(ledger.owedWindowNumbers.isEmpty)
    }

    @Test("a release of a window its application ordered out owes the return, and taking it in again settles it")
    func theSeatOwesAndForgives() async throws {
        let sensing = FakeSensing()
        let (seat, windows) = try await MultiWindowTests.seat(
            sensing: sensing,
            also   : [MultiWindowTests.secondWindowNumber]
        )
        let ledger = Server().ledger()
        seat.hiddenReturns = ledger
        sensing.orderedOut = [MultiWindowTests.secondWindowNumber]

        let outcome = await seat.release(windows[1])

        #expect(outcome == .returnsWhenShown)
        #expect(ledger.owedWindowNumbers == [MultiWindowTests.secondWindowNumber])

        sensing.orderedOut = []
        _ = try await seat.adopt(windows[1].reference, platform: AppKitPlatform())
        #expect(ledger.owedWindowNumbers.isEmpty)
    }
}
