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
///
/// A value is attributed only when everything read at the control's place reads that one value
/// in one place: the text painted there and the value the control's accessibility element reports.
/// Several elements there may be facets of one control, as its text and its chevron, or two
/// detections of one label, so they count as the values they read and where, not as elements. Readings of different values, or of one value in separate places, leave the control
/// unreadable, and the requested item is never preferred among them: what was asked must not
/// decide what the control shows.
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
        /// Nothing at the control's bounds reads a value: no element, or only unlabelled icons and
        /// labels recalled from memory rather than read in this capture.
        case nothingAtControl
        /// Elements at the control's bounds read different values, or one value in separate
        /// places, so none is the control's.
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
    /// overlaps the control's before bounds by more than half the smaller width and height, so the
    /// next dropdown grazing the control's edge is not read as its value.
    public static func atControl(
        _ bounds      : NormalizedRect,
        in scene      : SceneSnapshot,
        windowSizeKept: Bool
    ) -> DropdownReadback {
        guard windowSizeKept else { return .unreadable(.windowResized) }
        let atControl = scene.elements.filter { overlaps($0.bounds, bounds) }
        return attributed(atControl, as: DropdownReadback.window)
    }

    /// Reads the control's value in a recognition of its bounds alone, where every element is at
    /// the control.
    public static func inCrop(
        _ scene       : SceneSnapshot?,
        windowSizeKept: Bool
    ) -> DropdownReadback {
        guard windowSizeKept else { return .unreadable(.windowResized) }
        guard let scene else { return .unreadable(.cropUnavailable) }
        return attributed(scene.elements, as: DropdownReadback.controlCrop)
    }

    /// The one value `elements` read at one place, wrapped by `reading`, or why there is none. Text read
    /// in the pixels reads its label; an element the application's accessibility tree describes, which
    /// carries a role, reads its value, because its label is the control's name ("stile") and its value
    /// what it shows ("Regolare"), and it reads nothing without one. An unlabelled icon, a label recalled
    /// from memory, and text with no letter or digit read nothing. Values are compared as normalized label
    /// text, and every element that reads must read the first one's value and overlap it, so one value
    /// in two places is not one, nor a pixel reading that disagrees with the control's own.
    private static func attributed(
        _ elements: [SceneElement],
        as reading: (String) -> DropdownReadback
    ) -> DropdownReadback {
        let readings = elements.compactMap { element -> (element: SceneElement, value: String)? in
            guard !element.isUnlabeled, !element.isRecalled,
                  let value = element.role == nil ? element.label : element.value,
                  !LabelText.normalize(value).isEmpty else { return nil }
            return (element, value)
        }
        guard let first = readings.first else { return .unreadable(.nothingAtControl) }
        let value = LabelText.normalize(first.value)
        let onePlace = readings.allSatisfy { read in
            LabelText.normalize(read.value) == value && overlaps(read.element.bounds, first.element.bounds)
        }
        return onePlace ? reading(first.value) : .unreadable(.severalAtControl)
    }

    /// Whether two boxes share a place: they intersect over more than half the smaller width and more
    /// than half the smaller height, the rule `ControlAttribution` uses for a toggle's place.
    private static func overlaps(_ one: NormalizedRect, _ other: NormalizedRect) -> Bool {
        let (a, b) = (one.cgRect, other.cgRect)
        let overlap = a.intersection(b)
        return !overlap.isNull && overlap.width > min(a.width, b.width) * 0.5
            && overlap.height > min(a.height, b.height) * 0.5
    }
}
