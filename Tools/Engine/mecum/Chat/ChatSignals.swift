import Darwin
import Foundation

/// ChatSignals translates SIGINT/SIGTERM into one asynchronous shutdown owned by the terminal composition.
final class ChatSignals {
    private var sources: [any DispatchSourceSignal] = []
    private var fired = false
    private let stopAction: () -> Void

    init(onStop: @escaping () -> Void) {
        stopAction = onStop
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    guard let self, !self.fired else { return }
                    self.fired = true
                    self.stopAction()
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        sources.removeAll()
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
