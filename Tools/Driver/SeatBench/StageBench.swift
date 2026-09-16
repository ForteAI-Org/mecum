//
//  StageBench.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import PrivateSymbols
import SeatCore
import SeatInput
import SeatSession
import WindowPlacement

/// StageBench times `stage`: bringing a window Stage Manager has stashed back
/// to full size on the Virtual Display, against the 1 s p95 of spec section 8.
///
/// It went unmeasured for a long time because of Stage Manager's own rule: it
/// groups windows **by application**, so one process
/// cannot stash its own window no matter how many it opens. A second process is
/// needed, and the kit ships no application, so the second process is the
/// consumer's: `AGENTSEAT_FIXTURE_APP` names a binary that comes up as a
/// cooperative target when launched with `--session <token>` and publishes its
/// window identity as JSON. Without that variable there is nothing to stash and
/// the row stays `unsupported`, with the reason, rather than carrying a number
/// that proves nothing.
///
/// The cycle per sample: put this driver's own window on stage, which is what
/// makes Stage Manager stash the target, then time `AgentSeat.stage` from the
/// call to the second agreeing window server reading at full size. The path
/// measured is the public one, `kAXRaiseAction` plus the two confirmations, and
/// not a private shortcut past it.
@MainActor
enum StageBench {

    static let name = "stage"

    /// The identity the target publishes. Only the four fields this driver
    /// needs are declared: a consumer's own report may carry any number more.
    private struct TargetReport: Decodable {
        let sessionToken: String
        let writtenAt   : TimeInterval
        let processID    : Int32
        let windowNumber : Int
        let windowX      : Double
        let windowY      : Double
        let windowWidth  : Double
        let windowHeight : Double

        static func url(sessionToken: String) -> URL {
            URL(fileURLWithPath: "/tmp/agentseat-fixture-\(getuid())-\(sessionToken).json")
        }

        static func read(sessionToken: String) -> TargetReport? {
            guard
                let data   = try? Data(contentsOf: url(sessionToken: sessionToken)),
                let report = try? JSONDecoder().decode(TargetReport.self, from: data),
                report.sessionToken == sessionToken,
                report.windowNumber > 0,
                Date().timeIntervalSince1970 - report.writtenAt <= 3
            else {
                return nil
            }
            return report
        }
    }

