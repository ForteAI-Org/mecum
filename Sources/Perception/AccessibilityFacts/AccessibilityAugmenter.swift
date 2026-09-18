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
/// process's main window, hops to the main actor for the reads, and runs the core's generic walk
/// under a wall-clock budget.
///
/// The budget is the guard against a pathological tree: a file browser exposing hundreds of rows
/// measured nine seconds per window unbounded. Running out returns the rows read so far, fewer labels
/// rather than wrong ones. Reading needs the Accessibility grant; without it every tree is empty and
/// the answer is an empty array, not an error.
public struct AccessibilityAugmenter: SceneAugmenting {

    private let budgetSeconds: TimeInterval
    private let messagingTimeoutSeconds: Float

    /// Creates an augmenter. `budgetSeconds` bounds one walk; `messagingTimeoutSeconds` bounds one
    /// message to the app.
    public init(budgetSeconds: TimeInterval = 1.5, messagingTimeoutSeconds: Float = 2) {
        self.budgetSeconds           = budgetSeconds
        self.messagingTimeoutSeconds = messagingTimeoutSeconds
    }

    public func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> [SceneElement] {
        let budget = budgetSeconds, timeout = messagingTimeoutSeconds
        return await MainActor.run {
            let reader = LiveAccessibilityReader()
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: timeout)
            guard let window = reader.mainWindow(of: application) else { return [] }
            let deadline = Date().addingTimeInterval(budget)
            return AccessibilityAugmentation.elements(
                under      : window,
                windowFrame: windowFrame,
                reader     : reader,
                limits     : AccessibilityAugmentation.Limits(isPastDeadline: { Date() >= deadline })
            )
        }
    }
}
