import PerceptionCore

/// ActionRoute compares window controls with menu commands without performing either action.
/// Callers must choose an explicit tool after ambiguity; an execution never falls back across routes.
public struct ActionRoute: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case ui, menu, ambiguous, unavailable, incomplete }
    public let kind: Kind
    public let uiTarget: SceneElement?
    public let uiCount: Int
    public let menus: [MenuCatalog.Item]
    public let menuReadComplete: Bool

    public init(query: String, scene: SceneSnapshot, catalog: MenuCatalog) {
        let ui = scene.resolve(target: query, preferNativeControls: true)
        let candidates = catalog.items.filter {
            $0.path.last.map(MenuCatalog.key) == MenuCatalog.key(query)
        }
        menus = candidates
        menuReadComplete = catalog.isComplete
        switch ui {
        case .found(let element): uiTarget = element; uiCount = 1
        case .ambiguous(let count): uiTarget = nil; uiCount = count
        case .none: uiTarget = nil; uiCount = 0
        }
        if uiCount > 1 || candidates.count > 1 || (uiCount > 0 && !candidates.isEmpty) {
            kind = .ambiguous
        } else if !catalog.isComplete {
            kind = .incomplete
        } else if uiCount == 1 {
            kind = uiTarget?.isEnabled == false ? .unavailable : .ui
        } else if let menu = candidates.first, !menu.hasSubmenu, menu.isEnabled == true {
            kind = .menu
        } else {
            kind = .unavailable
        }
    }
}
