//
//  DisplayReconfigurationWatch.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics
import Foundation

/// DisplayReconfigurationWatch is the event half of the watchdog: CoreGraphics
/// tells the host that a display appeared, went away, moved or changed mode,
/// instead of the host asking fifty times a second whether it did.
///
/// This is where the wake-up budget is won. Re-reading all nine invariants on
/// a 20 ms timer pays for every one of them, and the two that can change
/// abruptly, the
/// display set and the topology, are exactly the two the system publishes. So
/// they are answered in the callback, within a display configuration
/// transaction, and everything else waits for the one-a-second heartbeat.
///
/// The callback arrives on the main run loop, and the handler is run through a
/// main queue block rather than a `Task`: the owner of a virtual display is
/// pumping its own AppKit loop (ADR 0007), and a main queue block runs under
/// that pump while a main actor job does not.
final class DisplayReconfigurationWatch {

    /// What is worth waking up for. A display added, removed, moved, or a mode
    /// change: the flags that can invalidate a coordinate. Brightness and
    /// mirroring changes come through the same callback and are ignored here.
    nonisolated static let interesting: CGDisplayChangeSummaryFlags = [
        .addFlag, .removeFlag, .movedFlag, .setModeFlag,
        .desktopShapeChangedFlag, .setMainFlag,
    ]

    /// One function pointer, stored: `CGDisplayRemoveReconfigurationCallback`
    /// matches on the pointer, and two identical closure literals are not
    /// guaranteed to compile to the same one, so a second literal would
    /// silently leave the callback registered for the life of the process.
    nonisolated(unsafe) private static let callback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in

        guard let userInfo,
              !flags.intersection(DisplayReconfigurationWatch.interesting).isEmpty
        else { return }

        let box = Unmanaged<Box>.fromOpaque(userInfo).takeUnretainedValue()

        // Not synchronous: the callback runs inside the window server's
        // configuration transaction, and re-reading the topology from in there
        // reads a half applied arrangement.
        DispatchQueue.main.async { MainActor.assumeIsolated { box.handler() } }
    }

    private var box: Unmanaged<Box>?

    /// The handler has to reach a C callback with no context of its own, so it
    /// travels as a retained box and the callback un-retains nothing: the watch
    /// owns the box and releases it in `deinit`.
    private final class Box {
        let handler: @MainActor () -> Void
        init(handler: @MainActor @escaping () -> Void) { self.handler = handler }
    }

    init(handler: @MainActor @escaping () -> Void) {

        let retained = Unmanaged.passRetained(Box(handler: handler))
        self.box = retained

        CGDisplayRegisterReconfigurationCallback(Self.callback, retained.toOpaque())
    }

    deinit {

        guard let box else { return }

        CGDisplayRemoveReconfigurationCallback(Self.callback, box.toOpaque())
        box.release()
    }
}
