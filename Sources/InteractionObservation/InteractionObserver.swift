import AppKit
import CoreGraphics
import Foundation
import InteractionListener
import PerceptionCore

/// InteractionObserver joins passive input and production perception without persistence.
/// Ambient and event reads share one acquisition. Events wait for a valid post-input sample;
/// hovers consume the existing cache without requesting additional screenshots. Eight scenes are kept.
/// Labels seen after input never replace missing before-input evidence.
@MainActor
public final class InteractionObserver {
    private let reader: InteractionSceneReader
    private let processID: Int32?
    private let interval: Duration
    private let captures = InteractionCaptureCoordinator()
    private var samples: [Int: InteractionSample] = [:]

    public init(reader: InteractionSceneReader, processID: Int32? = nil, intervalMilliseconds: Int = 500) {
        self.reader = reader
        self.processID = processID
        interval = .milliseconds(max(100, intervalMilliseconds))
    }

    /// Consumes until cancellation or source failure, joining pending reads before returning.
    /// Diagnostics describe capture failures and readiness; the caller owns and stops the listener.
    public func run(
        listener: PassiveInteractionListener,
        report: @escaping @MainActor (InteractionReport) -> Void,
        diagnostic: @escaping @MainActor (String) -> Void
    ) async throws {
        let refresh = Task { [self] in
            var lastDiagnostic: String?
            while !Task.isCancelled {
                if let window = listener.windowUnderPointer(), accepts(window.processID) {
                    do {
                        if let sample = try await read(window, listener: listener, priority: .ambient,
                                                       revision: listener.revision) {
                            remember(sample)
                            let count = sample.scene.elements.count
                            let coverage = count == 0 ? "no perceived elements" : "\(count) elements"
                            let message = "ready: window #\(window.number) \"\(window.title ?? "")\", \(coverage)"
                            if message != lastDiagnostic { diagnostic(message); lastDiagnostic = message }
                        }
                    } catch is CancellationError { break }
                    catch {
                        let message = "perception unavailable: \(error)"
                        if message != lastDiagnostic { diagnostic(message); lastDiagnostic = message }
                    }
                }
                do { try await Task.sleep(for: interval) } catch { break }
            }
        }
        do {
            for try await event in listener.events {
                try Task.checkCancellation()
                // A gap belongs to no app: filtering it out would hide lost input from the report.
                guard event.kind == .gap || accepts(event.processID) else { continue }
                let app = NSRunningApplication(processIdentifier: event.processID)
                let beforeSample = event.window.flatMap { samples[$0.number] }
                let before = InteractionResolution.resolve(event: event, sample: beforeSample)
                var afterElement: SceneElement?
                var observation: InteractionDifference?
                var afterStatus = event.kind == .focus || event.kind == .gap ? "not_applicable" : "intervening_input"
                var accessibility: AccessibilityPointResult?
                if event.kind == .hover {
                    afterStatus = "not_requested_for_hover"
                } else if event.kind != .focus, event.kind != .gap, let window = event.window,
                          listener.revision == event.revision {
                    let native = InteractionSceneReader.accessibility(at: event.point, processID: event.processID)
                    accessibility = listener.revision == event.revision ? native
                        : AccessibilityPointResult(status: "input_during_AX_read")
                    do {
                        if let sample = try await read(window, listener: listener, priority: .event,
                                                       revision: event.revision) {
                            remember(sample)
                            let point = CGPoint(x: (event.point.x - sample.window.frame.minX) / sample.window.frame.width,
                                                y: (event.point.y - sample.window.frame.minY) / sample.window.frame.height)
                            afterElement = InteractionResolution.at(point: point, in: sample.scene).element
                            afterStatus = "read_after_event"
                            if before.status == "resolved", let beforeSample,
                               InteractionDifference.needsConfirmation(before: beforeSample, after: sample) {
                                if let confirmed = try await read(sample.window, listener: listener, priority: .event,
                                                                  revision: event.revision) {
                                    remember(confirmed)
                                    observation = InteractionDifference.compare(
                                        before: beforeSample, after: sample, confirmation: confirmed
                                    )
                                } else {
                                    afterStatus = "read_after_event; change_unconfirmed"
                                }
                            }
                        } else {
                            afterStatus = listener.revision == event.revision
                                ? "window_changed_or_closed" : "input_during_observation"
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { afterStatus = "capture_failed: \(error)" }
                }
                report(InteractionReport(
                    event: event, app: app?.localizedName ?? "pid \(event.processID)", bundleID: app?.bundleIdentifier,
                    before: before, afterElement: afterElement, afterStatus: afterStatus,
                    accessibility: accessibility, observation: observation
                ))
            }
        } catch {
            refresh.cancel()
            await refresh.value
            throw error
        }
        refresh.cancel()
        await refresh.value
    }

    private func accepts(_ pid: Int32) -> Bool { pid != getpid() && (processID == nil || pid == processID) }

    private func read(
        _ window: InteractionWindow,
        listener: PassiveInteractionListener,
        priority: InteractionCaptureCoordinator.Priority,
        revision: UInt64
    ) async throws -> InteractionSample? {
        guard let current = InteractionWindowReader.windows(excluding: getpid()).first(where: {
            InteractionDifference.sameSurface(window, $0)
        }), let app = NSRunningApplication(processIdentifier: current.processID),
           let bundle = app.bundleIdentifier else { return nil }
        return try await captures.read(window: current, revision: revision, priority: priority, isCurrent: {
            listener.revision == revision && InteractionWindowReader.windows(excluding: getpid()).contains(current)
        }, load: { [reader] in
            try await reader.scene(window: current, bundleID: bundle, appName: app.localizedName ?? bundle)
        })
    }

    private func remember(_ sample: InteractionSample) {
        if let existing = samples[sample.window.number], existing.completedAt > sample.completedAt { return }
        samples[sample.window.number] = sample
        if samples.count > 8, let oldest = samples.values.min(by: { $0.completedAt < $1.completedAt }) {
            samples.removeValue(forKey: oldest.window.number)
        }
    }
}
