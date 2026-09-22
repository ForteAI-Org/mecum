import ModelTransports
import SeatBroker
import AppKit
import SwiftUI

/// Every recorded run, newest first. Left: searchable list with outcome,
/// goal, target and when. Right: the run as evidence — outcome, model, budget
/// tiles, the verified step timeline and the last frame the agent saw.
struct RunHistoryView: View {
    
    let broker: SeatBroker
    
    @Environment(\.dismiss) private var dismiss
    @State private var records: [RunRecord] = []
    @State private var selected: RunRecord.ID?
    @State private var query = ""

    private var filtered: [RunRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return records }
        return records.filter {
            $0.goal.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q)
                || $0.model.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selected) { record in
                RunListRow(record: record).tag(record.id)
            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "Goal, app or model")
            .navigationSplitViewColumnWidth(min: 280, ideal: 320)
            .overlay {
                if records.isEmpty {
                    ContentUnavailableView("No runs yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("Every goal you send is recorded here with its verified steps."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        } detail: {
            if let record = filtered.first(where: { $0.id == selected }) ?? records.first(where: { $0.id == selected }) {
                RunDetail(record: record, frameURL: broker.finalFrameURL(for: record))
                    .id(record.id)
            } else {
                ContentUnavailableView("Select a run", systemImage: "list.bullet.rectangle")
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            ToolbarItem {
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([broker.configuration.recordingDirectory])
                }
                .help("Open the folder with runs.jsonl and the frames")
            }
        }
        .onAppear {
            records = broker.runHistory()
            selected = records.first?.id
        }
    }
}

// MARK: - Outcome styling

private extension RunRecord.Outcome {
    var icon: String {
        switch self {
        case .completed: "checkmark.seal.fill"
        case .blocked: "hand.raised.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .completed: .green
        case .blocked: .orange
        case .failed: .red
        case .cancelled: .gray
        }
    }

    var title: String { rawValue.capitalized }
}

private struct OutcomeBadge: View {
    let outcome: RunRecord.Outcome

    var body: some View {
        Label(outcome.title, systemImage: outcome.icon)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(outcome.color.opacity(0.18), in: Capsule())
            .foregroundStyle(outcome.color)
    }
}

// MARK: - List row

private struct RunListRow: View {
    let record: RunRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.outcome.icon)
                .foregroundStyle(record.outcome.color)
                .font(.title3)
                .frame(width: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.goal).lineLimit(2).font(.body.weight(.medium))
                HStack(spacing: 4) {
                    Text(record.app)
                    Text("·").foregroundStyle(.tertiary)
                    Text(record.model).lineLimit(1)
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(record.startedAt.formatted(.relative(presentation: .named)))
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(record.steps.count) step\(record.steps.count == 1 ? "" : "s")")
                    Text("·").foregroundStyle(.tertiary)
                    Text(record.duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                    if let output = record.outputTokens {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\((record.inputTokens ?? 0) + output) tok")
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

private struct RunDetail: View {
    let record: RunRecord
    let frameURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                tiles
                if !record.steps.isEmpty { timeline }
                if let frameURL, let image = NSImage(contentsOf: frameURL) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Last frame the agent saw").font(.headline)
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .toolbar {
            ToolbarItem {
                Button("Copy summary", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.goal).font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer()
                OutcomeBadge(outcome: record.outcome)
            }
            if !record.reason.isEmpty {
                Text(record.reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                chip(record.app + (record.windowTitle.isEmpty ? "" : " · " + record.windowTitle), systemImage: "macwindow")
                chip("\(record.model) · \(record.effort.title(for: record.provider))", systemImage: "sparkles",
                     tint: EffortTint.color(for: record.effort, provider: record.provider, model: record.model))
                chip(record.startedAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
            }
        }
    }

    private var tiles: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                tile("Decisions", "\(record.decisions)")
                tile("Actions", "\(record.steps.count)")
                tile("Verified", "\(record.verifiedSteps)",
                     tint: record.steps.isEmpty ? nil : (record.verifiedSteps == record.steps.count ? .green : .orange))
                tile("Duration", record.duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
            }
            HStack(spacing: 12) {
                tile("Input tokens", record.inputTokens.map { $0.formatted() } ?? "—")
                tile("Output tokens", record.outputTokens.map { $0.formatted() } ?? "—")
                tile("Model time", record.modelSeconds.map { String(format: "%.1fs", $0) } ?? "—")
                tile("Tokens/s", tokensPerSecond)
            }
        }
    }

    /// Output tokens over model time; "—" when either is unknown (the CLIs report no tokens).
    private var tokensPerSecond: String {
        guard let output = record.outputTokens, let seconds = record.modelSeconds, seconds > 0 else { return "—" }
        return "\(Int((Double(output) / seconds).rounded()))"
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Steps").font(.headline)
            VStack(spacing: 0) {
                ForEach(record.steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 0) {
                            // The outcome and not the scene diff: a record
                            // that ticked every repaint read a dud as done.
                            Image(systemName: step.outcome?.symbol ?? "minus.circle")
                                .foregroundStyle(step.outcome?.isVerified == true ? .green : .orange)
                            if step.id != record.steps.last?.id {
                                Rectangle().fill(.quaternary).frame(width: 1).frame(maxHeight: .infinity)
                            }
                        }
                        .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("\(step.index).").foregroundStyle(.secondary)
                                Text(step.verb).fontWeight(.semibold)
                                Text(step.element == 0 ? "" : "[\(step.element)]").foregroundStyle(.secondary)
                                Text(step.targetLabel).lineLimit(1)
                            }
                            .font(.callout)
                            Text(detail(step)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private func chip(_ text: String, systemImage: String, tint: Color? = nil) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((tint ?? .secondary).opacity(0.15), in: Capsule())
            .foregroundStyle(tint ?? .secondary)
    }

    private func tile(_ title: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(tint ?? .primary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func detail(_ step: RunStepRecord) -> String {
        var parts = [step.outcome?.sentence ?? (step.sceneChanged ? "scene changed" : "scene unchanged")]
        if step.count > 1 { parts.append("x\(step.count)") }
        if let effect = step.effect { parts.append(effect) }
        if let pixels = step.pixelDifference { parts.append(String(format: "pixels %.1f%%", pixels * 100)) }
        parts.append("\(step.eventCount) event\(step.eventCount == 1 ? "" : "s")")
        parts.append("\(step.milliseconds) ms")
        return parts.joined(separator: " · ")
    }

    private var summary: String {
        var lines = [
            "Goal: \(record.goal)",
            "Outcome: \(record.outcome.title) — \(record.reason)",
            "Target: \(record.app) · \(record.windowTitle)",
            "Model: \(record.provider.title) · \(record.model) · \(record.effort.title(for: record.provider))",
            "Decisions \(record.decisions) · actions \(record.steps.count) · verified \(record.verifiedSteps) · \(record.duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))",
            "Tokens in \(record.inputTokens.map(String.init) ?? "—") · out \(record.outputTokens.map(String.init) ?? "—") · model time \(record.modelSeconds.map { String(format: "%.1fs", $0) } ?? "—")",
        ]
        for step in record.steps {
            lines.append("\(step.index). \(step.verb) \(step.element == 0 ? "" : "[\(step.element)] ")\(step.targetLabel) — \(detail(step))")
        }
        return lines.joined(separator: "\n")
    }
}
