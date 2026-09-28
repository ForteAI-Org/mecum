//
//  ElsewhereGuide.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore

/// ElsewhereGuide names what changed outside the window that was perceived, from a census of the
/// application's windows before and after a gesture, or names the absence, which is the whole point:
/// an agent that knows nothing moved anywhere stops retrying the click. It is never silent, because
/// "nothing" is itself the answer a dead click needs.
///
/// The census is one application's windows and the wording says so. Widening it to every window on
/// screen would read a clock or another agent's window as the effect of this click.
public enum ElsewhereGuide {

    /// What the census found, and its one clause. `changed` lets a caller drop its own speculation
    /// instead of contradicting a fact: "the click likely did not register" must not be printed next
    /// to "a new window appeared".
    public struct Elsewhere: Sendable, Equatable {
        public let changed: Bool
        public let sentence: String

        public init(changed: Bool, sentence: String) {
            self.changed  = changed
            self.sentence = sentence
        }
    }

    /// One clause from two window censuses. An appearance wins, then a disappearance, then a retitle;
    /// a resize alone is not an effect, because live surfaces reflow their own bounds.
    public static func forUnverifiedAct(app: String, before: [SurfaceVerdict], after: [SurfaceVerdict]) -> Elsewhere {
        let had = Set(before.map(\.row.number))
        let has = Set(after.map(\.row.number))
        if let new = after.first(where: { !had.contains($0.row.number) }) {
            if isPopup(new) {
                return Elsewhere(changed: true, sentence: "Elsewhere a pop-up menu opened: the click did land; read "
                    + "the menu in the scene below (or Escape it).")
            }
            return Elsewhere(changed: true, sentence: "Elsewhere a NEW window \(name(new)) appeared: the effect "
                + "landed THERE; describe_scene reads it.")
        }
        if let gone = before.first(where: { !has.contains($0.row.number) }) {
            if isPopup(gone) {
                return Elsewhere(changed: true, sentence: "Elsewhere a pop-up menu closed: the click dismissed it "
                    + "rather than selecting in this window.")
            }
            return Elsewhere(changed: true, sentence: "Elsewhere the window \(name(gone)) closed: that was the "
                + "effect.")
        }
        for previous in before {
            guard let current = after.first(where: { $0.row.number == previous.row.number }) else { continue }
            let was = (previous.row.title ?? "").trimmingCharacters(in: .whitespaces)
            let now = (current.row.title ?? "").trimmingCharacters(in: .whitespaces)
            if was != now, !now.isEmpty {
                return Elsewhere(changed: true, sentence: "Elsewhere the window is now titled \"\(now)\": that was "
                    + "the effect.")
            }
        }
        return Elsewhere(
            changed : false,
            sentence: "Nothing else in \(app) changed either: no window of it opened, closed or retitled; "
                + "if the effect was meant for ANOTHER app verify there, otherwise this was a dead click, not a slow "
                    + "one."
        )
    }

    private static func isPopup(_ verdict: SurfaceVerdict) -> Bool {
        verdict.kind == .popupLayer || verdict.kind == .floatingList
    }

    private static func name(_ verdict: SurfaceVerdict) -> String {
        let title = (verdict.row.title ?? "").trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return "\"\(title)\"" }
        return "\(Int(verdict.row.frame.width))×\(Int(verdict.row.frame.height))pt"
    }
}