    static func run(
        cycles           : Int,
        outputPath       : String?,
        baselineDirectory: String?
    ) -> Bool {

        let clock = Clock()
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        MonitorBench.pump(0.2)

        guard let binary = ProcessInfo.processInfo.environment["AGENTSEAT_FIXTURE_APP"],
              !binary.isEmpty,
              FileManager.default.isExecutableFile(atPath: binary)
        else {
            report(unsupported: """
                AGENTSEAT_FIXTURE_APP does not name an executable. Stage Manager groups windows by \
                application, so a stashed window needs a second process, and the kit ships none: \
                point the variable at a consumer's instrumented binary that comes up with \
                `--session <token>`.
                """, clock: clock, outputPath: outputPath)
            return true
        }
        guard Permissions.preflight(.accessibility) else {
            print("\(name): FAIL, Accessibility is not granted, so no window can be raised")
            return false
        }

        let sessionToken = "bench-\(ProcessInfo.processInfo.processIdentifier)"
        let process      = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments     = ["--session", sessionToken]
        try? FileManager.default.removeItem(at: TargetReport.url(sessionToken: sessionToken))
        do { try process.run() }
        catch {
            print("\(name): FAIL, the instrumented target did not start: \(error)")
            return false
        }
        defer {
            process.terminate()
            try? FileManager.default.removeItem(at: TargetReport.url(sessionToken: sessionToken))
        }

        var target: TargetReport?
        guard MonitorBench.pump(
            until  : {
                target = TargetReport.read(sessionToken: sessionToken)
                return target != nil
            },
            timeout: 20
        ), let target else {
            print("\(name): FAIL, the instrumented target never published a window number")
            return false
        }
        let home = CGPoint(x: target.windowX, y: target.windowY)

        do {
            let host = SeatHost(configuration: SeatHostConfiguration())
            try MonitorBench.awaiting { try await host.start() }
            defer {
                _ = try? MonitorBench.awaiting(timeout: 20) { await host.stop() }
                MonitorBench.pump(0.5)
            }
            guard let displayID = host.displayID else {
                print("\(name): FAIL, the host came up without a display")
                return false
            }
            let bounds = CGDisplayBounds(displayID)

            // This driver's own window, the one whose arrival stashes the
            // target. It is the second application on the display, which is the
            // whole precondition of the measurement.
            //
            // The frame comes from `NSScreen` and not from `CGDisplayBounds`:
            // AppKit counts y upwards from the primary display and Quartz
            // counts it down, and a window placed with the wrong one lands on
            // the person's own screen, where nothing is ever stashed. The first
            // run of this benchmark did exactly that.
            guard MonitorBench.pump(until: { screen(for: displayID) != nil }, timeout: 5),
                  let virtualScreen = screen(for: displayID)
            else {
                print("\(name): FAIL, AppKit never published an NSScreen for \(displayID)")
                return false
            }
            let ownFrame = NSRect(
                x     : virtualScreen.frame.minX + 40,
                y     : virtualScreen.frame.minY + 40,
                width : 700,
                height: 500
            )
            let ownWindow = NSWindow(
                contentRect: ownFrame,
                styleMask  : [.titled],
                backing    : .buffered,
                defer      : false,
                screen     : virtualScreen
            )
            ownWindow.title = "AgentSeatKit stage bench"
            ownWindow.setFrameOrigin(ownFrame.origin)
            ownWindow.orderFrontRegardless()
            MonitorBench.pump(0.4)
            print("\(name): own window on screen \(ownWindow.screen?.frame ?? .null), "
                + "virtual screen \(virtualScreen.frame)")

            let seat    = try host.makeSeat()
            let full    = CGSize(width: target.windowWidth, height: target.windowHeight)
            guard let targetReference = WindowServerProbe.geometry(of: target.windowNumber),
                  targetReference.processID == target.processID
            else {
                print("\(name): FAIL, WindowServer could not attest the target window")
                return false
            }
            let adopted = try MonitorBench.awaiting(timeout: 20) {
                try await seat.adopt(
                    targetReference.replacingFrame(CGRect(origin: home, size: full)),
                    platform: AppKitPlatform(),
                    title   : "instrumented target"
                )
            }
            defer {
                _ = try? MonitorBench.awaiting(timeout: 20) {
                    await seat.release(adopted, .returnToUserSeat)
                }
                MonitorBench.pump(0.4)
            }

            var nanoseconds : [Double] = []
            var alreadyStaged = 0
            for cycle in 1...cycles {
                // Stage Manager stashes whatever was on stage when another
                // application's window comes forward.
                ownWindow.orderFrontRegardless()
                MonitorBench.pump(0.8)

                if isFullSize(target.windowNumber, size: full, within: bounds) {
                    // Nothing was stashed, so there is nothing to time: counted
                    // and reported instead of timing a no-op and calling it a
                    // stage.
                    alreadyStaged += 1
                    continue
                }

                let start = clock.tick()
                _ = try MonitorBench.awaiting(timeout: 20) { try await seat.stage(adopted) }
                let ticks = clock.tick() &- start
                nanoseconds.append(Double(ticks) * clock.nanosecondsPerTick)
                print(String(
                    format: "  cycle %d: stage in %.0f ms",
                    cycle, Double(ticks) * clock.nanosecondsPerTick / 1e6
                ))
                MonitorBench.pump(0.4)
            }

            guard !nanoseconds.isEmpty else {
                report(unsupported: """
                    Stage Manager never stashed the target in \(cycles) cycles, and not because \
                    it is off: with it on, five inactive applications were observed thumbnailed \
                    at once on the physical display, 136x187 and the like in the strip at x=15. \
                    A stash follows an application activation, and this driver never activates \
                    anything, so it cannot cause one; and no window has ever been observed \
                    stashed on a virtual display, which is where the target sits. The primitive \
                    is verified on this build and unmeasurable without activating an application.
                    """, clock: clock, outputPath: outputPath)
                print("\(name): unsupported, Stage Manager stashed nothing in \(cycles) cycles")
                return true
            }

            let sample = Sample(
                name       : name,
                nanoseconds: nanoseconds,
                allocations: 0,
                frees      : 0
            )
            print(sample.line)
            if alreadyStaged > 0 {
                print("  \(alreadyStaged) of \(cycles) cycles were never stashed and are not timed")
            }
            let passed = sample.p95 <= Budget.stageNanosecondsP95
            print(String(
                format: "%@ stage p95: %.0f ms (budget %.0f ms)",
                passed ? "PASS" : "FAIL",
                sample.p95 / 1e6, Budget.stageNanosecondsP95 / 1e6
            ))

            var row = sample.json(budgetLimit: Budget.stageNanosecondsP95, passed: passed)
            row["cycles_requested"]     = cycles
            row["cycles_never_stashed"] = alreadyStaged
            let output: [String: Any] = [
                "schema_version": 1,
                "benchmark"     : name,
                "provenance"    : provenance(clock: clock),
                "scenario"      : "a real virtual display, a consumer's instrumented target adopted "
                    + "on it and this driver's own window brought forward to make Stage Manager "
                    + "stash it; timed from AgentSeat.stage to the second agreeing window server "
                    + "reading at full size",
                "results"       : [row],
            ]
            if let outputPath { writeJSON(output, to: outputPath) }
            if let baselineDirectory {
                mergeIntoBaseline(output, at: baselinePath(in: baselineDirectory))
            }
            print(passed ? "\(name): PASS" : "\(name): FAIL")
            return passed

        } catch {
            print("\(name): FAIL, \(error)")
            return false
        }
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == displayID
        }
    }

    /// Whether the window server shows the window at its own full size inside
    /// the display, which is what tells a staged window from a Stage Manager
    /// thumbnail.
    private static func isFullSize(
        _ windowNumber: Int,
        size          : CGSize,
        within bounds : CGRect
    ) -> Bool {
        guard let frame = WindowServerProbe.geometry(of: windowNumber)?.frame else { return false }
        return bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
            && abs(frame.width - size.width) <= 2
    }

    private static func report(unsupported reason: String, clock: Clock, outputPath: String?) {
        print("\(name): unsupported, \(reason)")
        guard let outputPath else { return }
        writeJSON(
            [
                "schema_version": 1,
                "benchmark"     : name,
                "provenance"    : provenance(clock: clock),
                "results"       : [
                    [
                        "name"  : name,
                        "unit"  : "ns",
                        "n"     : 0,
                        "status": "unsupported",
                        "reason": reason,
                        "budget": ["limit": Budget.stageNanosecondsP95, "passed": false],
                    ] as [String: Any],
                ],
            ],
            to: outputPath
        )
    }
}
