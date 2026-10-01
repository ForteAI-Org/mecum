import AutomationRuntime
import EngineCore
import PerceptionCore
import Testing

@MainActor
@Suite("Shared native menu delivery")
struct MenuInvocationTests {
    private let scene = SceneSnapshot(bundleID: "test.menu", appName: "Editor", windowTitle: "New",
        viewportPixelSize: .init(width: 800, height: 600), elements: [])

    @Test func uncertainDeliveryIsNotLearnableAndIsNeverRepeated() async throws {
        let menus = MenuInvocationAdapter()
        menus.delivery = .uncertain("AX timed out")
        let result = try await MenuBarCommand.perform(["File", "New"], menus: menus, processID: 42,
            allowsDestructive: false, readWindows: { menus.invocations == 0 ? ["Old"] : ["Old", "New"] },
            settle: {}, observe: { scene })
        #expect(menus.invocations == 1)
        #expect(result.kind == .actedUnverified)
        #expect(result.evidence == nil)
    }

    @Test func disabledMenuRefreshesBeforeOneSharedInvocation() async throws {
        let menus = MenuInvocationAdapter()
        menus.enabled = false
        var refreshes = 0
        let result = try await MenuBarCommand.perform(["File", "New"], menus: menus, processID: 42,
            allowsDestructive: false, refresh: { refreshes += 1; menus.enabled = true; return true },
            readWindows: { menus.invocations == 0 ? ["Old"] : ["Old", "New"] },
            settle: {}, observe: { scene })
        #expect(refreshes == 1)
        #expect(menus.invocations == 1)
        #expect(menus.requestedPath == ["File", "New..."])
        #expect(result.kind == .foundActed)
        #expect(result.evidence == nil)
    }

    @Test func partialUnknownAndDuplicateCatalogsNeverDispatchOrRefresh() async throws {
        for scenario in ["partial", "unknown", "duplicate"] {
            let menus = MenuInvocationAdapter()
            if scenario == "partial" { menus.complete = false }
            if scenario == "unknown" { menus.enabled = nil }
            if scenario == "duplicate" { menus.duplicate = true }
            let result = try await MenuBarCommand.perform(["File", "New"], menus: menus, processID: 42,
                allowsDestructive: false, refresh: { Issue.record("Must not refresh uncertain metadata"); return true },
                readWindows: { [] }, settle: {}, observe: { scene })
            #expect(result.kind == .refused || result.kind == .ambiguous)
            #expect(menus.invocations == 0)
        }
    }

    @Test func listingAndMissingReadbackDoNotPretendAnActionSucceeded() async throws {
        let menus = MenuInvocationAdapter()
        let listed = try await MenuBarCommand.perform(["File"], menus: menus, processID: 42,
            allowsDestructive: false, settle: {}, observe: { scene })
        #expect(listed.kind == .actedNoop)
        #expect(menus.invocations == 0)
        let unknown = try await MenuBarCommand.perform(["File", "New"], menus: menus, processID: 42,
            allowsDestructive: false, readWindows: { nil }, settle: {}, observe: { scene })
        #expect(unknown.kind == .actedUnverified)
        #expect(menus.invocations == 1)
        #expect(!MenuBarCommand.windowsChanged(before: ["A", "B"], after: ["B", "A"]))
    }
}

@MainActor
private final class MenuInvocationAdapter: ApplicationMenuOperating {
    var enabled: Bool? = true
    var complete = true
    var duplicate = false
    var invocations = 0
    var requestedPath: [String] = []
    var delivery: MenuDelivery = .requested

    func catalog(processID: Int32) throws -> MenuCatalog {
        var items: [MenuCatalog.Item] = [
            .init(path: ["Apple"], isEnabled: true, hasSubmenu: true),
            .init(path: ["File"], isEnabled: true, hasSubmenu: true),
            .init(path: ["File", "New..."], isEnabled: enabled)
        ]
        if duplicate { items.append(.init(path: ["File", "New…"], isEnabled: true)) }
        return MenuCatalog(items: items, isComplete: complete)
    }
    func invoke(path: [String], processID: Int32) async throws -> MenuDelivery {
        invocations += 1
        requestedPath = path
        return delivery
    }
}
