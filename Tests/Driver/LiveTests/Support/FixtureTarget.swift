//
//  FixtureTarget.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import SeatCore
import SeatInput
import WindowPlacement

/// FixtureTarget is the AppKit half of the matrix: an instrumented application
/// **the consumer owns**, launched as a process and read through the file it
/// publishes.
///
/// The kit ships no application, so this suite cannot name one. It takes the
/// path of a binary from `AGENTSEAT_FIXTURE_APP`, launches it with
/// `--session <token>`, and expects a JSON report at the path the token names
/// (`FixtureReport.url(sessionToken:)`). Every row that needs it is skipped,
/// with the reason printed, when the variable is not set.
///
/// It is the only target that can prove a routed event landed on the control
/// and not merely inside the window, because it hit tests its own controls and
/// says which view the last event actually reached.
@MainActor
final class FixtureTarget: MatrixTarget {

    let name     = "AppKit fixture"
    let platform: any InputPlatform = AppKitPlatform()

    /// The consumer's instrumented binary, or `nil` when the variable that
    /// names it is unset: the kit knows no consumer to fall back to.
    nonisolated static var binaryURL: URL? {
        ProcessInfo.processInfo.environment["AGENTSEAT_FIXTURE_APP"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    nonisolated static var isAvailable: Bool {
        binaryURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
    }

    /// Why the rows that need an instrumented target are skipped, as one line.
    nonisolated static var unavailableReason: String {
        guard let binaryURL else {
            return """
                AGENTSEAT_FIXTURE_APP is not set. The kit ships no application: point it at the \
                consumer's instrumented binary, which must come up as the cooperative target when \
                launched with `--session <token>` and publish its report at \
                \(FixtureReport.url(sessionToken: "<token>").path).
                """
        }
        guard !isAvailable else { return "" }
        return "AGENTSEAT_FIXTURE_APP names \(binaryURL.path), which is not an executable file."
    }

    /// Starts the target and waits, pumping, until it published a report the
    /// driver could act on: the first ones go out before AppKit has given the
    /// window a number, and a Window ID of zero is not an identity.
    static func launched(timeout: Double = 20) throws -> FixtureTarget {
        guard let binaryURL else { throw FixtureFailure.notConfigured }

        let sessionToken = "live-\(ProcessInfo.processInfo.processIdentifier)-"
            + String(UInt32.random(in: .min ... .max), radix: 36)
        let reportURL    = FixtureReport.url(sessionToken: sessionToken)
        try? FileManager.default.removeItem(at: reportURL)

        let process            = Process()
        process.executableURL  = binaryURL
        process.arguments      = ["--session", sessionToken]
        do { try process.run() }
        catch { throw FixtureFailure.notLaunched("\(error)") }

        var report: FixtureReport?
        let published = LivePump.run(
            until  : {
                report = FixtureReport.read(sessionToken: sessionToken)
                return report?.windowNumber ?? 0 > 0
            },
            timeout: timeout
        )
        guard published, let report else {
            process.terminate()
            throw FixtureFailure.neverPublished(reportURL.path)
        }
        return FixtureTarget(
            process     : process,
            sessionToken: sessionToken,
            report      : report
        )
    }

    private let process     : Process
    private let sessionToken: String
    private(set) var latest : FixtureReport

    private init(process: Process, sessionToken: String, report: FixtureReport) {
        self.process      = process
        self.sessionToken = sessionToken
        self.latest       = report
    }

    func terminate() {
        process.terminate()
        try? FileManager.default.removeItem(at: FixtureReport.url(sessionToken: sessionToken))
    }

    var window: WindowReference {
        let frame = CGRect(
            x     : latest.windowX,
            y     : latest.windowY,
            width : latest.windowWidth,
            height: latest.windowHeight
        )
        guard let reference = WindowServerProbe.geometry(of: latest.windowNumber),
              reference.processID == latest.processID
        else {
            return WindowReference(
                processID   : latest.processID,
                windowNumber: latest.windowNumber,
                frame       : frame
            )
        }
        return reference.replacingFrame(frame)
    }

    var expectedSize: CGSize {
        CGSize(width: latest.windowWidth, height: latest.windowHeight)
    }

    var isInternallyActive: Bool { latest.applicationIsActive || latest.windowIsKey }

    var diagnostics: String {
        "last event \(latest.lastEvent), window \(latest.lastMouseWindowNumber), "
            + "hit \(latest.lastMouseHitView), scroll hit \(latest.lastScrollHitView)"
    }

    func refresh() {
        if let report = FixtureReport.read(sessionToken: sessionToken) { latest = report }
    }

    func state() -> [String: Double] {
        refresh()
        return [
            "clicks" : Double(latest.buttonPressCount),
            "keys"   : Double(latest.textValue.filter { $0 == "Z" }.count),
            "wheel"  : latest.scrollOffsetY,
            "drag"   : latest.sliderValue,
            "downs"  : Double(latest.syntheticMouseDownCount),
            "drags"  : Double(latest.syntheticMouseDragCount),
            "ups"    : Double(latest.syntheticMouseUpCount),
            "scrolls": Double(latest.syntheticScrollCount),
            "metal"  : Double(latest.metalFrame),
            // Every character in the target's field, typed or pasted: the one
            // counter both text paths move, so the same row measures both.
            "chars"  : Double(latest.textValue.count),
            // The same reading under the name the bulk insertion row watches,
            // because on the browser half the two are different counters.
            "field"  : Double(latest.textValue.count),
        ]
    }

    func clickPoint() -> CGPoint? {
        refresh()
        guard latest.controlsAreHitTestable else { return nil }
        return CGPoint(x: latest.buttonQuartzX, y: latest.buttonQuartzY)
    }

    func scrollPoint() -> CGPoint? {
        refresh()
        guard latest.controlsAreHitTestable, latest.scrollMaximumOffsetY > 20 else { return nil }
        return CGPoint(x: latest.scrollQuartzX, y: latest.scrollQuartzY)
    }

    func dragEndpoints() -> (start: CGPoint, end: CGPoint)? {
        refresh()
        // No resizing and no fallback: the target's layout is its own contract,
        // and a point that does not hit its own control is a defect of the
        // target, reported as such rather than worked around.
        guard latest.controlsAreHitTestable else { return nil }
        return (
            CGPoint(x: latest.sliderStartQuartzX, y: latest.sliderStartQuartzY),
            CGPoint(x: latest.sliderEndQuartzX,   y: latest.sliderEndQuartzY)
        )
    }

    /// Resizes the target's window through accessibility, which is how the
    /// layout is checked at a height nothing else can reach.
    ///
    /// `AXSize` is deliberately **not** in the kit: the kit's whole use of
    /// accessibility is `AXPosition`, `AXRaise` and `_AXUIElementGetWindow`
    /// (ADR 0004), plus the one documented read precondition in
    /// `WindowReader`. It lives here, in test code, and it is the last
    /// consumer of that widening path anywhere.
    @discardableResult
    func resizeThroughAccessibility(to size: CGSize) -> AXError {
        let application = AXUIElementCreateApplication(latest.processID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                  application,
                  kAXWindowsAttribute as CFString,
                  &value
              ) == .success,
              let windows = value as? [AXUIElement],
              let window = windows.first
        else {
            return .cannotComplete
        }
        var requested = size
        guard let sizeValue = AXValueCreate(.cgSize, &requested) else { return .failure }
        return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
}

/// What the harness itself can get wrong about an instrumented target.
nonisolated enum FixtureFailure: Error, CustomStringConvertible {

    case notConfigured
    case notLaunched(String)
    case neverPublished(String)

    var description: String {
        switch self {
        case .notConfigured:
            FixtureTarget.unavailableReason
        case .notLaunched(let error):
            "the instrumented target did not start: \(error)"
        case .neverPublished(let path):
            "the instrumented target never published a window number at \(path)"
        }
    }
}
