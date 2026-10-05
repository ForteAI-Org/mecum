//
//  AccessibilityAugmenter.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import PerceptionCore

/// AccessibilityAugmenter fills `SceneAugmenting` with the live accessibility tree: it finds the
/// window matching the capture, hops to the main actor for the reads, and runs the core's generic walk
/// under a wall-clock budget.
///
/// The budget is the guard against a pathological tree: a file browser exposing hundreds of rows
/// measured nine seconds per window unbounded. Running out returns the rows read so far, fewer labels
/// rather than wrong ones, and the quality says the walk stopped at its deadline. Reading needs the
/// Accessibility grant; without it every tree is empty, the answer is an empty list, not an error,
/// and the quality says the grant was absent. A capture whose frame matches no window of the tree
/// answers an empty list with `windowFound` false: that is not a denied grant, and the grant is
/// reported on its own.
public struct AccessibilityAugmenter: SceneAugmenting {

    private let budgetSeconds: TimeInterval
    private let messagingTimeoutSeconds: Float

    /// Creates an augmenter. `budgetSeconds` bounds one walk; `messagingTimeoutSeconds` bounds one
    /// message to the app. The walk checks its deadline between nodes; an in-flight message and
    /// its one transient retry can exceed the walk budget.
    public init(budgetSeconds: TimeInterval = 1.5, messagingTimeoutSeconds: Float = 2) {
        self.budgetSeconds           = budgetSeconds
        self.messagingTimeoutSeconds = messagingTimeoutSeconds
    }

    public func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> AccessibilityHarvest {
        let budget = budgetSeconds, timeout = messagingTimeoutSeconds
        return await MainActor.run {
            let trusted = AXIsProcessTrusted()
            let reader = LiveAccessibilityReader()
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: timeout)
            guard let window = reader.window(of: application, matching: windowFrame) else {
                return AccessibilityHarvest(
                    elements: [],
                    quality : CaptureQuality(windowFound: false, isGrantAvailable: trusted)
                )
            }
            let deadline = Date().addingTimeInterval(budget)
            var harvest = AccessibilityAugmentation.harvest(
                under      : window,
                windowFrame: windowFrame,
                reader     : reader,
                limits     : AccessibilityAugmentation.Limits(isPastDeadline: { Date() >= deadline })
            )
            harvest.quality.isGrantAvailable = trusted
            return harvest
        }
    }
}
