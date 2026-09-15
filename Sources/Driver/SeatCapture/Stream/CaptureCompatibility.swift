//
//  CaptureCompatibility.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import SeatCore

/// StillRequestIdentity names everything that can change the pixels or their
/// provenance. Local geometry observation versions are deliberately absent:
/// their counters belong to one observer and can collide across owners.
nonisolated struct StillRequestIdentity: Sendable, Hashable {

    let source            : FrameSourceIdentity
    let pixelWidthBits    : UInt64
    let pixelHeightBits   : UInt64
    let framesPerSecond   : Int
    let displayGeneration : UInt64
    let captureGeneration : UInt64
}

nonisolated enum CaptureCompatibilityKey: Sendable, Hashable {
    case shareableContent
    case still(StillRequestIdentity)
    case streamStop(StreamRequestIdentity)
    case configurationUpdate(StreamConfigurationRequestIdentity)
}
