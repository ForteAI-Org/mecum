import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

/// WatcherPermissionsView requests only the grant the person explicitly selects.
struct WatcherPermissionsView: View {
    let watcher: WatcherModel

    var body: some View {
        if let reason = watcher.access.blockingReason {
            VStack(alignment: .leading, spacing: 8) {
                Text(reason).font(.callout)
                HStack {
                    if !watcher.access.inputMonitoring {
                        Button("Allow Input Monitoring…") {
                            _ = CGRequestListenEventAccess()
                            open("Privacy_ListenEvent")
                        }
                    }
                    if !watcher.access.screenRecording {
                        Button("Allow Screen Recording…") {
                            _ = CGRequestScreenCaptureAccess()
                            open("Privacy_ScreenCapture")
                        }
                    }
                    Button("Check Again") { watcher.refreshEnvironment() }
                }
            }
        } else if !watcher.access.accessibility {
            HStack {
                Text("Accessibility is unavailable. Watching will use visual perception.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Allow Accessibility…") {
                    // The SDK exposes this immutable option key as a concurrency-unsafe mutable global.
                    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                    open("Privacy_Accessibility")
                }
            }
        }
    }

    private func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) {
            NSWorkspace.shared.open(url)
        }
        watcher.refreshEnvironment()
    }
}
