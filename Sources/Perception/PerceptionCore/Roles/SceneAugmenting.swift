//
//  SceneAugmenting.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics
import Foundation

/// SceneAugmenting supplies authoritative elements the pixels alone cannot give, for one window of one
/// process: named list rows, focusable fields, controls with their true state. It only ever adds;
/// the pipeline merges what it returns with `AccessibilityAugmentation.merge`.
///
/// A conformer answers within its own budget and returns what it read by then, together with the
/// quality of that read: an app that exposes nothing yields an empty list, which is a real answer,
/// and the quality says whether the walk finished, whether a window was found and, when knowable,
/// whether the grant was there. A conformer that cannot tell leaves those facts `nil`; it never
/// reports a complete read it did not make. It throws only when it cannot read at all.
public protocol SceneAugmenting: Sendable {

    func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> AccessibilityHarvest
}
