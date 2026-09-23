import ModelTransports
import SeatBroker
import SwiftUI

/// The app's one screen: the message log, a floating live monitor of the
/// adopted window in the bottom-right corner, and a composer bar with the
/// model controls. Return sends, Option-Return inserts a newline. Images sit
/// in fixed-height slots so resizing never reflows the log.
///
/// It is shown before any seat exists, so the monitor and the titles are
/// written for a session that is nil and for one holding nothing yet.
struct ChatView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(model.messages) { message in
                            MessageRow(message: message).id(message.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    // Room for the floating monitor so the last bubble is never under it.
                    .padding(.bottom, 200)
                }
                .onChange(of: model.messages.count) {
                    if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let session = model.session {
                    FloatingMonitor(session: session, isRunning: model.isBusy)
                        .padding(16)
                }
            }
            ComposerBar(model: model)
                // The composer carries the model picker, so its appearing is what asks for the checks.
                .task { model.settings.refresh() }
        }
        .navigationTitle(model.session?.app?.name ?? "Mecum")
        .navigationSubtitle(model.session?.target?.title ?? "")
    }
}

// MARK: - Floating monitor

/// The virtual screen as a picture-in-picture monitor. Two sizes and two
/// sources, both toggled by its header: the adopted window live, or the whole
/// Virtual Display it sits on.
///
/// The source is held here rather than read from the session on every pass
/// because the session is not observable; the session's answer is what is
/// stored, so a display that does not exist yet leaves the toggle off.
private struct FloatingMonitor: View {
    let session: AgentSession
    let isRunning: Bool
    @State private var expanded = false
    @State private var showsDisplay = false

