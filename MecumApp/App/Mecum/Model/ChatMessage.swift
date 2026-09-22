import SeatBroker
import Foundation

/// One entry of the lab chat: what the person typed, what the runtime said,
/// an observation to draw, an executed action's report, or a planner run
/// that fills in while it goes.
struct ChatMessage: Identifiable {
    enum Role { case user, system }

    let id = UUID()
    let role: Role
    var text: String
    var observation: SceneObservation? = nil
    var report: ActionReport? = nil

    // Planner run state. `isRunning` shows the live stream in the bubble;
    // once done, `finalObservation` is the last frame the agent saw.
    var isRunning = false
    var runStatus: String? = nil
    var reports: [ActionReport] = []
    var finalObservation: SceneObservation? = nil
}
