import Foundation

/// MenuEvidence keeps an explicit native path and the newly opened window verified after delivery.
/// The Engine issues openedWindow only after two complete inventories and an attributable capture.
public struct MenuEvidence: StepEvidence {
    public enum Effect: String, Sendable, Equatable, Codable { case openedWindow, unverified }
    public let bundleID: String
    public let windowTitle: String
    public let path: [String]
    public let expectedWindow: String
    public let effect: Effect

    public init(bundleID: String, windowTitle: String, path: [String], expectedWindow: String, effect: Effect) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.path = path
        self.expectedWindow = expectedWindow
        self.effect = effect
    }

    public var windowTitles: [String] { [windowTitle, expectedWindow] }
    public var isVerified: Bool {
        effect == .openedWindow && (2...8).contains(path.count)
            && path.allSatisfy { !MenuCatalog.key($0).isEmpty }
            && !expectedWindow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && windowTitle != expectedWindow && !bundleID.isEmpty
    }
}
