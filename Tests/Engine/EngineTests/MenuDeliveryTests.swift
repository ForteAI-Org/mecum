import CoreGraphics
import Engine
import EngineCore
import Foundation
import PerceptionCore
import Testing

@MainActor
@Suite("Native menu delivery never replays uncertain input")
struct MenuDeliveryTests {
    @MainActor
    final class Menus: ApplicationMenuOperating {
        var calls = 0
        let result: MenuDelivery
        init(_ result: MenuDelivery) { self.result = result }
        func catalog(processID: pid_t) throws -> MenuCatalog { .init(items: [], isComplete: true) }
        func invoke(path: [String], processID: pid_t) async throws -> MenuDelivery { calls += 1; return result }
    }
    actor Scenes: SceneProviding {
        var calls = 0
        func currentScene(of processID: pid_t) async throws -> PerceivedWindow {
            calls += 1
            guard calls == 1 else { throw MenuFailure("Synthetic capture loss after delivery") }
            var scene = SceneSnapshot(bundleID: "test.editor", appName: "Editor", windowTitle: "Edit",
                                      viewportPixelSize: .init(width: 800, height: 600), elements: [])
            scene.coverage = .window
            return PerceivedWindow(scene: scene, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        }
    }
    struct Windows: WindowListing {
        let destinationExists: Bool
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] { try allWindows(ownedBy: processID) ?? [] }
        func allWindows(ownedBy processID: pid_t) throws -> [WindowRow]? {
            [.init(layer: 0, frame: .init(x: 0, y: 0, width: 800, height: 600), title: "Edit", number: 1)]
                + (destinationExists ? [.init(layer: 8, frame: .init(x: 50, y: 50, width: 500, height: 400),
                                             title: "I/O Setup", number: 2)] : [])
        }
    }
    @Test(arguments: [MenuDelivery.requested, .uncertain("AX timeout")])
    func uncertainNativeOrCaptureResultStaysUnverified(_ delivery: MenuDelivery) async {
        let menus = Menus(delivery)
        let scenes = Scenes()
        let engine = MenuActionEngine(menus: menus, scenes: scenes, windows: Windows(destinationExists: false))
        let result = await engine.perform(path: ["Setup", "I/O..."], expectingWindow: "I/O Setup", processID: 123)
        #expect(result.kind == .actedUnverified)
        #expect(result.evidence?.menu?.isVerified == false)
        #expect(menus.calls == 1)
        #expect(await scenes.calls == (delivery == .requested ? 2 : 1))
    }
    @Test func formatCategoryDoesNotRefuseShowingFonts() async {
        let menus = Menus(.uncertain("Synthetic timeout after one delivery"))
        let engine = MenuActionEngine(menus: menus, scenes: Scenes(), windows: Windows(destinationExists: false))
        let result = await engine.perform(path: ["Format", "Font", "Show Fonts"],
                                          expectingWindow: "Fonts", processID: 123)
        #expect(menus.calls == 1)
        #expect(result.kind == .actedUnverified)
    }

    @Test func existingDestinationAndDestructivePathRefuseBeforeDelivery() async {
        for existing in [false, true] {
            let menus = Menus(.requested)
            let engine = MenuActionEngine(menus: menus, scenes: Scenes(), windows: Windows(destinationExists: existing))
            let result = await engine.perform(path: existing ? ["Setup", "I/O..."] : ["File", "Delete"],
                                              expectingWindow: "I/O Setup", processID: 123)
            #expect(result.kind == .refused)
            #expect(menus.calls == 0)
        }
    }
}
