import AppKit
import CoreGraphics
import Dispatch
import CursorGuard
import Foundation
import SeatCore
import SeatInput
import SeatSession
import Testing
import VirtualScreens
import WindowPlacement

@Suite(.serialized)
@MainActor
struct UserFocusRecoveryLiveTests {
    @Test("Chrome Print restores the same user window without pointer input",
          .enabled(if: liveSkipReason(needsChrome: true) == nil,
                   Comment(rawValue: liveSkipReason(needsChrome: true) ?? "")))
    func printRestoresUserFocus() async throws {
        LivePump.prepare()
        var controls: [UInt64] = []
        for _ in 0..<1_000 {
            let start = DispatchTime.now().uptimeNanoseconds
            controls.append(DispatchTime.now().uptimeNanoseconds &- start)
        }
        controls.sort()
        print("FOCUS_CLOCK_CONTROL_NS \(controls.reduce(0, +) / UInt64(controls.count))")
        let person = UserSeatState.capture()
        let displaysBefore = Set(try DisplayList.online())
        let usesKeyRecords = ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_KEY_RECORDS"] == "1"
        var configuration = SeatHostConfiguration(restoresUserFocus: true, allowUnvalidatedFocusRecovery: true)
        configuration.focusRecoveryUsesKeyRecords = usesKeyRecords
        let host = SeatHost(configuration: configuration)
        try await host.start()
        var browser: OwnBrowserTarget?
        do {
            let target = try OwnBrowserTarget.launched()
            browser = target
            let seat = try host.makeSeat()
            var adopted = try await seat.adopt(target.reference, platform: ChromiumPlatform())
            if !seat.isStaged(adopted) { adopted = try await seat.stage(adopted) }
            NSRunningApplication(processIdentifier: person.frontmostProcessID)?.activate()
            LivePump.run(for: 0.8)
            var observations = [FocusAXObservation.read(person.frontmostProcessID, phase: "before")]
            let userWindow = try #require(observations.last?.windowNumber)
            if ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_SCENARIO"] == "warm-menu" {
                let warmTurn = try await seat.acquire()
                let warmGeometry = try #require(WindowServerProbe.geometry(of: adopted.id))
                let warmReceipt = try await seat.useContextMenu(
                    openedAt: try #require(target.probePoint(within: warmGeometry.frame)),
                    of      : adopted,
                    turn    : warmTurn
                ) { _ in nil }
                try #require(warmReceipt.closedBy != .chosenItem)
                try seat.release(warmTurn)
                LivePump.run(for: 0.3)
            }
            let before = UserSeatState.capture()
            try #require(before.frontmostProcessID == person.frontmostProcessID)
            let fence = try #require(host.fence)
            let hid = fence.snapshot().observedEventCount
            let bounds = CGDisplayBounds(try #require(host.displayID))
            let turn = try await seat.acquire()
            let geometry = try #require(WindowServerProbe.geometry(of: adopted.id))
            let sampler = Process()
            let sampleOutput = Pipe()
            var samplerLaunched = false
            if let path = ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_SAMPLER"] {
                sampler.executableURL = URL(fileURLWithPath: path)
                sampler.arguments = [String(userWindow), String(adopted.id),
                                     ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_SAMPLE_US"] ?? "100"]
                sampler.standardOutput = sampleOutput
            }
            defer { if sampler.isRunning { sampler.terminate() } }
            let receipt = try await seat.useContextMenu(
                openedAt: try #require(target.probePoint(within: geometry.frame)),
                of      : adopted,
                turn    : turn
            ) { menu in
                do {
                    let point = try MenuImageChoice.point(for: ["Print...", "Print…", "Stampa...", "Stampa…"],
                                                          in: menu.window)
                    if sampler.executableURL != nil {
                        try sampler.run()
                        samplerLaunched = true
                    }
                    return point
                } catch { Issue.record("Print was not uniquely identified: \(error)"); return nil }
            }
            #expect(receipt.chosenPoint != nil)
            #expect(receipt.closedBy == .chosenItem)
            let restored = LivePump.run(until: {
                seat.lastFocusRecovery?.outcome == .restored && seat.state.acceptsCommands
            }, timeout: 3)
            let report = try #require(seat.lastFocusRecovery, "No activation was recovered; this test did not exercise Print")
            #expect(restored, "\(report)")
            #expect(report.destination?.windowNumber == userWindow)
            #expect(report.requestCode == 0)
            #expect(report.timing.actionPreparationNanoseconds > 0)
            #expect(report.timing.preparedWindowsNanoseconds > 0)
            #expect(report.timing.preparedIdentityNanoseconds > 0)
            #expect(report.timing.ownerLookupNanoseconds == 0)
            #expect(report.timing.psnLookupNanoseconds == 0)
            #expect(report.timing.preparedSnapshotAgeNanoseconds <= 1_000_000_000)
            #expect((report.timing.firstKeyNanoseconds > 0) == usesKeyRecords)
            #expect((report.timing.secondKeyNanoseconds > 0) == usesKeyRecords)
            #expect(report.activatingProcessID == target.processID)
            #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == person.frontmostProcessID)
            observations.append(FocusAXObservation.read(person.frontmostProcessID, phase: "after"))
            let focusedAfter = observations.last?.windowNumber
            #expect(focusedAfter == userWindow)
            for index in 0..<4 {
                LivePump.run(for: 0.05)
                observations.append(FocusAXObservation.read(person.frontmostProcessID, phase: "stability-\(index)"))
                #expect(observations.last?.windowNumber == userWindow,
                        "Focus must remain on the recovered window after the menu action")
            }
            let after = UserSeatState.capture()
            let physicalEvents = fence.snapshot().observedEventCount &- hid
            #expect(before.cursor == after.cursor)
            #expect(physicalEvents == 0, "Physical activity makes this focus measurement inconclusive")
            #expect(bounds.contains(try #require(WindowServerProbe.geometry(of: adopted.id)).frame))
            #expect(seat.unconfirmedCommandCount == 0)
            if ProcessInfo.processInfo.environment["AGENTSEAT_FOCUS_BUDGET"] == "1" {
                #expect((report.frontmostRestoredNanoseconds ?? UInt64.max) <= 8_000_000,
                        "Focus exceeded the requested 8 ms detection-to-frontmost budget")
            }
            if samplerLaunched {
                sampler.waitUntilExit()
                #expect(sampler.terminationStatus == 0, "The independent focus sampler did not complete")
                let bytes = sampleOutput.fileHandleForReading.readDataToEndOfFile()
                print(String(decoding: bytes, as: UTF8.self))
            }
            let oracleData = try JSONEncoder().encode(observations)
            print("FOCUS_AX \(String(decoding: oracleData, as: UTF8.self))")
            let validation: [String: Bool] = [
                "cursor_unchanged": before.cursor == after.cursor,
                "no_physical_input": physicalEvents == 0,
                "same_user_app": before.frontmostProcessID == after.frontmostProcessID,
                "same_user_window": observations.allSatisfy { $0.windowNumber == userWindow },
                "recovered": restored,
                "target_virtual": bounds.contains(WindowServerProbe.geometry(of: adopted.id)?.frame ?? .null),
                "no_uncertain_commands": seat.unconfirmedCommandCount == 0
            ]
            let validationData = try JSONEncoder().encode(validation)
            print("FOCUS_VALIDATION \(String(decoding: validationData, as: UTF8.self))")
            let timingData = try JSONEncoder().encode(report.timing)
            print("FOCUS_TIMING \(String(decoding: timingData, as: UTF8.self))")
            print("FOCUS recovery=\(report.outcome.rawValue) frontmost=\(report.frontmostRestoredNanoseconds.map { Double($0) / 1e6 } ?? -1) ms detection-to-verification=\(Double(report.elapsedNanoseconds) / 1e6) ms request=\(report.requestCode ?? -999) cursor=\(before.cursor)->\(after.cursor) HID=\(physicalEvents)")
            try seat.release(turn)
            target.terminate()
            browser = nil
            let teardown = await host.stop()
            #expect(teardown.displayRemoved)
            #expect(Set(try DisplayList.online()) == displaysBefore)
        } catch {
            browser?.terminate()
            _ = await host.stop()
            throw error
        }
    }

}
