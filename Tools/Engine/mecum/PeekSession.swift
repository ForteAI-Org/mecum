import AppKit
import Darwin
import EngineCore
import Foundation
import PerceptionCore
import SceneOverlay

/// PeekSession owns one observation at a time. Input invalidates its generation, and a scene is
/// displayed only while the front app and window census still match the pre-capture target.
/// Cancellation hides the panels immediately and waits for the outstanding observation to finish.
final class PeekSession {
    private let scenes: any SceneProviding
    private let options: PeekOptions
    private let overlay = SceneOverlay()
    private var observation: Task<Void, Never>?
    private var refresh: PeekRefreshSchedule
    private var stopped = false
    private var lastMessage: String?

    init(scenes: any SceneProviding, options: PeekOptions) {
        self.scenes = scenes
        self.options = options
        refresh = PeekRefreshSchedule(interval: .milliseconds(options.intervalMilliseconds), now: .now)
    }

    func run() async throws {
        let end = options.durationSeconds.map { ContinuousClock.now.advanced(by: .seconds($0)) }
        var target: PeekTarget?
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown,
            .otherMouseDown, .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown]) { [weak self] _ in
            Task { @MainActor in self?.invalidate() }
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            overlay.close()
        }
        do {
            while !Task.isCancelled, end.map({ ContinuousClock.now < $0 }) ?? true {
                let current = PeekTargetReader.current(excluding: getpid())
                if current != target {
                    invalidate()
                    target = current
                }
                if let current, !current.visibleRegions.isEmpty, observation == nil,
                   ContinuousClock.now >= refresh.nextObservation {
                    observe(current)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch is CancellationError {
            // Both a terminal interrupt and parent cancellation use the same cleanup below.
        }
        stopped = true
        refresh.invalidate(at: .now)
        overlay.close()
        observation?.cancel()
        await observation?.value
        observation = nil
    }

    private func invalidate() {
        refresh.invalidate(at: .now)
        observation?.cancel()
        overlay.clear()
    }

    private func observe(_ target: PeekTarget) {
        let ticket = refresh.ticket(at: .now)
        observation = Task { [self] in
            var drawn = false
            defer {
                refresh.complete(ticket, at: .now)
                observation = nil
                if options.timings {
                    let elapsed = ticket.started.duration(to: .now).components
                    let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                    FileHandle.standardError.write(Data("peek timing: observation=\(Int(ms.rounded()))ms drawn=\(drawn)\n".utf8))
                }
            }
            do {
                let perceived = try await scenes.currentScene(of: target.processID)
                guard !stopped, !Task.isCancelled, refresh.isCurrent(ticket),
                      PeekTargetReader.current(excluding: getpid()) == target,
                      perceived.frame == target.frame else { return }
                overlay.show(perceived.scene, frame: perceived.frame, visibleRegions: target.visibleRegions,
                             sectionsOnly: options.sectionsOnly, labels: options.labels)
                drawn = true
                report("\(perceived.scene.appName): \(perceived.scene.elements.count) elements, "
                    + "\(perceived.scene.sections.count) sections")
            } catch {
                if !stopped, !Task.isCancelled, refresh.isCurrent(ticket) {
                    overlay.clear()
                    report("cannot read the current window: \(error)")
                }
            }
        }
    }

    private func report(_ message: String) {
        guard message != lastMessage else { return }
        lastMessage = message
        FileHandle.standardError.write(Data("peek: \(message)\n".utf8))
    }
}
