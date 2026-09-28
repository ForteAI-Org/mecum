//
//  PermissionsSection.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import AppKit
import SeatBroker
import SwiftUI

/// PermissionsSection lists the macOS permissions a worker's seat needs, each with its own Allow
/// button, read again whenever the app comes back to the front, since they are granted in System
/// Settings. The Settings page and the first launch's Mac Access sheet show the same section.
///
/// Each button asks for its one permission: its system prompt the first time, its pane of System
/// Settings after that. Asking for all of them at once raised several prompts together, and macOS
/// showed only one.
struct PermissionsSection: View {

    let broker: SeatBroker

    @State private var grants       : [DesktopGrant] = []
    @State private var needsRelaunch = false

    /// True once the person asked for a permission here. Only then is Screen Recording
    /// checked for a relaunch: that check asks ScreenCaptureKit, which can raise its own prompt.
    @State private var hasAsked = false

    var body: some View {
        Section {
            ForEach(grants) { grant in
                LabeledContent(grant.name) {
                    if grant.isGranted {
                        Label(
                            "Granted",
                            systemImage: "checkmark.circle.fill"
                        )
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                        .help("Granted")
                    } else {
                        Button("Allow…") { allow(grant) }
                            .controlSize(.small)
                    }
                }
            }

            if needsRelaunch {
                LabeledContent("Restart Required") {
                    Button(
                        "Quit and Reopen",
                        action: relaunch
                    )
                    .controlSize(.small)
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Each permission opens its macOS prompt the first time, then its page in System Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await read() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await read() }
        }
    }

    private func read() async {
        grants = broker.desktopGrants()
        if hasAsked { needsRelaunch = await broker.screenRecordingNeedsRelaunch() }
    }

    private func allow(_ grant: DesktopGrant) {
        hasAsked = true
        broker.request(grant)
        Task { await read() }
    }

    /// Screen Recording reaches only a fresh process, so the app opens itself again and quits.
    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at           : Bundle.main.bundleURL,
            configuration: configuration
        ) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
