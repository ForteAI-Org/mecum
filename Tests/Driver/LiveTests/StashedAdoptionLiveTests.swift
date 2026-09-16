//
//  StashedAdoptionLiveTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import SeatCore
import SeatInput
import SeatSession
import TargetReader
import Testing
import VirtualScreens
import WindowPlacement

@Suite(.serialized)
@MainActor
struct StashedAdoptionLiveTests {
    @Test("Chrome stashed on the physical display can be adopted and returned",
          .enabled(if: liveSkipReason(optIn: "AGENTSEAT_STASHED_ADOPTION", needsChrome: true) == nil,
                   Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_STASHED_ADOPTION", needsChrome: true) ?? "")))
    func stashedBeforeAdoption() async throws {
        LivePump.prepare()
        let person = UserSeatState.capture()
        let displaysBefore = Set(try DisplayList.online())
        let host = SeatHost()
        var browser: OwnBrowserTarget?
        do {
            try await host.start()
            let target = try OwnBrowserTarget.launched()
            browser = target
            NSRunningApplication(processIdentifier: person.frontmostProcessID)?.activate()
            LivePump.run(for: 1)
            let snapshot = try WindowReader.windowSnapshot(
                processID: target.processID,
                windowNumber: target.windowNumber
            )
            let original = snapshot.reference
            let thumbnail = try #require(WindowServerProbe.geometry(of: target.windowNumber))
            let bounds = CGDisplayBounds(try #require(host.displayID))
            print("ADOPTION_BEFORE ax=\(original.frame) ws=\(thumbnail.frame) virtual=\(bounds)")
            try #require(thumbnail.frame.width < original.frame.width - 2,
                         "This opt-in regression needs Stage Manager to stash Chrome before adoption")
            try #require(!bounds.contains(thumbnail.frame), "The thumbnail must still be on a physical display")
            let before = UserSeatState.capture()
            try #require(before.frontmostProcessID == person.frontmostProcessID)
            let seat = try host.makeSeat()
            let adopted = try await seat.adopt(original, platform: ChromiumPlatform())
            let server = try #require(WindowServerProbe.geometry(of: adopted.id))
            let observed = try WindowReader.windowSnapshot(
                processID: target.processID,
                windowNumber: adopted.id
            )
            #expect(seat.isStaged(adopted))
            #expect(bounds.contains(server.frame))
            #expect(bounds.contains(observed.windowFrame))
            #expect(VirtualWindowPlacementCheck.framesMatch(server.frame, observed.windowFrame))
            #expect(!observed.applicationIsActive)
            #expect(UserSeatState.capture() == before)
            print("ADOPTION_PLACED ax=\(observed.windowFrame) ws=\(server.frame) inactive=\(!observed.applicationIsActive)")
            let released = await seat.release(adopted)
            #expect(released == .returned)
            LivePump.run(for: 0.3)
            let returned = try WindowReader.windowSnapshot(
                processID: target.processID,
                windowNumber: adopted.id
            )
            #expect(VirtualWindowPlacementCheck.framesMatch(returned.windowFrame, original.frame))
            print("ADOPTION_RETURN outcome=\(released.rawValue) ax=\(returned.windowFrame)")
            target.terminate()
            browser = nil
            let teardown = await host.stop()
            #expect(teardown.displayRemoved)
            #expect(teardown.fenceReleased)
            #expect(Set(try DisplayList.online()) == displaysBefore)
        } catch {
            _ = await host.stop()
            browser?.terminate()
            throw error
        }
    }
}
