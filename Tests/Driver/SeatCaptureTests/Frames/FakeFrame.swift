//
//  FakeFrame.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import SeatCore
@testable import SeatCapture

/// A `SeatFrame` built from a surface this process allocated, with no display,
/// no permission and no ScreenCaptureKit.
///
/// It is a real `IOSurface` with a real `CVPixelBuffer` over it, in the same
/// 32BGRA the stream asks the window server for, so everything the unit tier
/// checks (the newest-wins slot, the generation gate, `makeCGImage`, the
/// assignment into a layer) is checked against the type the live path actually
/// carries and not against a stand-in.
nonisolated func makeFakeFrame(
    width            : Int    = 64,
    height           : Int    = 64,
    displayGeneration: UInt64 = 1,
    receivedAt       : UInt64 = 0,
    displayTime      : UInt64? = nil,
    source           : FrameSourceIdentity = .display(1)
) -> SeatFrame? {

    let properties: [IOSurfacePropertyKey: any Sendable] = [
        .width          : width,
        .height         : height,
        .bytesPerElement: 4,
        .bytesPerRow    : width * 4,
        .pixelFormat    : kCVPixelFormatType_32BGRA,
    ]
    guard let surface = IOSurface(properties: properties) else { return nil }

    var unmanaged: Unmanaged<CVPixelBuffer>?
    let status = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault,
        unsafeBitCast(surface, to: IOSurfaceRef.self),
        nil,
        &unmanaged
    )
    guard status == kCVReturnSuccess, let pixelBuffer = unmanaged?.takeRetainedValue()
    else { return nil }

    let pixelSize = CGSize(width: width, height: height)
    let geometry = FrameGeometryObservation(
        source              : source,
        screenRect          : CGRect(origin: .zero, size: pixelSize),
        contentRectInSurface: CGRect(origin: .zero, size: pixelSize),
        scaleFactor         : 1,
        contentScale        : 1,
        pixelSize           : pixelSize,
        version             : GeometryObservationVersion(
            observerGeneration: displayGeneration,
            sequence          : receivedAt
        ),
        capturesFullWindow  : false
    )
    return SeatFrame(
        surface          : surface,
        pixelBuffer      : pixelBuffer,
        presentationTime : CMTime(value: CMTimeValue(receivedAt), timescale: 1_000_000),
        receivedAt       : receivedAt,
        displayTime      : displayTime,
        displayGeneration: displayGeneration,
        source           : source,
        geometry         : geometry
    )
}
