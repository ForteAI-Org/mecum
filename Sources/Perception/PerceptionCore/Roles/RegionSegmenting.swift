//
//  RegionSegmenting.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics

/// RegionSegmenting supplies the bounding boxes of visually distinct regions in an image, in the
/// image's own pixel space: the raw material icons and switches are recognized from.
///
/// A conformer returns when the image has been read and holds no reference to it afterwards.
public protocol RegionSegmenting: Sendable {

    func segments(in image: CGImage) throws -> [CGRect]
}
