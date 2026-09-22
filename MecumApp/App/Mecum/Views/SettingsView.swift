import ModelTransports
import SeatBroker
import AppKit
import SwiftUI

/// One tab per provider: access (sign-in state or API key), the model list
/// the composer's picker shows, and Ollama's knobs. The + button proposes the
/// models the provider itself reports.
struct SettingsView: View {
    @Bindable var store: ModelSettingsStore

    var body: some View {
        TabView {
            ForEach(ModelProvider.allCases) { provider in
                ProviderTab(store: store, provider: provider)
                    .tabItem { Label(provider.title, systemImage: icon(provider)) }
            }
        }
        .frame(width: 560, height: 520)
        .padding()
    }

    private func icon(_ provider: ModelProvider) -> String {
        switch provider {
        case .codex, .claudeCode: "terminal"
        case .anthropic, .gemini: "key"
        case .ollama: "desktopcomputer"
        }
    }
}

private struct ProviderTab: View {
    @Bindable var store: ModelSettingsStore
    let provider: ModelProvider

    var body: some View {
        Form {
            Section {
                StatusRow(store: store, provider: provider)
                Text(provider.accessHint).font(.callout).foregroundStyle(.secondary)
                switch provider {
                case .anthropic:
                    KeyField(title: "Anthropic API key", text: $store.anthropicAPIKey, consoleURL: provider.consoleURL)
                case .gemini:
                    KeyField(title: "Gemini API key", text: $store.geminiAPIKey, consoleURL: provider.consoleURL)
                case .ollama:
                    TextField("Server", text: $store.ollamaHost, prompt: Text("http://127.0.0.1:11434"))
                case .codex, .claudeCode:
                    Button("Re-check sign-in") { store.scheduleAvailabilityRefresh() }
                }
            } header: {
                Text("Access")
            }

            ModelListSection(store: store, provider: provider)

            if provider == .ollama {
                Section {
                    LabeledContent("Temperature") {
                        Slider(value: $store.ollamaTemperature, in: 0...1.5, step: 0.05)
                        Text(store.ollamaTemperature.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 40)
                    }
                    LabeledContent("Top P") {
                        Slider(value: $store.ollamaTopP, in: 0.1...1, step: 0.05)
                        Text(store.ollamaTopP.formatted(.number.precision(.fractionLength(2)))).monospacedDigit().frame(width: 40)
                    }
                    LabeledContent("Top K") {
                        TextField("", value: $store.ollamaTopK, format: .number).frame(width: 90)
                    }
                    LabeledContent("Presence penalty") {
                        Slider(value: $store.ollamaPresencePenalty, in: 0...2, step: 0.1)
                        Text(store.ollamaPresencePenalty.formatted(.number.precision(.fractionLength(1)))).monospacedDigit().frame(width: 40)
                    }
                    LabeledContent("Context tokens") {
                        TextField("", value: $store.ollamaContextTokens, format: .number).frame(width: 90)
                    }
                    LabeledContent("Max output tokens") {
                        TextField("", value: $store.ollamaMaxOutputTokens, format: .number).frame(width: 90)
                    }
                    LabeledContent("Request timeout (s)") {
                        TextField("", value: $store.ollamaTimeoutSeconds, format: .number).frame(width: 90)
                    }
                    Text("Thinking tokens count against the output budget: keep it at 8k or more with thinking on. Thinking follows the effort in the chat: “No thinking” runs with it off, “Thinking” with it on.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    HStack {
                        Text("Generation")
                        Spacer()
                        Menu("Qwen recommended") {
                            Button("For thinking (0.6 · 0.95 · 20 · 0 · 8k out)") { store.applyQwenRecommendation(thinking: true) }
                            Button("For no thinking (0.7 · 0.8 · 20 · 1.5 · 2k out)") { store.applyQwenRecommendation(thinking: false) }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Ready / reason line with a coloured dot.
private struct StatusRow: View {
    let store: ModelSettingsStore
    let provider: ModelProvider

    var body: some View {
        let available = store.isAvailable(provider)
        let checking = store.unavailability[provider] == nil
        HStack(spacing: 8) {
            if checking {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(available ? .green : .orange).frame(width: 9, height: 9)
            }
            Text(store.statusText(provider))
                .font(.callout.weight(.medium))
            Spacer()
        }
    }
}

/// A secure key field with a reveal toggle, a link to where keys are made,
/// and a clear statement of what happens to the key.
private struct KeyField: View {
    let title: String
    @Binding var text: String
    let consoleURL: URL?
    @State private var reveals = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if reveals {
                        TextField(title, text: $text, prompt: Text("Paste your key here"))
                    } else {
                        SecureField(title, text: $text, prompt: Text("Paste your key here"))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                Button(reveals ? "Hide" : "Show") { reveals.toggle() }
                    .controlSize(.small)
                if !text.isEmpty {
                    Button("Clear", role: .destructive) { text = "" }.controlSize(.small)
                }
            }
            HStack(spacing: 12) {
                Label(text.isEmpty ? "No key stored" : "Key stored in your keychain",
                      systemImage: text.isEmpty ? "key.slash" : "checkmark.shield")
                    .font(.caption).foregroundStyle(text.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                if let consoleURL {
                    Link("Get a key…", destination: consoleURL).font(.caption)
                }
            }
        }
    }
}

/// The favorite models as a list: trash per row, + proposes what the
/// provider reports or takes a custom name.
private struct ModelListSection: View {
    @Bindable var store: ModelSettingsStore
    let provider: ModelProvider
    @State private var discovered: [String] = []
    @State private var discoveryError: String?
    @State private var isDiscovering = false
    @State private var customName = ""
    @State private var showsCustomField = false

    var body: some View {
        Section {
            let models = store.models(for: provider)
            if models.isEmpty {
                Text("No models yet. Use + to add the ones you want in the picker.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(models, id: \.self) { model in
                HStack {
                    Text(model).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button {
                        store.remove(model, from: provider)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove from the picker")
                }
            }
            if showsCustomField {
                HStack {
                    TextField("Model name", text: $customName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(addCustom)
                    Button("Add", action: addCustom).disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { showsCustomField = false; customName = "" }
                }
            }
            if let discoveryError {
                Text(discoveryError).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text("Models in the picker")
                Spacer()
                Menu {
                    let missing = discovered.filter { !store.models(for: provider).contains($0) }
                    if isDiscovering {
                        Text("Loading…")
                    } else if missing.isEmpty {
                        Text(discovered.isEmpty ? "Nothing found yet" : (canDiscover ? "All found models are listed" : "All known models are listed"))
                    } else {
                        Section(canDiscover ? "Reported by \(provider.title)" : "Known models") {
                            ForEach(missing, id: \.self) { model in
                                Button(model) { store.add(model, to: provider) }
                            }
                        }
                    }
                    Divider()
                    // The CLIs expose no model listing; their list is the known set.
                    if canDiscover {
                        Button("Refresh from \(provider.title)…") { Task { await discover() } }
                    }
                    Button("Add custom name…") { showsCustomField = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a model")
            }
        }
        .task(id: discoveryKey) { await discover() }
    }

    /// Codex and Claude Code have no model-listing command.
    private var canDiscover: Bool { provider != .codex && provider != .claudeCode }

    /// Re-discovers when the key or the server changes.
    private var discoveryKey: String {
        switch provider {
        case .anthropic: store.anthropicAPIKey
        case .gemini: store.geminiAPIKey
        case .ollama: store.ollamaHost
        case .codex, .claudeCode: "cli"
        }
    }

    private func discover() async {
        isDiscovering = true
        defer { isDiscovering = false }
        do {
            discovered = try await store.discoverModels(for: provider)
            discoveryError = nil
        } catch {
            discovered = []
            discoveryError = error.localizedDescription
        }
    }

    private func addCustom() {
        store.add(customName, to: provider)
        customName = ""
        showsCustomField = false
    }
}
