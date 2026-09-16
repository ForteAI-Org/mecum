//
//  SeatHostConfiguration.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Foundation
import SeatCapture
import SeatInput
import VirtualScreens

/// SeatHostConfiguration is what a caller chooses about a Seat Host before it
/// starts. Everything in it has a default that is the measured one, so
/// `SeatHost(configuration: .default)` is the configuration this kit was
/// benchmarked with.
nonisolated public struct SeatHostConfiguration: Sendable {

    /// The virtual display's geometry and refresh rate.
    public let display: VirtualDisplayConfiguration

    /// The Monitor's preview settings, nil to start without a preview at all.
    ///
    /// Starting without one is the cheap seat: the idle budget of spec section
    /// 8 (0,1 % of a core at the median, five wake-ups a second, 4 MB) is the
    /// budget of a display, a fence and a heartbeat, and a Monitor is measured
    /// separately because it is the person's convenience and not the seat's
    /// function.
    public let monitor: MonitorConfiguration?

    /// The Preparation and pacing policy new seats adopt windows with.
    /// `.universal` is `ChromiumPlatform`, which also covers Electron and CEF,
    /// and which an AppKit target pays nothing for: it prepares only `click`
    /// and `drag`.
    public let platform: any InputPlatform

    /// How long `start` waits for AppKit to publish an `NSScreen`, and `stop`
    /// waits for the display to leave the online list. Both waits need the
    /// caller to be turning its own AppKit event loop (ADR 0007).
    public let pumpTimeout: Duration

    /// The caller's own way of turning its event loop, for a caller that
    /// already has one.
    ///
    /// Leave it nil in an application: `NSApplication.run()` is turning, so the
    /// host's waits suspend and the application's loop does the work. Hand it
    /// over in a benchmark or a test harness that drives `nextEvent` itself, so
    /// the host uses **that** function instead of adding a second call site of
    /// its own. ADR 0007 and ADR 0008: only the caller knows how it pumps.
    public let eventLoopPump: (@MainActor (Duration) -> Void)?

    /// Restore the previously focused user window when an adopted application
    /// activates during a turn. All its visible windows must be virtual.
    public let restoresUserFocus: Bool

    /// Per-facility research opt-in; never bypasses symbol or permission checks.
    public let allowUnvalidatedFocusRecovery: Bool

    /// Package-only A/B experiment. Production recovery remains activation-only.
    package var focusRecoveryUsesKeyRecords = false

    public init(
        display      : VirtualDisplayConfiguration = VirtualDisplayConfiguration(),
        monitor      : MonitorConfiguration?       = nil,
        platform     : any InputPlatform           = ChromiumPlatform(),
        pumpTimeout  : Duration                    = .seconds(5),
        eventLoopPump: (@MainActor (Duration) -> Void)? = nil,
        restoresUserFocus: Bool = false,
        allowUnvalidatedFocusRecovery: Bool = false
    ) {
        self.display       = display
        self.monitor       = monitor
        self.platform      = platform
        self.pumpTimeout   = pumpTimeout
        self.eventLoopPump = eventLoopPump
        self.restoresUserFocus = restoresUserFocus
        self.allowUnvalidatedFocusRecovery = allowUnvalidatedFocusRecovery
    }

    public static let `default` = SeatHostConfiguration()
}
