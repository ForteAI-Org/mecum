//
//  CaptureFailure.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics

/// CaptureFailure names why a still could not be taken, so a caller can tell a missing permission
/// from a window that is no longer shared.
public enum CaptureFailure: Error, Equatable {

    /// The window server knows the number but ScreenCaptureKit does not share it: closed, off screen,
    /// or Screen Recording not granted to this process.
    case windowNotShared(number: Int)
    /// No display contains the region's origin.
    case displayNotFound(origin: CGPoint)
    /// The region has no area.
    case emptyRegion
}
