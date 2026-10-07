//
//  ControlledObservationSource.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 16/09/2026.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import SeatCapture
import SeatCore
@testable import SeatSession

/// A capture source that answers with a real `SeatFrame` built in this process:
/// a real `IOSurface`, a real 32BGRA `CVPixelBuffer`, and the geometry the fake
/// window server reports for the window.
///
/// It exists so the production observation path, the qualification and the
/// admission can be exercised whole, including their successful paths, without a
/// display, a permission or ScreenCaptureKit. It certifies nothing about macOS:
/// the shipped source still refuses the menu surface, and the shipped clock still
/// leaves the content age unknown.
final class ControlledObservationSource: ObservedSurfaceSourcing, @unchecked Sendable {

    private let sensing: FakeSensing

    /// Which abilities this source claims. A test turns one off to see the seat
    /// refuse before any effect, with the capability named.
    var supported: Set<ObservationCapability> = [.windowStill, .menuSurfaceStill, .contentClock]

    /// Captures that must fail before answering, counted down. It is how a test
    /// spends an attempt without ending the request.
    var failuresBeforeSuccess = 0

    /// An error every capture answers with, for the paths that never succeed.
    var permanentFailure: (any Error)?

    /// Runs inside the capture, before it answers, so a test can move the target
    /// or end the assignment while a capture is genuinely in flight.
    var duringCapture: (@MainActor () async -> Void)?

    /// Every window the source was asked for, in order.
    private(set) var requested: [WindowIdentity] = []

    /// The observational barriers the requests carried, which is what a Still of
    /// a superseded moment would share with one of the current moment.
    private(set) var barriers: [UInt64] = []

    /// Hosted-sheet crops requested by the production path. This makes a test
    /// distinguish the explicit union capture from the old host-only fallback.
    private(set) var requestedRegions: [(
        host: WindowIdentity,
        children: [WindowIdentity],
        screenRect: CGRect,
        sourceWindowFrame: CGRect
    )] = []

    /// True to answer a Frame of a window the caller did not ask for, so the
    /// qualifier's identity check can be seen refusing.
    var answersWrongIdentity: WindowIdentity?

    /// True to answer a Frame whose geometry cannot carry a coordinate.
    var answersMalformedGeometry = false

    /// Writes into the pixels of every window Frame before it is answered, so a test decides
    /// whether two observations show the same bytes. A new surface is all zeros otherwise.
    var paint: ((CVPixelBuffer) -> Void)?

    init(sensing: FakeSensing) {
        self.sensing = sensing
    }

    func supports(_ capability: ObservationCapability) -> Bool {
        supported.contains(capability)
    }

    func captureWindowStill(
        of identity        : WindowIdentity,
        observationBarrier : UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SeatFrame {
        try await capture(identity, barrier: observationBarrier)
    }

    func captureMenuStill(
        of identity        : WindowIdentity,
        parent             : WindowIdentity,
        observationBarrier : UInt64,
        deadlineNanoseconds: UInt64
    ) async throws -> SeatFrame {
        try await capture(identity, barrier: observationBarrier)
    }

    func captureWindowRegionStill(
        host                : WindowIdentity,
        children            : [WindowIdentity],
        displayID           : CGDirectDisplayID,
        screenRect          : CGRect,
        sourceWindowFrame   : CGRect,
        observationBarrier  : UInt64,
        deadlineNanoseconds : UInt64
    ) async throws -> SeatFrame {
        requestedRegions.append((host, children, screenRect, sourceWindowFrame))
        requested.append(host)
        barriers.append(observationBarrier)
        await duringCapture?()
        if let permanentFailure { throw permanentFailure }
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw ObservationUnavailable.captureFailed(reason: "controlled attempt refused")
        }
        guard let frame = makeControlledFrame(
            of                : answersWrongIdentity ?? host,
            screenRect        : screenRect,
            sourceWindowFrame : sourceWindowFrame,
            malformed         : answersMalformedGeometry
        ) else {
            throw ObservationUnavailable.captureFailed(reason: "could not construct the controlled region frame")
        }
        return frame
    }

    private func capture(_ identity: WindowIdentity, barrier: UInt64) async throws -> SeatFrame {

        requested.append(identity)
        barriers.append(barrier)

        await duringCapture?()

        if let permanentFailure { throw permanentFailure }
        if failuresBeforeSuccess > 0 {
            failuresBeforeSuccess -= 1
            throw ObservationUnavailable.captureFailed(reason: "controlled attempt refused")
        }

        let stamped = answersWrongIdentity ?? identity
        // Capture geometry belongs to the requested surface. A test may stamp
        // the returned Frame with another identity to exercise the qualifier,
        // but that must not publish the other surface into the assignment first:
        // doing so would correctly stop at containment before identity is read.
        guard let reference = sensing.windowGeometry(of: identity.windowNumber) else {
            throw ObservationUnavailable.captureFailed(
                reason: "no geometry for window \(identity.windowNumber)"
            )
        }
        guard let frame = makeControlledFrame(
            of        : stamped,
            screenRect: reference.frame,
            malformed : answersMalformedGeometry
        ) else {
            throw ObservationUnavailable.captureFailed(
                reason: "could not construct the controlled frame"
            )
        }
        paint?(frame.pixelBuffer)
        return frame
    }
}

/// Builds a Frame of one window with the geometry attachments a real sample
/// carries, or a malformed one on request.
///
/// The surface is allocated here and the pixel buffer is the same 32BGRA the
/// stream asks the window server for, so the qualifier and the coordinate
/// transform see the type the live path carries rather than a stand-in.
nonisolated func makeControlledFrame(
    of identity: WindowIdentity,
    screenRect : CGRect,
    sourceWindowFrame: CGRect? = nil,
    receivedAt : UInt64 = 1,
    displayTime: UInt64? = nil,
    malformed  : Bool = false
) -> SeatFrame? {

    let width  = max(1, Int(screenRect.width.rounded()))
    let height = max(1, Int(screenRect.height.rounded()))

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
    let geometry  = FrameGeometryObservation(
        source              : .window(identity),
        screenRect          : screenRect,
        sourceWindowFrame   : sourceWindowFrame,
        contentRectInSurface: malformed
            ? CGRect(x: 0, y: 0, width: screenRect.width * 4, height: screenRect.height)
            : CGRect(origin: .zero, size: screenRect.size),
        scaleFactor         : 1,
        contentScale        : 1,
        pixelSize           : pixelSize,
        version             : GeometryObservationVersion(
            observerGeneration: 1,
            sequence          : receivedAt
        ),
        capturesFullWindow  : true
    )
    return SeatFrame(
        surface          : surface,
        pixelBuffer      : pixelBuffer,
        presentationTime : CMTime(value: CMTimeValue(receivedAt), timescale: 1_000_000),
        receivedAt       : receivedAt,
        displayTime      : displayTime,
        displayGeneration: 1,
        source           : .window(identity),
        geometry         : geometry
    )
}
