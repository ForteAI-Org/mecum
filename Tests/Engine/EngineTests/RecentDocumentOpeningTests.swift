import CoreGraphics
import Engine
import EngineCore
import Foundation
import PerceptionCore
import Synchronization
import Testing

@MainActor
@Suite("Recent document startup")
struct RecentDocumentOpeningTests {
    static let file = "/Projects/Example.prproj"
    static var path: [String] { ["File", "Open Recent", file] }

    final class Menus: ApplicationMenuOperating {
        var calls = 0
        var complete = true
        var enabled: Bool? = true
        var duplicate = false
        var result = MenuDelivery.requested
        func catalog(processID: pid_t) throws -> MenuCatalog {
            let item = MenuCatalog.Item(path: RecentDocumentOpeningTests.path, isEnabled: enabled)
            return .init(items: duplicate ? [item, item] : [item], isComplete: complete)
        }
        func invoke(path: [String], processID: pid_t) async throws -> MenuDelivery {
            try Task.checkCancellation()
            calls += 1
            return result
        }
    }

    final class Windows: WindowListing, Sendable {
        let reads: Mutex<Int> = .init(0)
        let frames: [[WindowRow]?]
        init(_ frames: [[WindowRow]?]) { self.frames = frames }
        func windows(ownedBy processID: pid_t) throws -> [WindowRow] { try allWindows(ownedBy: processID) ?? [] }
        func allWindows(ownedBy processID: pid_t) throws -> [WindowRow]? {
            reads.withLock { count in
                defer { count += 1 }
                return frames[min(count, frames.count - 1)]
            }
        }
    }

    func row(_ title: String = file, number: Int = 9) -> WindowRow {
        .init(layer: 0, frame: .init(x: 20, y: 20, width: 800, height: 600), title: title, number: number)
    }
    func scene(_ title: String = file) -> SceneSnapshot {
        var scene = SceneSnapshot(bundleID: "test.editor", appName: "Editor", windowTitle: title,
                                  viewportPixelSize: .init(width: 800, height: 600), elements: [])
        scene.coverage = .window
        return scene
    }
    func engine(_ menus: Menus, _ frames: [[WindowRow]?],
                wait: @escaping @MainActor () async throws -> Void = {}) -> RecentDocumentOpening {
        RecentDocumentOpening(menus: menus, windows: Windows(frames), attempts: 3, wait: wait)
    }

    @Test func opensFromNoWindowAndFromRetitledHomeWindow() async {
        for before in [[], [row("Home")]] {
            let menus = Menus()
            var adoptions = 0
            let result = await engine(menus, [before, [row()], [row()], [row()]])
                .perform(path: Self.path, processID: 123, bundleID: "test.editor") { title in
                    #expect(title == Self.file)
                    adoptions += 1
                    return scene(title)
                }
            #expect(result.kind == .foundActed)
            #expect(result.evidence == nil)
            #expect(adoptions == 1 && menus.calls == 1)
        }
    }

    @Test func refusesBeforeDeliveryWhenCatalogOrInventoryCannotAuthorize() async {
        for mode in 0..<6 {
            let menus = Menus()
            if mode == 0 { menus.enabled = false }
            if mode == 1 { menus.enabled = nil }
            if mode == 2 { menus.complete = false }
            if mode == 3 { menus.duplicate = true }
            let frames: [[WindowRow]?] = mode == 4 ? [[row()]] : mode == 5 ? [nil] : [[]]
            let result = await engine(menus, frames).perform(path: Self.path, processID: 123,
                                                           bundleID: "test.editor") { _ in
                Issue.record("Refused command must not adopt")
                return scene()
            }
            #expect(result.kind == .refused)
            #expect(menus.calls == 0)
        }
    }

    @Test func wrongOrAmbiguousDocumentNeverVerifies() async {
        for after in [[row("Example.prproj")], [row(), row(number: 10)], [row("/Other/Example.prproj")]] {
            let menus = Menus()
            let result = await engine(menus, [[], after]).perform(path: Self.path, processID: 123,
                                                                bundleID: "test.editor") { _ in
                return scene(after.first?.title ?? "")
            }
            #expect(result.kind == .actedUnverified)
            #expect(menus.calls == 1)
        }
    }

    @Test func uncertainDeliveryCancellationAndAdoptionFailureNeverReplay() async {
        for mode in 0..<3 {
            let menus = Menus()
            if mode == 0 { menus.result = .uncertain("AX timeout") }
            let result = await engine(menus, [[], [row()]], wait: {
                if mode == 1 { throw CancellationError() }
            }).perform(path: Self.path, processID: 123, bundleID: "test.editor") { _ in
                throw MenuFailure("Synthetic adoption failure")
            }
            #expect(result.kind == .actedUnverified)
            #expect(menus.calls == 1)
        }
    }

    @Test func intermediateDialogIsObservedWithoutConfirmingItOrClaimingDocumentSuccess() async {
        let menus = Menus()
        let result = await engine(menus, [[], [row("Link Media")]])
            .perform(path: Self.path, processID: 123, bundleID: "test.editor") { title in scene(title) }
        #expect(result.kind == .actedUnverified)
        #expect(result.scene?.windowTitle == "Link Media")
        #expect(menus.calls == 1)
    }

    @Test func captureMismatchCannotClaimSuccess() async {
        let menus = Menus()
        let result = await engine(menus, [[], [row()]]).perform(path: Self.path, processID: 123,
                                                              bundleID: "test.editor") { _ in scene("Home") }
        #expect(result.kind == .actedUnverified)
        #expect(menus.calls == 1)
    }

    @Test func pathContractNeverTreatsArbitraryCommandsAsStartup() throws {
        for path in [["File", "Open Recent", "Clear Menu"], ["File", "Delete", Self.file],
                     ["File", "Open Recent", "Example.prproj"], ["File", "Open Recent", "/a/../Example.prproj"]] {
            #expect(throws: MenuFailure.self) { try RecentDocument(path: path) }
        }
        let document = try RecentDocument(path: Self.path)
        #expect(document.matches(windowTitle: Self.file + " *"))
        #expect(!document.matches(windowTitle: "Example"))
    }
}
