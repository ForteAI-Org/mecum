//
//  AccessibilityHarvest.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// AccessibilityHarvest is what one accessibility read of a window answers: the elements it
/// harvested and the quality of the read they came from. The two travel together because the
/// elements alone cannot say whether the walk finished: an empty list is a real answer from an
/// application that exposes nothing, and also what a denied grant or a missing window produces.
public struct AccessibilityHarvest: Sendable, Equatable {

    public var elements: [SceneElement]
    public var quality: CaptureQuality

    public init(elements: [SceneElement], quality: CaptureQuality) {
        self.elements = elements
        self.quality  = quality
    }

    /// No read took place: no elements, quality unknown.
    public static let none = AccessibilityHarvest(elements: [], quality: .unknown)
}
