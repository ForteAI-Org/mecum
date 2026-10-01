import AppKit
import ApplicationServices
import CoreGraphics

/// WatcherAccess reads grants without prompting. Requests belong to explicit UI buttons.
struct WatcherAccess: Equatable {
    let inputMonitoring: Bool
    let screenRecording: Bool
    let accessibility: Bool

    static func current() -> Self {
        Self(inputMonitoring: CGPreflightListenEventAccess(),
             screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())
    }

    var blockingReason: String? {
        if !inputMonitoring { return "Allow Input Monitoring for Mecum in System Settings, then reopen Mecum." }
        if !screenRecording { return "Allow Screen Recording for Mecum in System Settings, then reopen Mecum." }
        return nil
    }
}

/// WatcherApplication identifies one running instance, not whichever app later reuses its PID.
struct WatcherApplication: Identifiable, Hashable {
    let processID: Int32
    let bundleID: String
    let name: String
    var launchedAt: Date? = nil
    var id: Int32 { processID }

    static func running() -> [Self] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.activationPolicy == .regular, !app.isTerminated,
                  let bundleID = app.bundleIdentifier else { return nil }
            return Self(processID: app.processIdentifier, bundleID: bundleID,
                        name: app.localizedName ?? bundleID, launchedAt: app.launchDate)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
