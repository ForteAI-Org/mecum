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
        let task = Task {
            if options.raw {
                for try await event in listener.events {
                    try Task.checkCancellation()
                    if let processID, event.processID != processID { continue }
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
        let signals = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { task.cancel() }
            source.resume()
            return source
        }
        defer {
            duration?.cancel()
            for source in signals { source.cancel() }
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }
        stderr("starting passive listener\(options.raw ? " (raw)" : " with perception"); Ctrl+C stops.")
        do { try await task.value }
        catch is CancellationError { }
        catch { await listener.stop(); throw error }
        await listener.stop()
        stderr("stopped; event tap released.")
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data("watch: \(message)\n".utf8))
    }
}
