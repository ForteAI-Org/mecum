import CoreGraphics
import Foundation

/// An application the lab can drive: installed, and possibly running with
/// on-screen windows. A not-running app has no pid and no windows until the
/// runtime launches it.
public struct TargetApp: Sendable, Identifiable, Hashable {
    /// Two running instances of the same helper share a bundle identifier —
    /// the open and save panel service runs one process per host — so what has
    /// no bundle of its own is identified by the process it is.
    public var id: String { bundleURL?.path ?? (pid.map { "\(bundleID)#\($0)" } ?? bundleID) }
    public let pid: pid_t?
    public let bundleID: String
    public let name: String
    public let bundleURL: URL?
    public let windows: [TargetWindow]

    /// `CFBundleName`, which `name` hides when the bundle also declares a display name.
    public let bundleName: String?

    /// `CFBundleShortVersionString`, when the bundle declares one.
    public let version: String?

    /// When the person last opened it, as Spotlight recorded it; nil when Spotlight has no date.
    public let lastUsed: Date?

    public var isRunning: Bool { pid != nil }

    public init(pid: pid_t?, bundleID: String, name: String, bundleURL: URL?, windows: [TargetWindow],
                bundleName: String? = nil, version: String? = nil, lastUsed: Date? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundleURL = bundleURL
        self.windows = windows
        self.bundleName = bundleName
        self.version = version
        self.lastUsed = lastUsed
    }
}

/// One window of a running application, as the window server lists it.
/// `frame` is in global top-left points.
public struct TargetWindow: Sendable, Identifiable, Hashable {
    public var id: Int { windowNumber }
    public let pid: pid_t
    public let windowNumber: Int
    public let title: String
    public let frame: CGRect
}
