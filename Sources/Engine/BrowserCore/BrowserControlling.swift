import Foundation

/// BrowserControlling operates on explicit browser tabs, independently of Seat, MCP and a model provider.
/// Calls must not overlap. Connections borrow the browser: disconnect never closes it or deletes its profile.
/// References belong to one snapshot and connection. Effects are never replayed after a transport failure.
public protocol BrowserControlling: Sendable {
    func connect(profile: BrowserProfile) async throws -> BrowserConnection
    func disconnect() async throws
    func tabs() async throws -> [BrowserTab]
    func open(url: String) async throws -> BrowserTab
    func close(tab: String) async throws
    func snapshot(tab: String, options: BrowserObservationOptions) async throws -> BrowserSnapshot
    /// Reads article content without exposing an arbitrary page-script evaluator.
    func readContent(tab: String) async throws -> BrowserContentPage
    /// Advances the main document for article collection, without a trusted wheel event or tab activation.
    func advanceContent(tab: String, by pixels: Double) async throws -> BrowserReceipt
    func perform(_ action: BrowserAction, tab: String, snapshot: String?) async throws -> BrowserReceipt
    func screenshot(tab: String) async throws -> Data
    func dialog(tab: String) async throws -> BrowserDialog?
    func handleDialog(tab: String, accept: Bool, text: String?) async throws -> BrowserReceipt
}

/// BrowserProfile chooses existing user authorization or a separate, reusable automation profile.
public enum BrowserProfile: String, Sendable, Codable {
    case current, automation
}

public extension BrowserControlling {
    /// Adapters without semantic article reading explicitly refuse this optional capability.
    func readContent(tab: String) async throws -> BrowserContentPage {
        throw BrowserFailure(.unavailable, "This browser adapter does not support article collection.")
    }

    func advanceContent(tab: String, by pixels: Double) async throws -> BrowserReceipt {
        throw BrowserFailure(.unavailable, "This browser adapter does not support document scrolling for collection.")
    }

    /// Reads a compact page or dialog using the default observation bounds.
    func snapshot(tab: String) async throws -> BrowserSnapshot {
        try await snapshot(tab: tab, options: BrowserObservationOptions())
    }
}
