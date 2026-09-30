import AppKit
import ApplicationServices
import AutomationRuntime
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import InteractionListener
import InteractionObservation

/// WatchCommand composes the listener with production perception without constructing EngineRuntime.
/// Its only output is the terminal stream. Signal and duration cancellation join listener teardown.
enum WatchCommand {
    // SIGUSR2 toggles it; while set, the raw loop holds its next event and reads no more.
    private static var consumerPaused = false

    static func run(arguments: [String]) async throws {
        let options = try WatchOptions(arguments: arguments)
        if options.help { print(WatchOptions.usage); return }
        let processID = try options.app.map { try ApplicationLookup.running($0).processIdentifier }
        if !options.raw, !CGPreflightScreenCaptureAccess() {
            throw AutomationFailure("watch needs Screen Recording for perception. Grant it to the launching terminal and relaunch, or use --raw to inspect input only.")
        }
        if !options.raw, !AXIsProcessTrusted() {
            stderr("Accessibility unavailable; pixel perception remains enabled and AX results will say permission_missing.")
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        let listener = try PassiveInteractionListener(hover: options.hover)
        let counters = { @MainActor in WatchRendering.counters(observed: listener.observedSequence, listener.queueCounters) }
        // SIGUSR1 and stop: the tap's latency lines.
        let latency = { (atStop: Bool) in
            listener.takeCallbackLatency { taken in
                FileHandle.standardError.write(Data((taken.lines(role: "inprocess", atStop: atStop) + "\n").utf8))
            }
        }
        let task = Task {
            if options.raw {
                for try await event in listener.events {
                    // ponytail: polls while paused, a diagnostic only; a continuation needs its own cancel path.
                    while consumerPaused { try await Task.sleep(for: .milliseconds(50)) }
                    try Task.checkCancellation()
                    if let processID, event.kind != .gap, event.processID != processID { continue }
                    print(options.json ? try WatchRendering.json(event) : WatchRendering.raw(event))
                }
            } else {
                let observer = InteractionObserver(
                    reader: InteractionSceneReader(pipeline: ProductionPerception.pipeline()),
                    processID: processID, intervalMilliseconds: options.intervalMilliseconds
                )
                try await observer.run(listener: listener, report: { report in
                    do { print(options.json ? try WatchRendering.json(report) : WatchRendering.text(report)) }
                    catch { stderr("output encoding failed: \(error)") }
                }, diagnostic: stderr)
            }
        }
        let duration = options.duration.map { seconds in
            Task {
                do { try await Task.sleep(for: .seconds(seconds)); task.cancel() }
                catch { return }
            }
        }
        let signals = [SIGINT, SIGTERM, SIGUSR1, SIGUSR2].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    switch number {
                    case SIGUSR1: latency(false)
                    case SIGUSR2: toggleConsumer(raw: options.raw)
                    default: task.cancel()
                    }
                }
            }
            source.resume()
            return source
        }
        // SIGUSR1 and SIGUSR2 stay ignored after the sources end, so a late one cannot kill the stop.
        defer {
            duration?.cancel()
            for source in signals { source.cancel() }
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }
        stderr("starting passive listener\(options.raw ? " (raw)" : " with perception"); Ctrl+C stops.")
        do { try await task.value }
        catch is CancellationError { }
        catch {
            await listener.stop()
            stderr(counters())
            latency(true)
            throw error
        }
        await listener.stop()
        stderr(counters())
        latency(true)
        stderr("stopped; event tap released.")
    }

    /// Measurement only: pauses the raw loop that reads `listener.events`, while the listener keeps running.
    private static func toggleConsumer(raw: Bool) {
        guard raw else { return stderr("SIGUSR2 pauses the --raw event loop only; ignored") }
        consumerPaused.toggle()
        stderr(consumerPaused ? "consumer paused" : "consumer resumed")
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data("watch: \(message)\n".utf8))
    }
}
