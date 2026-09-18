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

    /// Follow the windows of the applications the seat is driving, and bring a
    /// new one onto the Virtual Display when it appears on a physical display.
    /// Off by default: a seat that was not asked takes no reading of anybody's
    /// windows.
    ///
    /// ## The whole lifecycle, in one place
    ///
    /// **Start.** The seat begins following when it adopts its first window,
    /// and the criterion is membership of the attested process: any window of a
    /// process a held window belongs to, whatever its title, its level or its
    /// place in an accessibility tree. A helper process with a different PID is
    /// outside the feature and stays outside it. A PID reused after the
    /// application terminated owns nothing, because the comparison is the
    /// process serial number and not the number the system handed out again.
    ///
    /// **What wakes it.** Three things, and the first two are the reason the
    /// process sleeps in between: `kAXWindowCreatedNotification` on each driven
    /// process, and the boundary of every finished Command, which is where a
    /// window that Command opened is looked for. Neither is trusted for
    /// correctness. The third is the seat's own one-a-second heartbeat, and it
    /// is the net: an application family whose notification never arrives is
    /// still covered, one second later.
    ///
    /// **The interval after a Command.** A wake-up starts a burst of at most
    /// ten window server passes 120 ms apart, ending as soon as nothing is
    /// waiting for its second reading. The cadence comes from the measurement:
    /// the notification leads the window server by 79 to 249 ms, and a
    /// candidate is only acted on when two readings agree on its identity and
    /// its frame, because a window is published before its geometry has
    /// settled. A window opened late, by a timer of the application's own, is
    /// found by the heartbeat rather than by the burst and transfers a beat
    /// later.
    ///
    /// **What it does.** A window of a driven process, visible, not a
    /// contextual menu, and outside the Virtual Display, goes through the same
    /// transaction as an explicit adoption: at a command boundary, with input
    /// held closed, moved with `AXPosition`, confirmed by two agreeing window
    /// server readings and rolled back if it cannot be. The Command that opened
    /// it is never repeated. A window the seat already holds that leaves the
    /// display is put back. A window that cannot be moved, one that does not
    /// fit, and one whose application keeps putting it back all produce
    /// `windowTransferRefused` with the reason; a transfer that worked produces
    /// `targetChanged` with reason `.detected`.
    ///
    /// **Giving control back.** The person's deliberate input stands the watch
    /// down for as long as it lasts: a pass is skipped while a Command or a
    /// contextual menu action is running, while a focus recovery holds the
    /// seat, and while a physical click or application switch was observed,
    /// which is read from the event the fence's watch latched and never from
    /// the frontmost PID. Releasing the last window stops the observers, and
    /// the teardown stops everything: no pass, no notification and no pending
    /// transfer survives it.
    public let followsNewWindows: Bool

    /// Restore the previously focused user window when an adopted application
    /// activates during a turn. All its visible windows must be virtual.
    public let restoresUserFocus: Bool

    /// Per-facility research opt-in; never bypasses symbol or permission checks.
    public let allowUnvalidatedFocusRecovery: Bool

    /// **Experimental, off by default.** Take a window that is in native macOS
    /// fullscreen: leave fullscreen, wait for the observable end of the
    /// transition, then move it onto the Virtual Display like any other window.
    ///
    /// What it costs, measured on 26A428 and written here because a flag whose
    /// price is in a report nobody reads is a flag that surprises somebody:
    ///
    /// - The exit needs **no added activation** and takes no focus. The
    ///   frontmost application never changed across it in any run, with Stage
    ///   Manager on or off.
    /// - It costs 36 to 100 ms of visible change **once the window's Space has
    ///   left the screen**, and 437 ms (Stage Manager off) to 875 ms (on) of
    ///   the display going to that Space and animating back if it has not. The
    ///   seat refuses rather than pay the second price, and the next pass finds
    ///   the same window.
    /// - A window whose `AXFullScreen` is unreadable or read only is **not
    ///   supported**: it is refused by name and left where it is.
    ///
    /// It changes nothing for a window that is not in native fullscreen. With
    /// it off, such a window is refused with `fullScreenTransferDisabled` and
    /// the ordinary path is exactly what it was before MW-03.
    public let transfersFullScreenWindows: Bool

    /// **Experimental, off by default, and separate on purpose.** Put the
    /// window back into native fullscreen when the seat releases it, if that is
    /// the state it was found in.
    ///
    /// It is its own switch because it is not the mirror image of the exit:
    /// **re-entering fullscreen takes the focus every single time**, measured
    /// on every run and in both Stage Manager states, and costs 538 to 792 ms
    /// of Space animation. The exit is free of both.
    ///
    /// With it off — the default — a release leaves fullscreen, returns the
    /// window to its original display at its normal frame, and stops there.
    /// The window comes back usable and the person's seat is untouched.
    public let restoresFullScreenOnRelease: Bool

    /// Package-only A/B experiment. Production recovery remains activation-only.
    package var focusRecoveryUsesKeyRecords = false

    public init(
        display      : VirtualDisplayConfiguration = VirtualDisplayConfiguration(),
        monitor      : MonitorConfiguration?       = nil,
        platform     : any InputPlatform           = ChromiumPlatform(),
        pumpTimeout  : Duration                    = .seconds(5),
        eventLoopPump: (@MainActor (Duration) -> Void)? = nil,
        followsNewWindows: Bool = false,
        restoresUserFocus: Bool = false,
        allowUnvalidatedFocusRecovery: Bool = false,
        transfersFullScreenWindows: Bool = false,
        restoresFullScreenOnRelease: Bool = false
    ) {
        self.display       = display
        self.monitor       = monitor
        self.platform      = platform
        self.pumpTimeout   = pumpTimeout
        self.eventLoopPump = eventLoopPump
        self.followsNewWindows = followsNewWindows
        self.restoresUserFocus = restoresUserFocus
        self.allowUnvalidatedFocusRecovery = allowUnvalidatedFocusRecovery
        self.transfersFullScreenWindows  = transfersFullScreenWindows
        self.restoresFullScreenOnRelease = restoresFullScreenOnRelease
    }

    public static let `default` = SeatHostConfiguration()
}
