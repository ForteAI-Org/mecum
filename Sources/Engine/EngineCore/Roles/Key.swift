//
//  Key.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// Key is the handful of virtual key codes the engine presses by name. Real key events, which
/// applications treat as navigation and submission where a typed glyph would only insert itself.
public enum Key {

    public static let `return`: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    /// The key above Return, which deletes backwards.
    public static let delete: UInt16 = 51
    public static let escape: UInt16 = 53
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
}
