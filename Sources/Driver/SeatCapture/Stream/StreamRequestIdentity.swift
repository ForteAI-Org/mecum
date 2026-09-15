//
//  StreamRequestIdentity.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import Foundation
import SeatCore

/// StreamRequestIdentity binds lifecycle work to one exact framework object,
/// capture generation, display generation and source lifetime.
nonisolated struct StreamRequestIdentity: @unchecked Sendable, Hashable {
    let streamIdentifier  : ObjectIdentifier
    let source            : FrameSourceIdentity
    let displayGeneration : UInt64
    let captureGeneration : UInt64
}

/// StreamConfigurationRequestIdentity adds every setting changed by an update.
/// Two quality requests coalesce only when they address the same resource and
/// ask ScreenCaptureKit for byte-for-byte equivalent scalar settings.
nonisolated struct StreamConfigurationRequestIdentity: @unchecked Sendable, Hashable {
    let stream             : StreamRequestIdentity
    let pixelWidthBits     : UInt64
    let pixelHeightBits    : UInt64
    let framesPerSecond    : Int
}
