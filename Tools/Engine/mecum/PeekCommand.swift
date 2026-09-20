import AppKit
import ApplicationServices
import AutomationRuntime
import CoreGraphics
import Darwin
import Dispatch
import Foundation

/// PeekCommand runs read-only inspection until Ctrl+C, SIGTERM, or the requested duration elapses.
enum PeekCommand {
    static func run(arguments: [String]) async throws {
        let options = try PeekOptions(arguments: arguments)
        if options.help { print(PeekOptions.usage); return }
        guard CGPreflightScreenCaptureAccess() else {
            throw AutomationFailure("peek needs Screen Recording permission for the launching terminal. Grant it in System Settings and relaunch the terminal.")
        }
        if !AXIsProcessTrusted() {
            FileHandle.standardError.write(Data("peek: Accessibility is unavailable; showing pixel observations only.\n".utf8))
        }
        // An accessory may show nonactivating panels; prohibited applications cannot reliably show UI.
        NSApplication.shared.setActivationPolicy(.accessory)
        defer { NSApplication.shared.setActivationPolicy(.prohibited) }
        let session = PeekSession(scenes: ProductionPerception.foregroundScenes(excludingProcesses: [getpid()]),
                                  options: options)
        let task = Task { try await session.run() }
        let sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { task.cancel() }
            source.resume()
            return source
        }
        defer {
            for source in sources { source.cancel() }
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }
        FileHandle.standardError.write(Data("peek: following the frontmost app; cyan native, orange text, green icons, purple images, yellow uncertain overlays, pink sections. Ctrl+C stops.\n".utf8))
        try await task.value
    }
}
