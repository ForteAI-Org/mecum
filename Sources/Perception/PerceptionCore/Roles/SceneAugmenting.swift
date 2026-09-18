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
/// A conformer answers within its own budget and returns what it read by then; an app that exposes
/// nothing yields an empty array, which is a real answer. It throws only when it cannot read at all.
public protocol SceneAugmenting: Sendable {

    func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> [SceneElement]
}
