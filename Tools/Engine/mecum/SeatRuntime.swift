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
/// display down, whatever the body did, a stop of the invocation included (`hold`).
enum SeatRuntime {

    /// The commands whose Seat follows a window the action opens: `act` as before, and the five inputs,
    /// as the app's session follows them.
    static let followsNewWindows: Set<String> = ["act", "type_text", "press_key", "scroll", "drag", "context_menu"]

    /// The commands that adopt the application's other working windows first, for focus recovery.
    static let adoptsCompanions: Set<String> = followsNewWindows.union(["select", "batch"])

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
            followsNewWindows: Self.followsNewWindows.contains(invocation.command ?? ""), restoresUserFocus: true
        ))
        try await hold(target, bringUp: { target in
            // Focus recovery requires every working window of the driven app on the Seat.
            // Adopt companions first so the requested interaction window is selected last.
            if Self.adoptsCompanions.contains(invocation.command ?? "") {
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
        }, body)
    }

    /// Holds a Seat around a command: brings it up, runs `bringUp` (the adoptions) and `body`, and lets
    /// it go once, whatever they did. A task already cancelled, a stop of the invocation before the Seat,
    /// brings nothing up. The release runs in a task of its own, which does not inherit the command's
    /// cancellation: the stop that cancelled the command never cuts the window's return or the display's
    /// teardown short. What the release did is said; a release that left a window away or the display
    /// up is thrown (`SeatReleaseFailure`), carrying the command's own error when there was one, so it
    /// is never taken for a return that happened. A Seat that fails to start takes itself down.
    static func hold<Seat: SeatHolding>(
        _ seat : Seat,
        bringUp: (Seat) async throws -> Void,
        _ body : (Seat) async throws -> Void,
        say    : (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) async throws {
        try Task.checkCancellation()
        try await seat.start()
        var failure: (any Error)?
        do {
            try await bringUp(seat)
            try await body(seat)
        } catch {
            failure = error
        }
        let release = await Task { @MainActor in await seat.stop() }.value
        say(describe(release))
        if !release.isComplete { throw SeatReleaseFailure(release: release, after: failure) }
        if let failure { throw failure }
    }

    /// The release in one line: the established line when it is complete, what is missing otherwise.
    nonisolated static func describe(_ release: SeatTargetRelease) -> String {
        let windows = release.windows.keys.sorted().map { "#\($0) \(release.windows[$0]!.rawValue)" }.joined(separator: ", ")
        let listed = windows.isEmpty ? "" : " (\(windows))"
        guard !release.isComplete else { return "seat: window returned, display down\(listed)" }
        var missing: [String] = []
        if !release.windowsNotReturned.isEmpty {
            missing.append("window \(release.windowsNotReturned.map { "#\($0)" }.joined(separator: ", ")) not returned")
        }
        if let teardown = release.teardown {
            if !teardown.displayRemoved { missing.append("virtual display not removed") }
            if !teardown.fenceReleased  { missing.append("fence not released") }
        }
        return "seat: release incomplete: \(missing.joined(separator: "; "))\(listed)"
    }
}

/// SeatHolding is the part of a Seat that `SeatRuntime.hold` brings up and lets go: `SeatTarget` in the
/// product, a stand-in in the tests.
@MainActor
protocol SeatHolding: AnyObject, Sendable {
    func start() async throws
    func stop() async -> SeatTargetRelease
}

extension SeatTarget: SeatHolding {}

/// SeatReleaseFailure is a Seat that was let go incompletely: a window not back on the person's displays,
/// or the virtual display or the fence still up. It carries the command's own error, when the command
/// failed or was stopped first, so neither hides the other.
struct SeatReleaseFailure: Error, CustomStringConvertible {
    let release: SeatTargetRelease
    let after: (any Error)?

    var description: String {
        let line = SeatRuntime.describe(release).replacingOccurrences(of: "seat: ", with: "the seat's ")
        return after.map { "\($0); then \(line)" } ?? line
    }
}
