import AutomationRuntime
import Foundation
import Memory
import SeatDriving

/// Runtime keeps terminal parsing in the CLI while all consumers share EngineRuntime's composition.
typealias Runtime = EngineRuntime

extension EngineRuntime {
    init(invocation: Invocation, seat: SeatTarget? = nil) {
        self.init(knowledgeDirectory: Self.knowledgeDirectory(invocation), seat: seat)
    }

    /// Where memory lives for this invocation: `--knowledge`, or the app's own Knowledge directory.
    static func knowledgeDirectory(_ invocation: Invocation) -> URL {
        if let path = invocation.options["knowledge"] {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mecum/Knowledge", isDirectory: true)
    }

    /// The recorder of one command line call: a `cli` producer, this process its stream and its trace,
    /// so the Brain learns from the command line as it always did and the calls stay apart.
    func commandLineRecorder() -> CallRecorder {
        recorder(ActionContext(source: .cli, streamID: CommandLineTrace.stream, traceID: CommandLineTrace.trace))
    }
}

/// CommandLineTrace names this invocation of `mecum` for the memory: one stream and one trace per process.
enum CommandLineTrace {
    static let trace  = UUID().uuidString
    static let stream = "mecum-\(ProcessInfo.processInfo.processIdentifier)"
}
