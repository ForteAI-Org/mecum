import AutomationRuntime
//
//  SeatRuntime.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import CoreGraphics
import Foundation
import PerceptionCore
import PrivateSymbols
import SeatCore
import SeatDriving
import SeatSession
import WindowServerListing

/// SeatRuntime brings the Seat up around one command: virtual display and fence, adopt the
/// application's interaction window, run the body against it, return the window and take the
/// display down, whatever the body did.
enum SeatRuntime {

    static func withSeat(
        _ application: NSRunningApplication,
        _ invocation : Invocation,
        _ body       : (SeatTarget) async throws -> Void
    ) async throws {
        if invocation.flags.contains("allow-unvalidated-build") {
            // The Driver refuses private primitives on a macOS build its ledger has not validated; this
            // is the same research opt-in the Lab exposes, chosen on the command line and said out loud.
            FacilityGate.researchOptInForUnvalidatedBuilds = true
            FileHandle.standardError.write(Data("seat: research opt-in for an unvalidated macOS build\n".utf8))
        }
        let processID = application.processIdentifier
        let rows = try WindowServerWindowListing().windows(ownedBy: processID)
        let requested = invocation.options["window"]
        let matches = requested.map { title in rows.filter { $0.title?.caseInsensitiveCompare(title) == .orderedSame } }
        if let matches, matches.count != 1 {
            throw UsageError.windowSelection(
                title: requested ?? "",
                count: matches.count,
                available: rows.map { "#\($0.number) \"\($0.title ?? "untitled")\"" }
            )
        }
        guard let interaction = matches?.first ?? WindowSurfaceClassifier.classify(rows).interaction else {
            throw UsageError.noSuchApplication("\(application.localizedName ?? "?"): no interaction window to adopt")
        }
        let target = SeatTarget(configuration: SeatHostConfiguration(
            followsNewWindows: invocation.command == "act", restoresUserFocus: true
        ))
        try await target.start()
        do {
            // Focus recovery requires every working window of the driven app on the Seat.
            // Adopt companions first so the requested interaction window is selected last.
            if ["select", "act", "batch"].contains(invocation.command) {
                for row in rows.reversed() where row.number != interaction.number
                    && WindowSurfaceClassifier.isWindowLayer(row.layer)
                    && WindowSurfaceClassifier.isSubstantialWindow(row.frame) {
                    let companion = try await target.adopt(
                        windowNumber: row.number, processID: processID, title: row.title ?? ""
                    )
                    FileHandle.standardError.write(Data("seat: adopted companion #\(companion.id) \"\(companion.title)\"\n".utf8))
                }
            }
            let started = ContinuousClock.now
            let adopted = try await target.adopt(windowNumber: interaction.number, processID: processID,
                                                 title: interaction.title ?? "")
            let frame = adopted.reference.frame
            let placed = "at \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
            let line = "seat: adopted #\(adopted.id) \"\(adopted.title)\" \(placed) in \(started.duration(to: .now))\n"
            FileHandle.standardError.write(Data(line.utf8))
            try await body(target)
        } catch {
            await target.stop()
            throw error
        }
        await target.stop()
        FileHandle.standardError.write(Data("seat: window returned, display down\n".utf8))
    }
}
