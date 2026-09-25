//
//  ComputerSettings.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 24/09/2026.
//

import AppKit
import SeatBroker
import SwiftUI

/// ComputerSettings is what a worker needs to use this Mac: the macOS
/// permissions its seat asks for, read again whenever the app comes back to
/// the front, since they are granted in System Settings, and this Mac's build
/// with whether the kit's ledger lists it.
struct ComputerSettings: View {

    let broker: SeatBroker

    @State private var grants       : [DesktopGrant] = []
    @State private var validation   : BuildValidation?
    @State private var needsRelaunch = false

    /// True once the person asked for the permissions here. Only then is Screen Recording
    /// checked for a relaunch: that check asks ScreenCaptureKit, which can raise its own prompt.
    @State private var hasAsked = false

    var body: some View {
        Form {
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
                            Button("Allow…", action: allow)
                                .controlSize(.small)
                        }
                    }
                }

                if needsRelaunch {
                    LabeledContent("Restart Required") {
                        Button("Quit and Reopen", action: relaunch)
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Mecum requests each permission when a worker first needs it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validation {
                Section {
                    LabeledContent(
                        "macOS",
                        value: "\(validation.productVersion) (\(validation.build))"
                    )
                    LabeledContent("Seat") {
                        if validation.isValidated {
                            Text("Validated")
                        } else {
                            Text("Not Validated")
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("This Mac")
                } footer: {
                    if !validation.isValidated {
                        Text("Workers can still use this Mac, but this macOS build has not been validated. Mecum records that status with each action.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await read() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await read() }
        }
    }

    private func read() async {
        grants     = broker.desktopGrants()
        validation = broker.buildValidation()
        if hasAsked { needsRelaunch = await broker.screenRecordingNeedsRelaunch() }
    }

    /// Asks macOS for the missing permissions; a prompt already answered no is only reachable in
    /// System Settings, which opens then.
    private func allow() {
        hasAsked = true
        if !broker.requestMissingPermissions() { broker.openPermissionSettings() }
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