    var body: some View {
        // The frame is empty until a window is adopted, and a zero ratio
        // collapses the preview, so an empty seat keeps the monitor's shape.
        let frame = session.windowFrame
        let ratio = frame.height > 0 && frame.width > 0 ? frame.width / frame.height : 16.0 / 10.0
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(isRunning ? .red : .green).frame(width: 7, height: 7)
                Text(isRunning ? "Agent acting" : "Live monitor")
                    .font(.caption.weight(.medium))
                Text("·").foregroundStyle(.tertiary)
                // The source, not the application: "Live monitor · Finder" is
                // a lie when the picture is the whole display.
                Text(showsDisplay ? "Virtual Display" : (session.app?.name ?? "nothing on the seat"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button {
                    showsDisplay = session.setPreviewShowsDisplay(!showsDisplay)
                } label: {
                    Image(systemName: showsDisplay ? "display" : "macwindow")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showsDisplay ? "Show the adopted window" : "Show the whole Virtual Display")
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            LivePreview(session: session)
                .aspectRatio(ratio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding([.horizontal, .bottom], 6)
        }
        .frame(width: expanded ? 560 : 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

// MARK: - Composer

/// Text field on top; under it, on the right, one capsule that names the
/// model and its effort and opens the model popover, then the send or stop
/// button. The capsule warms from grey to orange as the effort rises.
private struct ComposerBar: View {
    @Bindable var model: AppModel
    @State private var showsModelPopover = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            // Three places state the slash vocabulary and have to agree: this
            // placeholder, the help line in `AppModel.send`, and the parser.
            TextField("Say what you want done, or type /observe, /click N [count]…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...8)
                .focused($isFocused)
                .onSubmit { Task { await model.send() } }
                // Focus as soon as the chat appears, and again when a run ends,
                // so the next goal can be typed without a click.
                .task { isFocused = true }
                .onChange(of: model.isBusy) { _, busy in if !busy { isFocused = true } }
            HStack(spacing: 10) {
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                ModelCapsule(selection: model.selection) { showsModelPopover.toggle() }
                    .popover(isPresented: $showsModelPopover, arrowEdge: .bottom) {
                        ModelPopover(model: model)
                    }
                if model.isBusy {
                    Button { model.cancelRun() } label: {
                        Image(systemName: "stop.fill").font(.callout.weight(.bold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .tint(.red)
                } else {
                    Button { Task { await model.send() } } label: {
                        Image(systemName: "arrow.up").font(.callout.weight(.bold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || model.selection.model.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding([.horizontal, .bottom], 16)
        .padding(.top, 8)
    }
}

/// Grey at low, blue at medium, then amber, orange and red-orange: the
/// colour says how hard the model will think before the person reads it.
enum EffortTint {
    static func color(for effort: ReasoningEffort, provider: ModelProvider, model: String) -> Color {
        let supported = ModelSelection.supportedEfforts(provider: provider, model: model)
        let position = Double(supported.firstIndex(of: effort) ?? 0) / Double(max(1, supported.count - 1))
        return color(position: position)
    }

    static func color(position: Double) -> Color {
        // Blue (hue 0.60) down to orange (hue 0.07); saturation grows with effort.
        let hue = 0.60 - 0.53 * position
        return Color(hue: hue, saturation: 0.55 + 0.4 * position, brightness: 0.95)
    }
}

private struct ModelCapsule: View {
    let selection: ModelSelection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(selection.model.isEmpty ? "Choose a model" : selection.model)
                    .lineLimit(1)
                // Sized by the widest level this model has, so changing the
                // effort never resizes the capsule or moves the popover.
                ZStack {
                    ForEach(ModelSelection.supportedEfforts(provider: selection.provider, model: selection.model)) {
                        Text($0.title(for: selection.provider)).fontWeight(.semibold).hidden()
                    }
                    // A model with no effort parameter shows no level at all.
                    if !ModelSelection.supportedEfforts(provider: selection.provider, model: selection.model).isEmpty {
                        Text(selection.effort.title(for: selection.provider)).fontWeight(.semibold)
                    }
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(EffortTint.color(for: selection.effort, provider: selection.provider, model: selection.model))
        .help("Model and effort")
    }
}

/// Provider, model and a stepped effort slider.
private struct ModelPopover: View {
    @Bindable var model: AppModel

    private var efforts: [ReasoningEffort] {
        ModelSelection.supportedEfforts(provider: model.selection.provider, model: model.selection.model)
    }

    private var effortIndex: Binding<Double> {
        Binding(
            get: { Double(efforts.firstIndex(of: model.selection.effort) ?? 0) },
            set: { model.selection.effort = efforts[min(efforts.count - 1, max(0, Int($0.rounded())))] }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Provider", selection: $model.selection.provider) {
                ForEach(model.settings.availableProviders) { Text($0.title).tag($0) }
                if !model.settings.isAvailable(model.selection.provider) {
                    Text(model.selection.provider.title).tag(model.selection.provider)
                }
            }
            .onChange(of: model.selection.provider) { _, provider in
                let models = model.settings.models(for: provider)
                if !models.contains(model.selection.model) { model.selection.model = models.first ?? "" }
                clampEffort()
            }
            let models = model.settings.models(for: model.selection.provider)
            if models.isEmpty {
                SettingsLink { Label("Add models in Settings", systemImage: "gearshape") }
            } else {
                Picker("Model", selection: $model.selection.model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                    if !models.contains(model.selection.model) {
                        Text(model.selection.model).tag(model.selection.model)
                    }
                }
                .onChange(of: model.selection.model) { clampEffort() }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Effort")
                    Spacer()
                    Text(model.selection.effort.title(for: model.selection.provider))
                        .fontWeight(.semibold)
                        .foregroundStyle(EffortTint.color(for: model.selection.effort, provider: model.selection.provider, model: model.selection.model))
                }
                Slider(value: effortIndex, in: 0...Double(max(1, efforts.count - 1)), step: 1)
                    .tint(EffortTint.color(for: model.selection.effort, provider: model.selection.provider, model: model.selection.model))
                    .disabled(efforts.count < 2)
                HStack {
                    ForEach(efforts) { effort in
                        Text(effort.title(for: model.selection.provider))
                            .font(.caption2)
                            .foregroundStyle(effort == model.selection.effort ? .primary : .secondary)
                        if effort != efforts.last { Spacer() }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func clampEffort() {
        let supported = efforts
        guard !supported.isEmpty, !supported.contains(model.selection.effort) else { return }
        // Medium when the provider has it; otherwise the highest level, which
        // for Ollama means thinking on.
        model.selection.effort = supported.contains(.medium) ? .medium : (supported.last ?? .low)
    }
}

// MARK: - Bubbles

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 120)
                UserBubble(text: message.text)
            } else {
                SystemBubble(message: message)
                Spacer(minLength: 60)
            }
        }
    }
}

private struct UserBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: 520, alignment: .trailing)
    }
}

/// Runtime output. Plain text, an observation (image plus collapsible scene
/// text), a single action report (before and after), or a planner run.
private struct SystemBubble: View {
    let message: ChatMessage
    private let imageHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if message.runStatus != nil {
                runHeader
            } else if let observation = message.observation {
                SceneImageView(observation: observation).frame(height: imageHeight)
                if let timing = observation.timing {
                    Text("Perceived in \(timing.summary)").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Scene text · \(observation.elements.count) elements") {
                    Text(message.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
                .font(.caption.weight(.medium))
            } else if !message.text.isEmpty {
                Text(message.text)
                    .font(message.text.contains("\n") ? .system(.callout, design: .monospaced) : .body)
                    .textSelection(.enabled)
            }

            if let report = message.report {
                HStack(spacing: 8) {
                    labeled("Before") { SceneImageView(observation: report.before) }
                    // No after-frame is a reading that could not be taken, not
                    // a blank one: the line beside it says what is known.
                    if let after = report.after {
                        labeled("After") { SceneImageView(observation: after) }
                    } else {
                        labeled("After") { Text("not perceived").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .frame(height: imageHeight + 18)
                footer("\(report.eventCount) input event\(report.eventCount == 1 ? "" : "s") · \(report.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))")
            }

            if message.runStatus != nil {
                if message.isRunning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Watch the live monitor while the agent works.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(height: 32)
                } else if let final = message.finalObservation {
                    labeled("Last frame the agent saw") { SceneImageView(observation: final) }
                        .frame(height: imageHeight + 18)
                }
                if !message.reports.isEmpty { reportList }
                if !message.text.isEmpty {
                    Text(message.text).font(.callout.weight(.medium)).textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var runHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: message.isRunning ? "brain.head.profile" : "checkmark.seal.fill")
                .foregroundStyle(message.isRunning ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
            Text(message.runStatus ?? "")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var reportList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Verified actions").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(message.reports.enumerated()), id: \.element.id) { index, report in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Green is the verified effect and nothing else: a scene
                    // that merely changed used to get the same tick.
                    Image(systemName: report.verification.outcome.symbol)
                        .foregroundStyle(report.verification.outcome.isVerified ? .green : .orange)
                    Text("\(index + 1). \(report.action.verb) \(report.action.targetDescription) \(report.targetLabel)")
                        .font(.caption.weight(.medium))
                    Text(report.verification.summary)
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Under the line rather than beside it: a note is a sentence,
                // and a refused menu names every title it was offered instead.
                if let note = report.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func footer(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
