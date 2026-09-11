//
//  RectangleGeometry.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import CoreGraphics

/// rectanglesMatch compares two frames within a tolerance, which is how every
/// geometric invariant in the kit is written: window servers, accessibility and
/// display topology all report the same rectangle with sub-point differences.
/// Two absent readings match, an absent one never matches a present one. One
/// predicate covers both optionals and plain rectangles, because two copies of
/// the same comparison are two chances to disagree.
public func rectanglesMatch(
    _ lhs    : CGRect?,
    _ rhs    : CGRect?,
    tolerance: CGFloat = 0.5
) -> Bool {
    
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    
    return abs(lhs.minX  - rhs.minX)    <= tolerance &&
           abs(lhs.minY  - rhs.minY)    <= tolerance &&
           abs(lhs.width - rhs.width)   <= tolerance &&
           abs(lhs.height - rhs.height) <= tolerance
}

/// rectangleIsUsable rejects the rectangles a reading can legitimately return
/// when the window is gone or in transition: null, empty, infinite or carrying
/// a non finite coordinate. A tolerance comparison on those is meaningless.
public func rectangleIsUsable(_ rect: CGRect) -> Bool {
    !rect.isNull       && !rect.isEmpty      &&
    !rect.isInfinite   && rect.minX.isFinite &&
    rect.minY.isFinite && rect.maxX.isFinite &&
    rect.maxY.isFinite
}
