import PerceptionCore
import AutomationMCP
import SQLiteLivingMemory
import Foundation
import LocalMCP
import Memory
import Testing

/// Opt-in child fixture: each phase runs in a separate Swift test process over the same temporary store.
@MainActor
struct LivingMemoryProcessTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MECUM_RESTART_PHASE"] != nil))
    func restartPhase() async throws {
        let environment = ProcessInfo.processInfo.environment
        let phase = try #require(environment["MECUM_RESTART_PHASE"])
        let path = try #require(environment["MECUM_RESTART_DIRECTORY"])
        let root = URL(filePath: path, directoryHint: .isDirectory)
        let window = ControlSession.Window(
            bundleID: "test.synthetic.mixer",
            title: "Synthetic Mixer",
            toggles: [.init("Mute", .off)]
        )
        let process = try MecumProcess(knowledge: root, window: window)
        switch phase {
        case "learn":
            #expect(try await process.experiences().isEmpty)
            let (_, end) = try await process.turn("Attiva Mute") { tools, id in
                _ = try await tools.call("act", .object([
                    "session": id, "target": .string("Mute"),
                    "verb": .string("set_toggle"), "value": .string("on")
                ]))
            }
            #expect(end.report.decision.reason == .admittedSingleToggle)
            #expect(window.clicks == 1)
        case "correct":
            window.clickFlips = false
            let (start, end) = try await process.turn("Attiva Mute") { tools, id in
                _ = try await tools.call("act", .object([
                    "session": id, "target": .string("Mute"),
                    "verb": .string("set_toggle"), "value": .string("on")
                ]))
            }
            #expect(start.memory?.briefing?.status == "suggested")
            #expect(end.report.decision.reason == .contradictsFollowedExperience)
        case "verify":
            let record = try #require(try await process.experiences().first)
            #expect(record.successCount == 1)
            #expect(record.failureCount == 1)
            #expect(try await process.store.history(of: record.id).count == 2)
            #expect(try await !process.store.sightings(in: ["test.synthetic.mixer"]).isEmpty)
            #expect(window.clicks == 0)
        default:
            Issue.record("Unknown synthetic restart phase")
        }
        try String(ProcessInfo.processInfo.processIdentifier).write(
            to: root.appending(path: "\(phase).pid"),
            atomically: true,
            encoding: .utf8
        )
    }
}
