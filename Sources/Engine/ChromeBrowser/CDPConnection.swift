import BrowserCore
import Foundation

/// CDPConnection owns one browser-level socket, multiplexing target sessions and bounded requests.
/// Cancellation/timeout removes the waiter but never resends an uncertain command.
actor CDPConnection {
    private struct Pending {
        let continuation: CheckedContinuation<CDPValue, any Error>
        let timeout: Task<Void, Never>
        let sessionID: String?
        let method: String
    }
    private let socket: URLSessionWebSocketTask
    private let session: URLSession
    private var reader: Task<Void, Never>?
    private var pending: [Int: Pending] = [:]
    private var nextID = 0
    private var closed = false
    private var dialogs: [String: BrowserDialog] = [:]

    init(endpoint: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 0
        let session = URLSession(configuration: configuration, delegate: CDPRedirectPolicy(), delegateQueue: nil)
        self.session = session
        self.socket = session.webSocketTask(with: endpoint)
        self.socket.maximumMessageSize = 16 * 1024 * 1024
    }

    deinit {
        reader?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    func start() {
        guard reader == nil, !closed else { return }
        socket.resume()
        reader = Task { [weak self, socket] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    let data: Data
                    switch message {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: throw BrowserFailure(.transport, "Unknown Chrome WebSocket message.")
                    }
                    let value = try JSONDecoder().decode(CDPValue.self, from: data)
                    await self?.receive(value)
                }
            } catch {
                await self?.failAll(BrowserFailure(.transport, "Chrome disconnected: \(error). Reconnect explicitly and observe."))
            }
        }
    }

    func call(_ method: String, _ params: [String: CDPValue] = [:], sessionID: String? = nil,
              timeout: Duration = .seconds(15)) async throws -> CDPValue {
        try Task.checkCancellation()
        guard !closed else { throw BrowserFailure(.notConnected, "Chrome connection is closed. Connect again.") }
        nextID += 1
        let id = nextID
        var request: [String: CDPValue] = ["id": .number(Double(id)), "method": .string(method), "params": .object(params)]
        if let sessionID { request["sessionId"] = .string(sessionID) }
        let bytes = try JSONEncoder().encode(CDPValue.object(request))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.fail(id, BrowserFailure(.transport, "Chrome timed out during \(method). Observe before another action."))
                }
                pending[id] = Pending(continuation: continuation, timeout: timer, sessionID: sessionID, method: method)
                Task { [weak self, socket] in
                    do {
                        guard await self?.hasPending(id) == true else { return }
                        try await socket.send(.string(String(decoding: bytes, as: UTF8.self)))
                    }
                    catch { await self?.fail(id, BrowserFailure(.transport, "Chrome send failed: \(error)")) }
                }
            }
        } onCancel: {
            Task { await self.fail(id, CancellationError()) }
        }
    }

    func close() {
        failAll(BrowserFailure(.notConnected, "Chrome connection was released."))
    }

    func currentDialog(sessionID: String) -> BrowserDialog? { dialogs[sessionID] }

    private func receive(_ value: CDPValue) {
        if let numericID = value["id"].number, numericID >= 0, numericID < Double(Int.max) {
            let id = Int(numericID)
            guard let request = pending.removeValue(forKey: id) else { return }
            request.timeout.cancel()
            if let error = value["error"].object {
                request.continuation.resume(throwing: BrowserFailure(.protocolError,
                    error["message"]?.string ?? "Chrome rejected the request."))
            } else { request.continuation.resume(returning: value["result"]) }
            return
        }
        guard let sessionID = value["sessionId"].string else { return }
        switch value["method"].string {
        case "Page.javascriptDialogOpening":
            let params = value["params"]
            dialogs[sessionID] = BrowserDialog(type: params["type"].string ?? "unknown",
                message: String((params["message"].string ?? "").prefix(4096)),
                defaultPrompt: String((params["defaultPrompt"].string ?? "").prefix(1024)))
            // Chrome can withhold the command reply until a synchronous JavaScript dialog is answered.
            let blocked = pending.filter { $0.value.sessionID == sessionID && $0.value.method != "Page.handleJavaScriptDialog" }
            for id in blocked.keys {
                fail(id, BrowserFailure(.unavailable, "A JavaScript dialog opened. Use browser_dialog and browser_handle_dialog.", effectsPossible: true))
            }
        case "Page.javascriptDialogClosed", "Inspector.detached": dialogs.removeValue(forKey: sessionID)
        default: break
        }
    }

    private func hasPending(_ id: Int) -> Bool { pending[id] != nil && !closed }

    private func fail(_ id: Int, _ error: any Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: error)
    }

    private func failAll(_ error: any Error) {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        let waiting = pending
        pending.removeAll()
        dialogs.removeAll()
        for request in waiting.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
