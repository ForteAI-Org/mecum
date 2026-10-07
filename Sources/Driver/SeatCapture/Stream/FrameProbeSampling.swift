//
//  FrameProbeSampling.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

#if MECUM_PHASES
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PhaseSignposts
import ScreenCaptureKit

/// FrameProbeSampling reads one ScreenCaptureKit sample into a `FrameSample` for a phase
/// measurement build: its status, which attachments it carries, its dirty rectangles and,
/// when asked, a hash of its pixels.
///
/// Read only: it never changes the sample and never decides whether a frame is used. Compiled
/// only under `MECUM_PHASES`.
nonisolated enum FrameProbeSampling {

    static func sample(_ sampleBuffer: CMSampleBuffer, hashing: Bool) -> FrameSample {
        var sample = FrameSample()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]]
        if let attachment = attachments?.first {
            sample.hasAttachment   = true
            sample.status          = attachment[.status] as? Int
            sample.hasDisplayTime  = attachment[.displayTime] is NSNumber
            sample.hasScreenRect   = rectangle(attachment[.screenRect]) != nil
            sample.hasContentRect  = rectangle(attachment[.contentRect]) != nil
            sample.hasScaleFactor  = attachment[.scaleFactor] is NSNumber
            sample.hasContentScale = attachment[.contentScale] is NSNumber
            sample.dirtyRectCount  = (attachment[.dirtyRects] as? [Any])?.count ?? 0
        }
        if hashing, let buffer = sampleBuffer.imageBuffer {
            sample.contentHash = contentHash(of: buffer)
        }
        return sample
    }

    /// Hashes every fourth row of the surface, whole rows, as 64-bit words: a glyph or a caret
    /// spans more than four rows, so a visible change moves the hash.
    static func contentHash(of buffer: CVPixelBuffer) -> UInt64? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let wordsPerRow = CVPixelBufferGetWidth(buffer) * 4 / 8
        let stride      = CVPixelBufferGetBytesPerRow(buffer)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for row in Swift.stride(from: 0, to: CVPixelBufferGetHeight(buffer), by: 4) {
            let line = base.advanced(by: row * stride)
            for word in 0..<wordsPerRow {
                hash = (hash ^ line.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self))
                    &* 0x0000_0100_0000_01b3
            }
        }
        return hash
    }

    private static func rectangle(_ value: Any?) -> CGRect? {
        if let rectangle = value as? CGRect { return rectangle }
        if let rectangle = (value as? NSValue)?.rectValue { return rectangle }
        return nil
    }
}
#endif
