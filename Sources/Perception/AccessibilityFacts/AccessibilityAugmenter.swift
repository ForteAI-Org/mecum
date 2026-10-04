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
/// rather than wrong ones. Reading needs the Accessibility grant; without it every tree is empty and
/// the answer is an empty array, not an error.
public struct AccessibilityAugmenter: SceneAugmenting {

    private let budgetSeconds: TimeInterval
    private let messagingTimeoutSeconds: Float
    private let windowNumberResolver: (@MainActor @Sendable (AXUIElement) -> Int?)?

    /// Creates an augmenter. `budgetSeconds` bounds one walk; `messagingTimeoutSeconds` bounds one
    /// message to the app. The walk checks its deadline between nodes; an in-flight message and
    /// its one transient retry can exceed the walk budget.
    /// `windowNumberResolver` binds identified captures to a native AX window. An absent or failed
    /// resolver yields no native facts for such a capture; it never falls back to geometry or focus.
    public init(
        budgetSeconds: TimeInterval = 1.5,
        messagingTimeoutSeconds: Float = 2,
        windowNumberResolver: (@MainActor @Sendable (AXUIElement) -> Int?)? = nil
    ) {
        self.budgetSeconds           = budgetSeconds
        self.messagingTimeoutSeconds = messagingTimeoutSeconds
        self.windowNumberResolver    = windowNumberResolver
    }

    public func augmentation(for processID: pid_t, windowFrame: CGRect) async throws -> [SceneElement] {
        await read(processID: processID, windowNumber: nil, windowFrame: windowFrame)
    }

    public func augmentation(
        for processID: pid_t, windowNumber: Int, windowFrame: CGRect
    ) async throws -> [SceneElement] {
        await read(processID: processID, windowNumber: windowNumber, windowFrame: windowFrame)
    }

    private func read(
        processID: pid_t, windowNumber: Int?, windowFrame: CGRect
    ) async -> [SceneElement] {
        let budget = budgetSeconds, timeout = messagingTimeoutSeconds, resolve = windowNumberResolver
        return await MainActor.run {
            guard windowNumber == nil || resolve != nil else { return [] }
            let reader = LiveAccessibilityReader()
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: timeout)
            guard let window = reader.window(
                of: application, matching: windowFrame,
                isCapturedWindow: { node in
                    guard let windowNumber else { return true }
                    return resolve?(node) == windowNumber
                }
            ) else { return [] }
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
