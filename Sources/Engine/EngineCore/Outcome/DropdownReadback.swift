//
//  DropdownReadback.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

import CoreGraphics
import PerceptionCore

/// DropdownReadback is the value read back at a dropdown's own place after its menu closed, and
/// which reading produced it, or why no value can be attributed to the control.
///
/// The read uses the after-close capture the selector already took; it never asks for another.
/// Both readers attribute a value by the control's bounds from the before capture, so a window
/// whose size changed in between yields no reading rather than a value read somewhere else.
public enum DropdownReadback: Sendable, Equatable, Codable {

    /// The value read at the control's bounds in the full window scene.
    case window(String)

    /// The value read in a recognition of the control's bounds alone, for a control the full
    /// window scene could not resolve.
    case controlCrop(String)

    /// No value could be attributed to the control.
    case unreadable(Unreadable)

    /// Unreadable names why the after-close reading proves nothing about the control.
    public enum Unreadable: String, Sendable, Equatable, Codable {
        /// No element overlaps the control's bounds.
        case nothingAtControl
        /// Several elements overlap the control's bounds and none reads as the requested item.
        case severalAtControl
        /// The window changed size, so the before bounds no longer locate the control.
        case windowResized
        /// The control crop could not be recognized.
        case cropUnavailable
    }

    /// The value read, or nil when nothing was.
    public var value: String? {
        switch self {
            case .window(let value), .controlCrop(let value): value
            case .unreadable                                : nil
        }
    }

    /// Whether the value read is the requested item, compared as normalized label text.
    public func reads(_ item: String) -> Bool {
        value.map { LabelText.normalize($0) == LabelText.normalize(item) } ?? false
    }

    /// Reads the control's value in the full window scene. An element sits at the control when it
    /// overlaps the control's before bounds by more than half the smaller height. An element there
    /// that reads as the item wins; otherwise a lone element's label is the value.
    public static func atControl(
        _ bounds      : NormalizedRect,
        in scene      : SceneSnapshot,
        item          : String,
        windowSizeKept: Bool
    ) -> DropdownReadback {
        guard windowSizeKept else { return .unreadable(.windowResized) }
        let original = bounds.cgRect
        let atControl = scene.elements.filter { element in
            let current = element.bounds.cgRect
            let overlap = original.intersection(current)
            return !overlap.isNull && overlap.width > 0
                && overlap.height > min(original.height, current.height) * 0.5
        }
        if let match = atControl.first(where: { LabelText.normalize($0.label) == LabelText.normalize(item) }) {
            return .window(match.label)
        }
        switch atControl.count {
            case 0 : return .unreadable(.nothingAtControl)
            case 1 : return .window(atControl[0].label)
            default: return .unreadable(.severalAtControl)
        }
    }

    /// Reads the control's value in a recognition of its bounds alone. The item resolved in the
    /// crop wins; otherwise a lone element's label is the value.
    public static func inCrop(
        _ scene       : SceneSnapshot?,
        item          : String,
        windowSizeKept: Bool
    ) -> DropdownReadback {
        guard windowSizeKept else { return .unreadable(.windowResized) }
        guard let scene else { return .unreadable(.cropUnavailable) }
        if case .found(let value) = scene.resolve(target: item) { return .controlCrop(value.label) }
        switch scene.elements.count {
            case 0 : return .unreadable(.nothingAtControl)
            case 1 : return .controlCrop(scene.elements[0].label)
            default: return .unreadable(.severalAtControl)
        }
    }
}
