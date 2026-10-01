import CoreGraphics
@testable import Engine
import EngineCore
import PerceptionCore
import Testing

@Suite("Native menu routing and effect verification")
struct MenuActionTests {
    private func scene(_ elements: [SceneElement] = [], title: String = "Edit") -> SceneSnapshot {
        var scene = SceneSnapshot(bundleID: "test.editor", appName: "Editor", windowTitle: title,
                      viewportPixelSize: .init(width: 800, height: 600), elements: elements)
        scene.coverage = .window
        return scene
    }

    @Test func separateMenuAndWindowRoutes() {
        let control = SceneElement(id: "export", kind: .control, label: "Export", bounds: .init(x: 0, y: 0, width: 0.1, height: 0.1))
        let catalog = MenuCatalog(items: [.init(path: ["File", "Export"], isEnabled: true)], isComplete: true)
        #expect(ActionRoute(query: "Export", scene: scene([control]), catalog: catalog).kind == .ambiguous)
        #expect(ActionRoute(query: "Export", scene: scene(), catalog: catalog).kind == .menu)
        #expect(ActionRoute(query: "Export", scene: scene([control]), catalog: .init(items: [], isComplete: true)).kind == .ui)
    }

    @Test func unavailableAndIncompleteDoNotBecomeActions() {
        for enabled: Bool? in [false, nil] {
            let catalog = MenuCatalog(items: [.init(path: ["Setup", "I/O…"], isEnabled: enabled)], isComplete: true)
            #expect(ActionRoute(query: "I/O...", scene: scene(), catalog: catalog).kind == .unavailable)
        }
        let partial = MenuCatalog(items: [.init(path: ["Setup", "I/O…"], isEnabled: true)], isComplete: false)
        #expect(ActionRoute(query: "I/O...", scene: scene(), catalog: partial).kind == .incomplete)
        let parent = MenuCatalog(items: [.init(path: ["File", "Export"], isEnabled: true, hasSubmenu: true)], isComplete: true)
        #expect(ActionRoute(query: "Export", scene: scene(), catalog: parent).kind == .unavailable)
    }

    @Test func duplicatePathsStayAmbiguous() {
        let item = MenuCatalog.Item(path: ["File", "Export"], isEnabled: true)
        let catalog = MenuCatalog(items: [item, item], isComplete: true)
        #expect(ActionRoute(query: "Export", scene: scene(), catalog: catalog).kind == .ambiguous)
        #expect(catalog.matching(path: ["File", "Export"]).count == 2)
    }

    @Test func openingNeedsNewIdentityTwoInventoriesAndMatchingCapture() {
        let parent = WindowRow(layer: 0, frame: .init(x: 0, y: 0, width: 800, height: 600), title: "Edit", number: 10)
        let dialog = WindowRow(layer: 8, frame: .init(x: 100, y: 100, width: 600, height: 400), title: "I/O Setup", number: 20)
        let source = PerceivedWindow(scene: scene(), frame: parent.frame)
        let after = PerceivedWindow(scene: scene(title: "I/O Setup"), frame: dialog.frame)
        func opened(_ before: [WindowRow], _ first: [WindowRow], _ second: [WindowRow]?, _ capture: PerceivedWindow) -> Bool {
            MenuActionEngine.openedWindow("I/O Setup", before: before, first: first, second: second, after: capture, source: source)
        }
        #expect(opened([parent], [parent, dialog], [parent, dialog], after))
        #expect(!opened([parent, dialog], [parent, dialog], [parent, dialog], after))
        #expect(!opened([parent], [parent], [parent, dialog], after))
        #expect(!opened([parent], [parent, dialog], nil, after))
        #expect(!opened([parent], [parent, dialog], [parent, dialog], source))
        #expect(!opened([parent], [parent, dialog], [parent, dialog, dialog], after))
    }
}
