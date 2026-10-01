import CoreGraphics
import EngineCore
import Foundation
import PerceptionCore

/// Attests destruction of the uniquely identified source window in a single delivery transaction.
/// Visible absence alone is insufficient. Two complete inventories must agree after the gesture,
/// with no replacement or collateral window changes and at least one unchanged surviving window.
enum WindowClosure {
    static func title(
        of source: PerceivedWindow,
        visible: [WindowRow]?,
        before: [WindowRow]?,
        first: [WindowRow]?,
        second: [WindowRow]?
    ) -> String? {
        guard let visible, let before, let first, let second,
              !source.scene.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        func windows(_ rows: [WindowRow]) -> [WindowRow] {
            rows.filter { WindowSurfaceClassifier.isWindowLayer($0.layer) && $0.frame.width >= 60 && $0.frame.height >= 30 }
        }
        let prior = windows(before)
        let origins = prior.filter { $0.title == source.scene.windowTitle && $0.frame == source.frame }
        guard origins.count == 1, let origin = origins.first, origin.number > 0,
              visible.contains(origin), Set(before.map(\.number)).count == before.count,
              !first.contains(where: { $0.number == origin.number }),
              !second.contains(where: { $0.number == origin.number }) else { return nil }
        let survivors = Set(prior.filter { $0.number != origin.number })
        guard !survivors.isEmpty, Set(windows(first)) == survivors, Set(windows(second)) == survivors,
              !survivors.contains(where: { $0.title == origin.title }) else { return nil }
        return source.scene.windowTitle
    }
}
