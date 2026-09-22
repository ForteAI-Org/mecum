import SeatBroker
import SwiftUI

/// The whole app: the chat, and the chrome that has to be reachable whether or
/// not a seat exists. The capability badge and the permissions alert live here
/// rather than in `ChatView` because a fresh installation has no seat, no
/// application and no grants, and those two are the only way to get any.
struct ContentView: View {

    @Bindable
    var model: AppModel

    var body: some View {
        ChatView(model: model)
            .frame(minWidth: 720, minHeight: 520)
            .toolbar {
                ToolbarItem { seatBadge }
                ToolbarItem { capabilityBadge }
                ToolbarItem {
                    Button("Run history", systemImage: "clock.arrow.circlepath") { model.showsHistory = true }
                }
                ToolbarItem {
                    // Available whenever there is a seat, busy or not: it was
                    // grey for exactly as long as it was needed.
                    Button("End seat", systemImage: "stop.circle") { Task { await model.closeSession() } }
                        .disabled(model.session == nil)
                }
            }
            // A Screen Recording grant only reaches a fresh process, so the app
            // restarts itself and says so before the window disappears.
            .overlay(alignment: .bottom) {
                if model.relaunchPending {
                    Text("Screen Recording granted — relaunching Mecum…")
                        .padding(10).glassEffect().padding()
                }
            }
            .sheet(isPresented: $model.showsHistory) {
                RunHistoryView(broker: model.broker)
            }
            .alert("The seat could not do that", isPresented: Binding(
                get: { model.openError != nil }, set: { if !$0 { model.openError = nil } }
            )) {
                Button("OK", role: .cancel) {}
                Button("Request permissions") { model.requestPermissions() }
                if !model.capabilities.allReady {
                    Button("Open Privacy Settings") { model.openPermissionSettings() }
                }
            } message: {
                Text((model.openError ?? "") + "\n\n" + model.capabilityLines)
            }
            .alert("No model available", isPresented: $model.needsModel) {
                Button("Open Settings") { model.openSettings() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Mecum needs at least one usable model: sign in to Codex, add an Anthropic or Gemini API key, or run Ollama with a pulled model. Set it up in Settings.")
            }
    }

    /// What the seat is doing, as the kit answers it.
    ///
    /// It is a separate control from the permissions badge on purpose. That
    /// one used to be labelled "Seat ready" while reporting nothing but
    /// whether the grants were in place, so it went on saying ready while the
    /// seat was waiting for the person's focus with its gate shut. This one
    /// reads the kit, and it never speaks for permissions; that one never
    /// speaks for the seat.
    private var seatBadge: some View {
        Menu {
            Text(model.seatActivity.title)
            if let hold = model.inputHold { Text(hold) }
            // Its own line, never folded into the state above: a lost
            // picture is not a lost application.
            if let preview = model.previewSuspension { Text(preview) }
        } label: {
            Label(model.seatActivity.title, systemImage: model.seatActivity.symbol)
        }
    }

    /// Every permission and its state, and the two ways to fix one. Without
    /// this menu a fresh installation has no button to press at all.
    private var capabilityBadge: some View {
        let report = model.capabilities
        return Menu {
            ForEach(report.entries) { entry in
                Label("\(entry.name): \(entry.detail)", systemImage: entry.ready ? "checkmark.circle" : "xmark.circle")
            }
            Divider()
            Button("Request missing permissions") { model.requestPermissions() }
            Button("Relaunch Mecum") { model.relaunch() }
        } label: {
            Label(report.allReady ? "Permissions ready" : "Permissions missing",
                  systemImage: report.allReady ? "checkmark.shield" : "exclamationmark.triangle")
        }
    }
}
