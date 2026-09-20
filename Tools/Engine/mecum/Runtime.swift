import AutomationRuntime
import Foundation
import SeatDriving

/// Runtime keeps terminal parsing in the CLI while all consumers share EngineRuntime's composition.
typealias Runtime = EngineRuntime

extension EngineRuntime {
    init(invocation: Invocation, seat: SeatTarget? = nil) {
        let directory: URL
        if let path = invocation.options["knowledge"] {
            directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Mecum/Knowledge", isDirectory: true)
        }
        self.init(knowledgeDirectory: directory, seat: seat)
    }
}
