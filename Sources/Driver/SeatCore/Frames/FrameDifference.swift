//
//  FrameDifference.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// FrameDifference answers one question about two captured images: how much
/// they differ, on average, per pixel. It is the arithmetic behind a before and
/// after comparison, never a verdict: whether a difference proves an effect is
/// the consumer's decision, and the kit does not classify outcomes.
public enum FrameDifference {

    /// The side of the grayscale grid both images are drawn into. 64 by 64 is
    /// small enough to ignore antialiasing and font hinting, large enough to
    /// catch a button that changed state.
    public static let downsampleSide = 64

    /// meanPixelDifference returns the mean absolute difference of the two
    /// downsampled images, normalized to 0...1, or nil when either image cannot
    /// be drawn. Nil means "not measured": it is never read as "no difference".
    public static func meanPixelDifference(
        _ first : CGImage,
        _ second: CGImage
    ) -> Double? {
        
        guard
            let firstPixels  = downsample(first),
            let secondPixels = downsample(second),
            firstPixels.count == secondPixels.count,
            !firstPixels.isEmpty
        else { return nil }
        
        let totalDifference = zip(firstPixels, secondPixels).reduce(0.0) { partial, pair in
            partial + abs(Double(pair.0) - Double(pair.1))
        }
        
        return totalDifference / (Double(firstPixels.count) * 255)
    }

    /// downsample draws the image into a fixed grayscale grid. The low
    /// interpolation quality is deliberate: the grid is a signature, and a
    /// better resampler would only make two captures of the same screen differ.
    public static func downsample(_ image: CGImage) -> [UInt8]? {
        
        let side        = downsampleSide
        let bytesPerRow = side
        var pixels      = [UInt8](repeating: 0, count: side * bytesPerRow)
        let colorSpace  = CGColorSpaceCreateDeviceGray()

        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data            : buffer.baseAddress,
                width           : side,
                height          : side,
                bitsPerComponent: 8,
                bytesPerRow     : bytesPerRow,
                space           : colorSpace,
                bitmapInfo      : CGImageAlphaInfo.none.rawValue
            ) else { return false }
            
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
            
        }
        
        return didDraw ? pixels : nil
    }
}
