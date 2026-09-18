//
//  ActivationPolicy.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation

/// ActivationPolicy decides whether a gesture needs the application raised first. Two rules, both
/// bought with a failure: never while a pop-up menu is open, because the activation event cancels
/// menu tracking and the click lands on the window behind it; and never when the application is
/// already in front, because the activation is a no-op but the settle after it is a fifth of the
/// round trip. Not knowing which application is in front is not evidence of being in front.
public enum ActivationPolicy {

    public static func needsActivation(target: pid_t, frontmost: pid_t?, isPopupOpen: Bool) -> Bool {
        if isPopupOpen { return false }
        return frontmost != target
    }
}
