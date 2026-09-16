//
//  WindowGeometryProbe.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import CoreGraphics
import Darwin
import SeatCore

/// WindowGeometryProbe reads the identity, frame and one unambiguous display
/// scale of a window. It is called at a Command boundary, never for each Frame:
/// `CGWindowListCopyWindowInfo` allocates and does not belong in capture's live
/// delivery path.
nonisolated public enum WindowGeometryProbe {

    private static let maximumDisplayCount: Int     = 32
    private static let scaleTolerance     : CGFloat = 0.000_001

    /// observation returns nil unless the window is still the attested target
    /// and lies on exactly one display with a uniform pixel-to-point scale.
    /// The version is a local reading sequence based on monotonic uptime, not a
    /// WindowServer generation and not proof against move-away-and-back races.
    public static func observation(
        of window             : WindowReference,
        allowUnvalidatedBuild : Bool = false
    ) -> WindowGeometryObservation? {
        
        guard let expectedIdentity = window.identity,
              let current = WindowServerProbe.geometry(
                  of                   : window.windowNumber,
                  allowUnvalidatedBuild: allowUnvalidatedBuild
              ),
              current.identity == expectedIdentity,
              let scaleFactor = scaleFactor(for: current.frame)
                
        else { return nil }

        return WindowGeometryObservation(
            window     : current,
            scaleFactor: scaleFactor,
            version    : GeometryObservationVersion(
                observerGeneration: 0,
                sequence          : mach_absolute_time()
            )
        )
    }

    /// scaleFactor refuses a window spanning outputs. One scalar cannot prove
    /// how points sampled on two displays map to pixels, even when both displays
    /// currently report the same nominal scale.
    package static func scaleFactor(for frame: CGRect) -> CGFloat? {
        guard frame.hasFinitePositiveArea else { return nil }

        return withUnsafeTemporaryAllocation(
            of      : CGDirectDisplayID.self,
            capacity: maximumDisplayCount
        ) { displays in
            
            var displayCount: UInt32 = 0
            guard CGGetDisplaysWithRect(
                frame,
                UInt32(maximumDisplayCount),
                displays.baseAddress,
                &displayCount
            ) == .success,
                  displayCount > 0,
                  displayCount <= UInt32(maximumDisplayCount)
            else { return nil }

            var containingDisplay: CGDirectDisplayID?
            for index in 0..<Int(displayCount) {
                let displayID = displays[index]
                let bounds    = CGDisplayBounds(displayID)
                let overlap   = bounds.intersection(frame)
               
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
                guard bounds.contains(frame) else { return nil }
                guard containingDisplay == nil else { return nil }
                
                containingDisplay = displayID
            }
            guard let displayID = containingDisplay else { return nil }

            let bounds = CGDisplayBounds(displayID)
            guard bounds.hasFinitePositiveArea,
                  let mode = CGDisplayCopyDisplayMode(displayID)
            else { return nil }

            // The active mode is one coherent snapshot of both its logical
            // point dimensions and backing pixel dimensions. Display bounds
            // are still checked because they are the coordinate space used to
            // prove that the complete window lies on this display. A rotated
            // output may exchange the two axes.
            let modePointSize = CGSize(
                width : CGFloat(mode.width),
                height: CGFloat(mode.height)
            )
            let dimensionsAgree = Self.dimensions(
                modePointSize,
                equal: bounds.size
            ) || Self.dimensions(
                modePointSize,
                equal: CGSize(width: bounds.height, height: bounds.width)
            )
            guard dimensionsAgree else { return nil }

            let horizontal = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
            let vertical   = CGFloat(mode.pixelHeight) / CGFloat(mode.height)
            guard horizontal.isFinite,
                  vertical.isFinite,
                  horizontal > 0,
                  vertical > 0,
                  abs(horizontal - vertical) <= scaleTolerance
            else { return nil }
            return horizontal
        }
    }

    private static func dimensions(_ lhs: CGSize, equal rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) <= scaleTolerance
            && abs(lhs.height - rhs.height) <= scaleTolerance
    }
}
