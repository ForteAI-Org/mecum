//
//  SheetGeometryTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 05/10/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

/// A sheet that settles at a new size where it stands, which is what a Save
/// panel's disclosure does.
///
/// The recovery watches the sheet's host, because a sheet owes no return, so a
/// geometry Issue read on the sheet's own record sent an episode after a host
/// that had not moved. The episode finished, the sheet's record kept the size it
/// was adopted at, and every later Command on the sheet looped on the same
/// Issue.
@MainActor
@Suite("A sheet that settles at a new size")
struct SheetGeometryTests {

    static let sheetWindowNumber = 880

    @Test("a sheet grown inside the seat takes its new size, and the next Command goes out")
    func aGrownSheetTakesItsNewSize() async throws {

        let sensing   = FakeSensing()
        let sender    = FakeSender()
        let reader    = ControlledSurfaceReader(sensing: sensing)
        let discovery = GestureEndpointRoutingTests.Discovery()
        let seat      = makeSeat(
            sensing  : sensing,
            sender   : sender,
            marker   : 1_931,
            reader   : reader,
            source   : ControlledObservationSource(sensing: sensing),
            clock    : ControlledContentClock(),
            endpoints: discovery.discovery
        )

        let host = try await seat.adopt(
            FakeGeometry.reference(frame: FakeGeometry.userSeatWindow.frame),
            platform: AppKitPlatform()
        )
        let inbound = FakeGeometry.reference(
            frame       : FakeGeometry.adoptedWindow.frame.offsetBy(dx: 60, dy: 60),
            windowNumber: Self.sheetWindowNumber
        )
        sensing.additionalWindows[Self.sheetWindowNumber] = inbound
        reader.roles[Self.sheetWindowNumber]  = .dialog
        reader.modals[Self.sheetWindowNumber] = .window(try #require(host.reference.identity))
        seat.refreshTargetReadings()
        seat.refreshTargetReadings()
        let sheet = try await seat.adopt(inbound, platform: AppKitPlatform())
        #expect(sheet.owesNoReturn, "the attached modal is the evidence the adoption had")
        sensing.additionalWindows[Self.sheetWindowNumber] = sheet.reference
        // A sheet the application opens is held beside the target, and the guard stays on the host.
        _ = try await seat.switchTarget(to: host)
        #expect(seat.currentTarget?.id == host.id)

        // The disclosure expands the sheet in place, still inside the seat.
        let adopted = sheet.reference.frame
        let grown   = sheet.reference.replacingFrame(CGRect(
            origin: adopted.origin,
            size  : CGSize(width: adopted.width + 300, height: adopted.height + 120)
        ))
        sensing.additionalWindows[Self.sheetWindowNumber] = grown
        #expect(sensing.virtualDisplayBounds.contains(grown.frame))
        let identity = try #require(grown.identity)
        discovery.identities[Self.sheetWindowNumber] = identity

        let point = CGPoint(x: grown.frame.midX, y: grown.frame.midY)
        var refusals = 0
        for _ in 0..<3 {
            let observation = try await observedReference(seat)
            discovery.answer = .success(try GestureEndpointRoutingTests.endpoint(
                try #require(WindowGeometryObservation(
                    window     : grown,
                    scaleFactor: 2,
                    version    : GeometryObservationVersion(observerGeneration: 5, sequence: 1)
                )),
                relation      : .logicalSurface,
                logicalSurface: identity,
                generation    : observation.selectionGeneration,
                hostProcessID : host.reference.processID
            ))
            let turn = try await seat.acquire()
            do {
                let receipt = try await seat.send(
                    GestureEndpointRoutingTests.click(at: point),
                    observation: observation,
                    turn       : turn
                )
                try seat.confirm(receipt, .unknown)
                try seat.release(turn)
                break
            } catch {
                refusals += 1
                try? seat.release(turn)
                _ = await AppWindowFollowTests.settle({ seat.state == .ready }, within: 5)
            }
        }

        #expect(sender.sent.count == 1, "the Command goes out once the sheet's size is accepted")
        #expect(refusals <= 1, "one refusal at most, never a loop on the host")
        #expect(seat.state == .ready)
        #expect(seat.currentTarget?.id == host.id, "the host stays the target")
        #expect(seat.session[Self.sheetWindowNumber]?.window.reference.frame == grown.frame)
        #expect(seat.session[Self.sheetWindowNumber]?.window.owesNoReturn == true,
                "accepting a size changes nothing the sheet owes")
    }
}
