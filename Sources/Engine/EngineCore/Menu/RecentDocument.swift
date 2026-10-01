import Foundation

/// RecentDocument binds a recent-menu leaf to an absolute file path, never a guessed window title.
/// Only explicit File > Open Recent paths are supported; other menu semantics need another contract.
public struct RecentDocument: Sendable, Equatable {
    public let path: [String]
    public let filePath: String

    public init(path: [String]) throws {
        guard path.count == 3, MenuCatalog.key(path[0]) == "file",
              MenuCatalog.key(path[1]) == "open recent", path[2].hasPrefix("/"),
              !path[2].contains("\n"), !path[2].contains("\0"),
              (path[2] as NSString).standardizingPath == path[2],
              !(path[2] as NSString).pathExtension.isEmpty else {
            throw MenuFailure("Use an exact File > Open Recent leaf containing an absolute document path.")
        }
        self.path = path
        filePath = path[2]
    }

    /// Accepts the full document path, optionally with the application's unsaved marker.
    public func matches(windowTitle: String?) -> Bool {
        windowTitle == filePath || windowTitle == filePath + " *"
    }
}
