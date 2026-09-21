//
//  AccessibilityPopupReader.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import ApplicationServices
import CoreGraphics
import Foundation
import PerceptionCore

/// AccessibilityPopupReader fills `PopupRowReading` with the live accessibility tree: it hops to the
/// main actor for the reads and runs the core's generic menu walk under a wall-clock budget.
///
/// The budget is smaller than the augmenter's on purpose. A menu is open while this runs, which
/// means the application's main thread is busy tracking it and every request queues behind that, and
/// a pop-up nobody can read has to be given up on quickly enough for the pixel row cut to still be
/// worth doing. Running out returns the rows read so far: fewer rows, never wrong ones. Without the
/// Accessibility grant every tree is empty and the answer is an empty list, not an error.
public struct AccessibilityPopupReader: PopupRowReading {

    private let budgetSeconds          : TimeInterval
    private let messagingTimeoutSeconds: Float

    /// Creates a reader. `budgetSeconds` bounds one walk; `messagingTimeoutSeconds` bounds one
    /// message to the application. An in-flight message and its one transient retry can exceed the
    /// walk budget, which is why both exist.
    public init(budgetSeconds: TimeInterval = 1.5, messagingTimeoutSeconds: Float = 2) {
        self.budgetSeconds           = budgetSeconds
        self.messagingTimeoutSeconds = messagingTimeoutSeconds
    }

    public func popupRows(ofProcess processID: pid_t, popupFrame: CGRect?) async -> [PopupRow] {
        let budget = budgetSeconds, timeout = messagingTimeoutSeconds
        return await MainActor.run {
            let reader = LiveAccessibilityReader()
            let application = reader.application(processID: processID)
            reader.setMessagingTimeout(application, seconds: timeout)
            // The focused window first: a dropdown's list hangs off its pop-up button, the common
            // case and the cheapest place to find it. The application element has the menu bar under
            // it, and a context menu hangs off the application itself.
            var roots = [AXUIElement]()
            if let window = reader.mainWindow(of: application) { roots.append(window) }
            roots.append(application)
            let deadline = Date().addingTimeInterval(budget)
            return PopupRowHarvest.rows(
                among     : roots,
                popupFrame: popupFrame,
                reader    : reader,
                limits    : PopupRowHarvest.Limits(isPastDeadline: { Date() >= deadline })
            )
        }
    }
}
