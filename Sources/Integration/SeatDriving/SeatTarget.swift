//
//  SeatTarget.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import Foundation
import SeatCapture
import SeatCore
import SeatInput
import SeatSession
import WindowPlacement

/// SeatTarget is one application window driven in the background: the host that owns the virtual
/// display and the fence, the seat on it, and the window adopted there. It is the one owner of the
/// Driver's lifecycle in this layer; the scene provider and the actuator borrow it.
///
/// Main actor, like the seat it wraps. Every still it takes records the window's pixel-to-screen
/// geometry, which is what authorizes a later click: the seat refuses a point that was not measured
/// under an observation, and this is where the observation comes from.
@MainActor
public final class SeatTarget {

    private let host: SeatHost
    private var seat: AgentSeat?
    private var adopted: AdoptedWindow?
    /// The geometry of the last full-window still, the coordinate authority for the next command.
    public private(set) var lastWindowGeometry: WindowGeometryObservation?
    /// The window whose pixels were last captured, which can be the held predecessor of a closed dialog.
    public private(set) var lastCapturedWindow: AdoptedWindow?

    public init(configuration: SeatHostConfiguration = SeatHostConfiguration(restoresUserFocus: true)) {
        host = SeatHost(configuration: configuration)
    }

    /// Brings up the virtual display and the fence, atomically, and makes the seat.
    public func start() async throws {
        try await host.start()
        seat = try host.makeSeat()
    }

    /// Adopts one window of a process onto the virtual display and stages it, so input lands on a
    /// window and not on a Stage Manager thumbnail. The reference is the window server's attested
    /// one; the accessibility frame, when readable, only refines the rectangle before the move.
    @discardableResult
    public func adopt(windowNumber: Int, processID: pid_t, title: String) async throws -> AdoptedWindow {
        guard let seat else { throw SeatDrivingFailure.notAdopted }
        guard let server = WindowServerProbe.geometry(of: windowNumber), server.processID == processID else {
            throw SeatDrivingFailure.windowNotAttested(number: windowNumber, processID: processID)
        }
        // The accessibility frame is a refinement, not a requirement: unreadable means the server's rectangle.
        let refined = (try? WindowRelocator.frame(of: server)) ?? nil
        let reference = refined.map(server.replacingFrame) ?? server
        var window = try await seat.adopt(reference, platform: .universal, title: title)
        if !seat.isStaged(window) { window = try await seat.stage(window) }
        adopted = window
        return window
    }

    /// The seat, once started.
    public func agentSeat() throws -> AgentSeat {
        guard let seat else { throw SeatDrivingFailure.notAdopted }
        return seat
    }

    /// The window the seat currently targets: the one the seat selected when it follows the
    /// application's windows, else the one adopted here.
    public func currentWindow() throws -> AdoptedWindow {
        guard let window = seat?.currentTarget ?? adopted else { throw SeatDrivingFailure.notAdopted }
        return window
    }

    /// The virtual display, once started.
    public var displayID: CGDirectDisplayID? { host.displayID }

    /// One still of the adopted window at its own resolution. ScreenCaptureKit sometimes answers a
    /// one-shot with no buffer right after a window moved, so a miss is retried before it is an error.
    public func windowStill() async throws -> SeatFrame {
        let frame = try await Self.retrying { [self] in
            let window = try observationWindow()
            guard let identity = window.reference.identity else { throw SeatDrivingFailure.notAdopted }
            let captured = try await SeatCaptureStream.still(of: .attestedWindow(identity), timeout: .seconds(5))
            lastCapturedWindow = window
            return captured
        }
        if let geometry = frame.geometry.windowObservation { lastWindowGeometry = geometry }
        return frame
    }

    /// Reads an already-held predecessor when the current dialog has disappeared. This does not
    /// retarget input or recover a failed Seat: it supplies the evidence needed to confirm the
    /// pending action, whose unknown effect would otherwise prevent Driver recovery.
    private func observationWindow() throws -> AdoptedWindow {
        let current = try currentWindow()
        if let live = WindowServerProbe.geometry(of: current.id) {
            guard live.hasSameIdentity(as: current.reference) else {
                throw SeatDrivingFailure.windowNotAttested(number: current.id, processID: current.reference.processID)
            }
            return current
        }
        guard let seat else { throw SeatDrivingFailure.notAdopted }
        for number in seat.targetHistory.reversed() where number != current.id {
            guard let candidate = seat.adoptedWindows.first(where: { $0.id == number }),
                  candidate.reference.identity?.process == current.reference.identity?.process,
                  let live = WindowServerProbe.geometry(of: number),
                  live.hasSameIdentity(as: candidate.reference) else { continue }
            return candidate
        }
        throw SeatDrivingFailure.windowNotAttested(number: current.id, processID: current.reference.processID)
    }

    /// One still of the whole virtual display: the only capture that holds both the window and a
    /// pop-up floating beside it, because a window filter captures exactly one window.
    public func displayStill() async throws -> SeatFrame {
        guard let displayID = host.displayID else { throw SeatDrivingFailure.notAdopted }
        return try await Self.retrying {
            try await SeatCaptureStream.still(of: .display(displayID), timeout: .seconds(5))
        }
    }

    /// The window server's current frame of the adopted window.
    public func currentFrame() throws -> CGRect {
        let window = try currentWindow()
        return WindowServerProbe.geometry(of: window.id)?.frame ?? window.reference.frame
    }

    /// Returns the window to the person's displays and takes the virtual display down.
    public func stop() async {
        if let seat, let adopted {
            for companion in seat.adoptedWindows where companion.id != adopted.id {
                _ = await seat.release(companion, .returnToUserSeat)
            }
            _ = await seat.release(adopted, .returnToUserSeat)
        }
        adopted = nil
        seat = nil
        lastCapturedWindow = nil
        lastWindowGeometry = nil
        _ = await host.stop()
    }

    private static func retrying<T>(_ body: () async throws -> T) async throws -> T {
        var lastError: any Error = SeatDrivingFailure.frameUnusable
        for attempt in 1...3 {
            do { return try await body() } catch {
                lastError = error
                if error is CancellationError { break }
                try? await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }
        throw lastError
    }
}
