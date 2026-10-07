//
//  CommandProvenanceTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// What the record of one pressed Command explains, with no seat and no clock:
/// only the target's own windows, first seen after the press and inside the margin.
@Suite("A Command's provenance")
struct CommandProvenanceTests {

    private static let virtual = FakeGeometry.virtual
    private static let physicalFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
    private static let pressedAt: UInt64 = 1_000_000_000
    private static let handbackAt: UInt64 = 1_050_000_000

    private static func surface(
        _ windowNumber: Int,
        processID     : Int32 = FakeGeometry.targetPID,
        lifetime      : UInt32 = 1,
        level         : Int = 8,
        frame         : CGRect = physicalFrame
    ) -> WindowSurface {
        WindowSurface(
            reference: FakeGeometry.reference(
                frame       : frame,
                processID   : processID,
                windowNumber: windowNumber,
                lifetime    : lifetime
            ),
            level    : level,
            isVisible: true
        )
    }

    /// A record pressed at `pressedAt` whose handback finished at `handbackAt`,
    /// with the target's window 777 listed before the press.
    private static func record(before: Set<Int>? = [FakeGeometry.windowNumber]) -> CommandProvenance {
        var record = CommandProvenance(
            process           : FakeGeometry.identity().process,
            person            : FakeGeometry.reference(frame: physicalFrame, processID: FakeGeometry.userPID, windowNumber: 801),
            windowsBeforePress: before,
            pressedAt         : pressedAt
        )
        record.close(at: handbackAt)
        return record
    }

    @Test("a new window of the target, first seen inside the margin, is the Command's")
    func aNewWindowOfTheTargetIsSighted() {
        var record = Self.record()
        let panel = Self.surface(778)
        let fresh = record.sight([Self.surface(777), panel], at: Self.handbackAt + 730_000_000, virtualBounds: Self.virtual)
        #expect(fresh.map(\.identity.windowNumber) == [778], "the window that was there before the press is not new")
        #expect(record.sighting(of: panel.reference)?.level == 8)

        let again = record.sight([panel], at: Self.handbackAt + 800_000_000, virtualBounds: Self.virtual)
        #expect(again.isEmpty, "one window is sighted once")
    }

    @Test("a window of another process is never the Command's")
    func anotherProcessIsRefused() {
        var record = Self.record()
        let stranger = Self.surface(778, processID: FakeGeometry.distinctProcessID())
        #expect(record.sight([stranger], at: Self.handbackAt + 100, virtualBounds: Self.virtual).isEmpty)
        #expect(record.sighting(of: stranger.reference) == nil)
    }

    @Test("the same PID under another process lifetime is another process")
    func aReusedPIDIsRefused() {
        var record = Self.record()
        let reused = Self.surface(778, lifetime: 2)
        #expect(record.sight([reused], at: Self.handbackAt + 100, virtualBounds: Self.virtual).isEmpty)
        #expect(record.sighting(of: reused.reference) == nil)
    }

    @Test("a window the reading before the press already listed is refused, and so is every window with no such reading")
    func aWindowThatExistedBeforeThePressIsRefused() {
        var record = Self.record(before: [FakeGeometry.windowNumber, 778])
        #expect(record.sight([Self.surface(778)], at: Self.handbackAt + 100, virtualBounds: Self.virtual).isEmpty)

        var unread = Self.record(before: nil)
        #expect(unread.sight([Self.surface(779)], at: Self.handbackAt + 100, virtualBounds: Self.virtual).isEmpty,
                "without the reading nothing can be called new")
    }

    @Test("a window first seen after the margin is refused, and one seen at its last instant is not")
    func aWindowAfterTheMarginIsRefused() {
        var record = Self.record()
        let end = Self.handbackAt + CommandProvenance.marginNanoseconds
        #expect(record.validUntil == end)
        #expect(record.sight([Self.surface(778)], at: end, virtualBounds: Self.virtual).isEmpty)
        #expect(record.sight([Self.surface(779)], at: end - 1, virtualBounds: Self.virtual).map(\.identity.windowNumber) == [779])
    }

    @Test("a window cannot be first seen before the press")
    func nothingPrecedesThePress() {
        var record = Self.record()
        #expect(record.sight([Self.surface(778)], at: Self.pressedAt - 1, virtualBounds: Self.virtual).isEmpty)
    }

    @Test("the record covers the press, the scope and the margin, and nothing else")
    func coverage() {
        var open = CommandProvenance(
            process           : FakeGeometry.identity().process,
            person            : FakeGeometry.reference(frame: Self.physicalFrame),
            windowsBeforePress: [],
            pressedAt         : Self.pressedAt
        )
        #expect(open.covers(Self.pressedAt + 5_000_000_000), "valid for as long as the brief activation runs")
        #expect(!open.covers(Self.pressedAt - 1))
        open.close(at: Self.handbackAt)
        open.close(at: Self.handbackAt + 900_000_000)
        #expect(open.handbackAt == Self.handbackAt, "the first close is the handback")
        #expect(open.covers(Self.handbackAt + CommandProvenance.marginNanoseconds - 1))
        #expect(!open.covers(Self.handbackAt + CommandProvenance.marginNanoseconds))
    }

    @Test("the notice line names the window, the process, the layer, the display and the time since the press")
    func theNoticeLine() {
        var record = Self.record()
        let onPerson = record.sight([Self.surface(778)], at: Self.pressedAt + 780_000_000, virtualBounds: Self.virtual)
        #expect(onPerson.first?.line(pressedAt: Self.pressedAt)
            == "a new window of the Command's target appeared: window 778, process 4242, layer 8, "
                + "on a physical display, 780 ms after the press")

        let inSeat = Self.surface(779, level: 0, frame: CGRect(x: 1700, y: 100, width: 400, height: 300))
        let onVirtual = record.sight([inSeat], at: Self.pressedAt + 40_000_000, virtualBounds: Self.virtual)
        #expect(onVirtual.first?.line(pressedAt: Self.pressedAt).contains("layer 0, on the virtual display, 40 ms") == true)
    }
}
