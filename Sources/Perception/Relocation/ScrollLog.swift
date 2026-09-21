import Foundation

/// One gated logger for the whole scroll engine (`LOCATOR_DEBUG` → stderr, "[scroll]" prefix). Lets a
/// `flow-run --debug` explain WHY a step did or didn't scroll, and via WHICH driver (AX vs opaque) — the
/// difference between "the fix isn't working" and "this app never took the path the fix touches".
enum ScrollLog {
    static func d(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["LOCATOR_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("[scroll] \(message())\n".utf8))
    }
}
