//
//  DragPacing.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

/// DragPacing is the timing of one drag, as data rather than as a command case.
/// A background app can drop a drag that arrives faster than a hand could
/// produce it, so the driver waits between the events; how long is a property of
/// the target family, which is why an InputPlatform provides it and the command
/// stays a plain description of what to do.
public struct DragPacing: Sendable, Equatable {

    /// The pause after the opening `mouseMoved`, which tells an app whose
    /// internal pointer state is stale where the mouse is before the press.
    public let openingMoveMicroseconds: UInt32

    /// The pause after the press, longer than the steps: an app that starts a
    /// selection or a slider drag does work on the first event.
    public let pressMicroseconds: UInt32

    /// The pause after every intermediate move and after the release.
    public let stepMicroseconds: UInt32

    public init(
        openingMoveMicroseconds: UInt32,
        pressMicroseconds      : UInt32,
        stepMicroseconds       : UInt32
    ) {
        self.openingMoveMicroseconds = openingMoveMicroseconds
        self.pressMicroseconds       = pressMicroseconds
        self.stepMicroseconds        = stepMicroseconds
    }

    /// The pacing measured on AppKit targets and on Chromium renderers:
    /// 24 ms after the opening move, 16 ms after the press, 12 ms per step.
    public static let realistic = DragPacing(
        openingMoveMicroseconds: 24_000,
        pressMicroseconds      : 16_000,
        stepMicroseconds       : 12_000
    )
}
