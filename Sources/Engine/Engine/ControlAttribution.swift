//
//  ControlAttribution.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 27/09/2026.
//

import CoreGraphics
import EngineCore
import PerceptionCore

/// ControlAttribution finds, in a later perception, the control an action resolved in an earlier
/// one, or says why no element can be attributed to it. It is the one rule every toggle reading
/// after resolution uses, so a state is never taken from a control that only shares a name.
///
/// Element ids are derived from the kind and the label (`SceneIdentity`), so several controls with
/// one label share an id by design: an id alone never identifies a control. A candidate must be in
/// the same application and window family, and in the same section, with the same id or with the
/// same label and a state. Before an action, one candidate is the control wherever it is now: it is
/// what the requested name resolves to in that section, so a control that moved is acted on where it
/// is. Across an action, a reading must be of the control acted on, and neither a label nor a
/// label-derived id proves that alone: every candidate, one included, must still cover the control's
/// earlier bounds in a window of unchanged size, over more than half of the smaller width and of the
/// smaller height, so a homonym beside it that only grazes its place is not it. Several candidates
/// are settled only by that place, never by the state a request wants. Anything else attributes
/// nothing, so a control that moved because of the action reads as not attributable rather than
/// borrowing a homonym's state.
enum ControlAttribution {

    /// Result is the attributed element, and whether it matched by id or by label, or why none was.
    enum Result: Equatable {
        case found(SceneElement, ToggleEvidence.Reading.Source)
        case unreadable(ToggleEvidence.Reading.Unreadable)
    }

    /// The element of `later` that is `control`, as it was resolved in `earlier`. `acrossAction` says
    /// whether an action was delivered in between, which requires the place even for one candidate.
    static func find(
        _ control   : SceneElement,
        from earlier: PerceivedWindow,
        in later    : PerceivedWindow,
        acrossAction: Bool = false
    ) -> Result {
        guard later.scene.bundleID == earlier.scene.bundleID,
              LabelText.letters(later.scene.windowTitle) == LabelText.letters(earlier.scene.windowTitle) else {
            return .unreadable(.otherWindow)
        }
        let label = LabelText.normalize(control.label)
        let candidates = later.scene.elements.filter { element in
            let named = element.id == control.id
                || (element.state != nil && LabelText.normalize(element.label) == label)
            return named && element.section == control.section
        }
        let chosen: SceneElement
        switch candidates.count {
            case 0:
                return .unreadable(.notFound)
            case 1 where !acrossAction:
                chosen = candidates[0]
            case 1:
                guard later.frame.size == earlier.frame.size, covers(candidates[0].bounds, control.bounds) else {
                    return .unreadable(.notAtPlace)
                }
                chosen = candidates[0]
            default:
                // Normalized bounds locate the same place only while the window keeps its size.
                guard later.frame.size == earlier.frame.size else { return .unreadable(.severalMatches) }
                let atPlace = candidates.filter { covers($0.bounds, control.bounds) }
                guard atPlace.count == 1 else { return .unreadable(.severalMatches) }
                chosen = atPlace[0]
        }
        return .found(chosen, chosen.id == control.id ? .sameElement : .sameLabel)
    }

    /// Whether two bounds overlap by more than half the smaller width and more than half the smaller
    /// height, the readback rule for "at the control's place": a control repainted a little moved or
    /// resized covers it, the next strip's homonym touching its edge does not.
    private static func covers(_ bounds: NormalizedRect, _ original: NormalizedRect) -> Bool {
        let overlap = original.cgRect.intersection(bounds.cgRect)
        return !overlap.isNull && overlap.width > min(original.width, bounds.width) * 0.5
            && overlap.height > min(original.height, bounds.height) * 0.5
    }
}
