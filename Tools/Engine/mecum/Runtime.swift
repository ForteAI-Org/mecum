import AutomationRuntime
import EngineCore
import Foundation
import Memory
import SeatDriving

/// Runtime keeps terminal parsing in the CLI while all consumers share EngineRuntime's composition.
typealias Runtime = EngineRuntime

extension EngineRuntime {
    init(invocation: Invocation, seat: SeatTarget? = nil) {
        self.init(knowledgeDirectory: Self.knowledgeDirectory(invocation), seat: seat)
    }

    /// Where memory lives for this invocation: `--knowledge`, used as given, or the user's one Knowledge
    /// directory (`KnowledgeLocation`), shared with the app, whose earlier client archives it unifies.
    static func knowledgeDirectory(_ invocation: Invocation) -> URL {
        if let path = invocation.options["knowledge"] {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return sharedKnowledge()
    }

    /// The recorder of one command line call: a `cli` producer, this process its stream and its trace,
    /// so the Brain learns from the command line as it always did and the calls stay apart.
    func commandLineRecorder() -> CallRecorder {
        recorder(CommandLineTrace.context())
    }

    /// The user's one Knowledge directory, with its earlier client archives registered for unification.
    static func sharedKnowledge() -> URL {
        let support = KnowledgeLocation.support()
        let shared  = KnowledgeLocation.knowledge(under: support)
        MemoryService.unify(shared, with: KnowledgeLocation.legacyProfiles(under: support))
        return shared
    }

    /// A command line recorder over the memory of `knowledge`, for a command that builds no runtime.
    static func commandLineRecorder(knowledge: URL) -> CallRecorder {
        let service = MemoryService.shared(for: knowledge)
        return CallRecorder(memory: service, brain: BrainMemory(brains: service, applications: service,
                                                                clock: { service.clock.brainNow() }),
                            context: CommandLineTrace.context())
    }
}

/// CommandLineCall ends a command line action's call in the living memory with what it answered and the
/// check its path made. An end the memory cannot save is reported and thrown (`Unsaved`): the action
/// ran, its record is incomplete in the archive, and the command exits non zero, never acting again.
/// An end saved without parts the archive refused is reported too, as the record's gap.
enum CommandLineCall {

    struct Unsaved: Error, CustomStringConvertible {
        let reason: String
        var description: String { "the action ran, but its record was not saved: \(reason)" }
    }

    static func end(_ recorder: CallRecorder, outcome: ActOutcome, tool: AgentTool) async throws {
        do {
            try await recorder.end(.completed, result: .outcome(outcome.kind, message: outcome.message), tool: tool,
                                   check: outcome.withStatedCheck.check)
        } catch {
            print("memory: the action ran, but its record was not saved (\(error)); do not repeat it")
            throw Unsaved(reason: "\(error)")
        }
        if let gap = await recorder.recordingGap { print("memory: part of this call was not recorded: \(gap)") }
    }
}

/// CommandLineTrace names this invocation of `mecum` for the memory: one stream, one trace and one
/// session per process, since a process drives one Seat. A call that acts names its session, as the
/// contract requires of every tool but the listings.
enum CommandLineTrace {
    static let trace   = UUID().uuidString
    static let stream  = "mecum-\(ProcessInfo.processInfo.processIdentifier)"
    static let session = UUID().uuidString

    /// The context of a command line call of this invocation.
    static func context() -> ActionContext {
        ActionContext(source: .cli, streamID: stream, traceID: trace, sessionID: session)
    }
}
