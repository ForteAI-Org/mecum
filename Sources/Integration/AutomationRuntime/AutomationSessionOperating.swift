import EngineCore
import Foundation
import PerceptionCore

/// AutomationSessionOperating is the application-session boundary consumed by tool adapters.
/// Calls are serialized by the owner. close follows cancellation/draining and invalidates the session ID.
@MainActor
public protocol AutomationSessionOperating: AnyObject {
    var id: UUID? { get }
    func open(application: String, window: String?) async throws -> SceneSnapshot
    func observe() async throws -> SceneSnapshot
    func act(target: String, verb: ActionVerb, section: String?, desiredState: ControlState?) async throws -> ActOutcome
    func select(control: String, item: String) async throws -> ActOutcome
    func close() async
}
