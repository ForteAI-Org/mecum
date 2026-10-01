import SwiftUI

/// WatcherCommands keeps the app-wide listener reachable even when its window is closed.
struct WatcherCommands: Commands {
    let watcher: WatcherModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Watcher") {
            Button("Show Watcher") { openWindow(id: WatcherView.windowID) }
            Button("Stop Watching") { Task { await watcher.stop() } }
                .disabled(!watcher.isActive || watcher.phase == .stopping)
        }
    }
}

struct WatcherToolbarButton: View {
    let watcher: WatcherModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button { openWindow(id: WatcherView.windowID) } label: {
            Image(systemName: watcher.isActive ? "waveform.circle.fill" : "waveform.circle")
                .foregroundStyle(watcher.isActive ? Color.accentColor : Color.secondary)
        }
        .help(watcher.isActive ? "Watcher is active" : "Open Watcher")
        .accessibilityLabel("Watcher")
        .accessibilityValue(watcher.statusTitle)
    }
}
