//
//  AccessibilityFrameTrust.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 15/09/2026.
//

import CoreGraphics

/// AccessibilityFrameTrust is the one rule about accessibility geometry: a frame is trusted only where
/// it lies inside the window the window server reports.
///
/// After a window is moved through the window server, an app's child frames are not refreshed and
/// keep the window's old position. Measured twice: Premiere's header tabs reported at x 169 and 279
/// while the window sat at x 2036; its Sample Rate combo box reported at x 2725 while the window sat
/// at x 1096. Normalizing such a frame against the real window gives a point nowhere near the
/// control, and it fails silently. Putting the rule here, pure and tested, makes every adapter obey it.
public enum AccessibilityFrameTrust {

    /// True when the frame has area and intersects the window's real frame.
    public static func isTrustworthy(_ frame: CGRect, in windowFrame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height,
         windowFrame.minX, windowFrame.minY, windowFrame.width, windowFrame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0 && windowFrame.intersects(frame)
    }

    /// The visible intersection normalized to the window, when it is trustworthy; nil otherwise.
    public static func normalized(_ frame: CGRect, in windowFrame: CGRect) -> NormalizedRect? {
        guard isTrustworthy(frame, in: windowFrame), windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        let frame = frame.intersection(windowFrame)
        return NormalizedRect(
            x     : Double((frame.minX - windowFrame.minX) / windowFrame.width),
            y     : Double((frame.minY - windowFrame.minY) / windowFrame.height),
            width : Double(frame.width / windowFrame.width),
            height: Double(frame.height / windowFrame.height)
        )
    }
}
