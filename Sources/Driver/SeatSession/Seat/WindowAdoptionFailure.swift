//
//  WindowAdoptionFailure.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics
import SeatCore

/// WindowAdoptionFailure preserves the failed placement before rollback changes
/// its evidence. The original error is still thrown, including cancellation;
/// this report tells the consumer what was attempted and whether it came back.
nonisolated public struct WindowAdoptionFailure: Sendable {
    public let window: WindowReference
    public let requestedFrame: CGRect
    public let virtualBounds: CGRect
    public let lastObservedFrame: CGRect?
    public let cause: any Error
    public let restoration: WindowReleaseOutcome
    public let restorationError: (any Error)?
}
