import AppKit
import SwiftUI

/// WatcherView presents the app-owned listener. Closing the panel leaves its explicit run active;
/// the toolbar and menu keep its state reachable. Quit joins teardown through the app delegate.
struct WatcherView: View {
    static let windowID = "watcher"
    @Bindable var watcher: WatcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(watcher.statusTitle, systemImage: watcher.isActive ? "waveform.circle.fill" : "waveform.circle")
                    .font(.headline)
                    .foregroundStyle(watcher.isActive ? Color.accentColor : Color.secondary)
                    .accessibilityIdentifier("watcher.status")
                Spacer()
                if watcher.isActive {
                    Button("Stop Watching") { Task { await watcher.stop() } }
                        .disabled(watcher.phase == .stopping)
                        .accessibilityIdentifier("watcher.stop")
                } else {
                    Button("Start Watching") { watcher.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!watcher.canStart)
                        .accessibilityIdentifier("watcher.start")
                }
            }
            Picker("Application", selection: $watcher.selectedApplication) {
                Text("All applications").tag(nil as WatcherApplication?)
                if let selected = watcher.selectedApplication, !watcher.applications.contains(selected) {
                    Text("\(selected.name) (closed)").tag(Optional(selected))
                }
                ForEach(watcher.applications) { app in Text(app.name).tag(Optional(app)) }
            }
            .disabled(watcher.isActive)
            .accessibilityIdentifier("watcher.application")
            Text(watcher.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            if case .failed(let reason) = watcher.phase {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            WatcherPermissionsView(watcher: watcher)
            HStack {
                Text("Recent observations (\(watcher.entries.count) of \(watcher.totalEvents))")
                    .font(.headline)
                Spacer()
                Button("Clear") { watcher.clear() }.disabled(watcher.entries.isEmpty)
            }
            if watcher.entries.isEmpty {
                ContentUnavailableView("No Observations Yet", systemImage: "cursorarrow.rays",
                    description: Text("Start watching, move into the selected app and wait for Ready before clicking."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(watcher.entries) { entry in WatcherEventRow(entry: entry) }
                    .listStyle(.inset)
                    .accessibilityIdentifier("watcher.events")
            }
            Text("The latest 100 observations stay in this app session. Closing this window keeps watching active. Stop Watching ends capture. Observations are not learned actions.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 600, idealWidth: 780, minHeight: 540, idealHeight: 720)
        .task { watcher.refreshEnvironment() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            watcher.refreshEnvironment()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            watcher.refreshEnvironment()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            watcher.refreshEnvironment()
        }
    }
}

private struct WatcherEventRow: View {
    let entry: WatcherEntry

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.window).foregroundStyle(.secondary)
                Text(entry.input).foregroundStyle(.secondary)
                LabeledContent("Before", value: entry.before)
                LabeledContent("After", value: entry.after)
                LabeledContent("Accessibility", value: entry.accessibility)
                if let change = entry.change { Text(change).foregroundStyle(.secondary) }
            }
            .font(.callout).textSelection(.enabled).padding(.vertical, 6)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title).lineLimit(2)
                    Text(entry.before).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(entry.time, style: .time).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
