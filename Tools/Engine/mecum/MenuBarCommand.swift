import AppKit
import AutomationRuntime
import EngineCore
import Foundation
import PerceptionCore
import PrivateSymbols

/// MenuBarCommand exposes the same menu catalog, routing and execution used by the app's tools.
enum MenuBarCommand {
    static func run(_ invocation: Invocation) async throws {
        if invocation.command == "open-recent" {
            guard invocation.flags.contains("seat") else { throw UsageError.missing("--seat") }
            if invocation.flags.contains("allow-unvalidated-build") {
                FacilityGate.researchOptInForUnvalidatedBuilds = true
            }
            let knowledge = invocation.options["knowledge"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Mecum/Knowledge", isDirectory: true)
            let session = AutomationSession(knowledgeDirectory: knowledge)
            let outcome = try await session.openRecent(application: invocation.positional(0, "<app>"),
                                                       path: Array(invocation.positionals.dropFirst()))
            print("\(outcome.kind.rawValue): \(outcome.message)")
            if let scene = outcome.scene { print(scene.text()) }
            await session.close()
            if !outcome.isSuccess { throw ActFailure(outcome.kind) }
            return
        }
        let app = try ApplicationLookup.running(invocation.positional(0, "<app>"))
        if invocation.flags.contains("seat") {
            try await SeatRuntime.withSeat(app, invocation) { target in
                try await run(invocation, app, Runtime(invocation: invocation, seat: target))
            }
        } else {
            try await run(invocation, app, Runtime(invocation: invocation))
        }
    }

    private static func run(_ invocation: Invocation, _ app: NSRunningApplication, _ runtime: Runtime) async throws {
        switch invocation.command {
        case "menus":
            var catalog = try runtime.menuCatalog(processID: app.processIdentifier)
            if invocation.positionals.count > 1 {
                let query = MenuCatalog.key(invocation.positionals[1])
                catalog = MenuCatalog(items: catalog.items.filter { $0.path.contains { MenuCatalog.key($0).contains(query) } },
                                      isComplete: catalog.isComplete, issues: catalog.issues)
            }
            try printJSON(catalog)
        case "resolve":
            try await printJSON(runtime.resolveAction(invocation.positional(1, "<target>"), processID: app.processIdentifier))
        default:
            guard let expected = invocation.options["expect-window"] else { throw UsageError.missing("--expect-window <title>") }
            let outcome = await runtime.performMenu(path: Array(invocation.positionals.dropFirst()),
                                                    expectingWindow: expected, processID: app.processIdentifier,
                                                    allowsDestructive: invocation.flags.contains("allow-destructive"))
            print("\(outcome.kind.rawValue): \(outcome.message)")
            if let scene = outcome.scene { print(scene.text()) }
            await runtime.finish()
            if !outcome.isSuccess { throw ActFailure(outcome.kind) }
        }
    }

    private static func printJSON(_ value: some Encodable) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}
