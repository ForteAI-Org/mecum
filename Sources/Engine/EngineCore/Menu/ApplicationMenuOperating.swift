import Foundation

/// ApplicationMenuOperating reads native menus and requests one leaf without activating the app.
/// An invocation re-resolves the whole path and validates the application's focused window against
/// the current Seat observation. No command is retried. Delivery alone is never effect evidence.
@MainActor
public protocol ApplicationMenuOperating: Sendable {
    func catalog(processID: pid_t) throws -> MenuCatalog
    func invoke(path: [String], processID: pid_t) async throws -> MenuDelivery
}

/// MenuDelivery reports the native call, including an error after delivery may have begun.
public enum MenuDelivery: Sendable, Equatable {
    case requested
    case uncertain(String)
}
