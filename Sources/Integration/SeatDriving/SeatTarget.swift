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
/// Main actor, like the seat it wraps. Every still it takes comes from `AgentSeat.observe()`, which
/// hands the Frame together with the Observation Reference that binds it: that reference is what
/// authorizes the next gesture, because a Command is addressed by the observation it was decided on
/// and never by a window. This is where the observation is kept between the two.
@MainActor
public final class SeatTarget {

    private let host: SeatHost
    private var seat: AgentSeat?
    private var adopted: AdoptedWindow?
    /// True when another owner started `host` and `seat` and keeps their lifecycle.
    private let isBorrowed: Bool
    /// Told of every observation taken through a borrow, so the owner can follow the window read here.
    private let observed: (@MainActor (SeatObservationDelivery) -> Void)?

    /// The observation the last Frame was delivered with, and whether a Command already consumed it.
    private var delivery: SeatObservationDelivery?
    private var deliverySpent = false
    /// The opening obligation ends only when this window supplies its first qualified observation.
    private var initialWindow: WindowIdentity?

    /// The geometry of the last observation, the coordinate authority for the next command.
    public private(set) var lastWindowGeometry: WindowGeometryObservation?
    /// The window whose pixels were last observed, resolved from the delivery's own recipient.
    public private(set) var lastCapturedWindow: AdoptedWindow?

    public init(configuration: SeatHostConfiguration = SeatHostConfiguration(restoresUserFocus: true)) {
        host = SeatHost(configuration: configuration)
        isBorrowed = false
        observed   = nil
    }

    /// Wraps a host and a seat another owner started, so the Engine's roles act on that owner's seat.
    ///
    /// The target borrows both and owns neither. `start()` refuses, because the host is already up
    /// and bringing it up is the owner's; `stop()` ends the borrow and touches neither, because
    /// releasing a window or taking the display down here would leave the owner holding a seat it
    /// no longer has. The owner keeps adoption, release and teardown, and must outlive every use.
    ///
    /// The observation kept here is this target's own, and the seat keeps one outstanding
    /// observation: one the owner takes afterwards supersedes it, so the next Command from here is
    /// refused before any event and never redirected. `observed` hears every observation taken
    /// here, so the owner's live picture shows the window the engine reads and not the one it adopted.
    /// The first observation must match `initialWindow`, or the selected window at the borrow when
    /// it is omitted. Later window following remains available after that first identity is verified.
    package init(
        borrowing host: SeatHost,
        seat          : AgentSeat,
        initialWindow : WindowIdentity? = nil,
        observed      : (@MainActor (SeatObservationDelivery) -> Void)? = nil
    ) {
        self.host     = host
        self.seat     = seat
        self.observed = observed
        isBorrowed    = true
        self.initialWindow = initialWindow ?? seat.currentTarget?.reference.identity
    }

    /// Brings up the virtual display and the fence, atomically, and makes the seat.
    public func start() async throws {
        guard !isBorrowed else { throw SeatDrivingFailure.borrowedLifecycle }
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
        initialWindow = window.reference.identity
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
        try verifyInitialWindow(window.reference.identity)
        return window
    }

    /// The virtual display, once started.
    public var displayID: CGDirectDisplayID? { host.displayID }

    /// One observation of the selected window: the Frame and the reference the next Command is
    /// admitted under, kept here so the gesture that follows a scene is posted under the very
    /// picture that scene was read from. ScreenCaptureKit sometimes answers a one-shot with no
    /// buffer right after a window moved, so an unavailable observation is retried before it is an
    /// error. The error is the seat's own `ObservationUnavailable`, so the consumer can word it.
    ///
    /// Which window is observed is the seat's own choice and no longer this layer's: the seat
    /// follows the application through a dialog's closure and selects the surviving surface, which
    /// is what the predecessor reading here used to do by hand. Aiming a capture from outside would
    /// produce pixels with no reference, and a Frame nobody can act on.
    @discardableResult
    public func observe() async throws -> SeatObservationDelivery {
        let seat = try agentSeat()
        _ = try currentWindow()
        let delivered = try await Self.retrying {
            _ = try self.currentWindow()
            switch await seat.observe() {
                case .success(let delivery): return delivery
                case .failure(let reason)  : throw reason
            }
        }
        try verifyInitialWindow(delivered.reference.recipient)
        initialWindow = nil
        delivery           = delivered
        deliverySpent      = false
        lastWindowGeometry = delivered.geometry
        lastCapturedWindow = seat.adoptedWindows.first {
            $0.reference.identity == delivered.reference.recipient
        }
        observed?(delivered)
        return delivered
    }

    /// The observation the next Command is admitted under. A complete Command consumes its
    /// observation, so one that already carried a Command is replaced by a new look rather than
    /// handed out twice: the seat refuses the second gesture under the same reference, and that
    /// refusal would arrive after the engine had already decided what to do.
    public func currentObservation() async throws -> SeatObservationDelivery {
        if let delivery, !deliverySpent { return delivery }
        return try await observe()
    }

    /// Records that a Command went out under the kept observation, which ends its authority. A
    /// Command refused before any effect leaves the observation exactly as it was, so this is
    /// called only once the events have gone out.
    public func spendObservation() {
        deliverySpent = true
    }

    /// One still of the observed window, for perception. It is the observation's own Frame, so a
    /// scene read from it and the gesture decided on that scene are bound to the same picture.
    public func windowStill() async throws -> SeatFrame {
        try await observe().frame
    }

    /// One still of the whole virtual display: the only capture that holds both the window and a
    /// pop-up floating beside it, because a window filter captures exactly one window.
    public func displayStill() async throws -> SeatFrame {
        // A display crop cannot establish the opening identity; qualify the selected window first.
        if initialWindow != nil { _ = try await observe() }
        // A stopped borrow has no seat and must not read the owner's display, which may show another window.
        guard seat != nil, let displayID = host.displayID else { throw SeatDrivingFailure.notAdopted }
        return try await Self.retrying {
            try await SeatCaptureStream.still(of: .display(displayID), timeout: .seconds(5))
        }
    }

    /// The window server's current frame of the adopted window.
    public func currentFrame() throws -> CGRect {
        let window = try currentWindow()
        return WindowServerProbe.geometry(of: window.id)?.frame ?? window.reference.frame
    }

    /// Returns the window to the person's displays and takes the virtual display down. A borrowed
    /// target only forgets its seat and its observation: the host and the seat are left as they are.
    public func stop() async {
        if !isBorrowed, let seat, let adopted {
            for companion in seat.adoptedWindows where companion.id != adopted.id {
                _ = await seat.release(companion, .returnToUserSeat)
            }
            _ = await seat.release(adopted, .returnToUserSeat)
        }
        adopted = nil
        seat = nil
        delivery = nil
        deliverySpent = false
        lastCapturedWindow = nil
        lastWindowGeometry = nil
        initialWindow = nil
        if !isBorrowed { _ = await host.stop() }
    }

    private func verifyInitialWindow(_ observed: WindowIdentity?) throws {
        guard let expected = initialWindow else { return }
        guard observed == expected else {
            throw SeatDrivingFailure.initialWindowChanged(expected: expected, observed: observed)
        }
    }

    private static func retrying<T>(_ body: () async throws -> T) async throws -> T {
        var lastError: any Error = SeatDrivingFailure.frameUnusable
        for attempt in 1...3 {
            do { return try await body() } catch {
                lastError = error
                if error is CancellationError { break }
                if case .initialWindowChanged? = error as? SeatDrivingFailure { break }
                try? await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }
        throw lastError
    }
}
