import Foundation

/// Resume a continuation exactly once, whichever racer (the operation or the timeout) finishes first.
private final class ResumeOnce<U: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<U?, Never>
    init(_ c: CheckedContinuation<U?, Never>) { cont = c }
    func resume(_ value: U?) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { cont.resume(returning: value) }
    }
}

/// Run `op`, but give up after `seconds` and return nil — WITHOUT awaiting the (possibly hung) operation.
/// ScreenCaptureKit's one-shot (`SCShareableContent.current` / `SCScreenshotManager.captureImage`)
/// occasionally LEAKS its continuation and never resumes; a structured `withThrowingTaskGroup` would then
/// deadlock at scope exit awaiting that child, so we race via UNSTRUCTURED tasks + a resume-once box. The
/// leaked task lingers suspended (harmless for a short-lived CLI invocation) while the caller proceeds.
func raceTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
    await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
        let once = ResumeOnce<T>(c)
        Task { let r = await op(); once.resume(r) }
        Task { try? await Task.sleep(for: .seconds(seconds)); once.resume(nil) }
    }
}
