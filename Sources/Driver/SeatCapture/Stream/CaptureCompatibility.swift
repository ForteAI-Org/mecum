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

    /// The requester's observational barrier. Two requests with the same pixels
    /// and provenance are still different requests when a Command completed, a
    /// selection moved or an invalidation happened between them: without this
    /// field a request made after a Command could join a job that started before
    /// it and inherit pixels of the state the Command has already changed. The
    /// default keeps every caller that has no barrier on the previous behaviour.
    var observationBarrier: UInt64 = 0
}

nonisolated enum CaptureCompatibilityKey: Sendable, Hashable {
    case shareableContent
    case still(StillRequestIdentity)
    case streamStop(StreamRequestIdentity)
    case configurationUpdate(StreamConfigurationRequestIdentity)
}
