import Foundation

public enum ProviderError: LocalizedError {
    case missingAPIKey(ModelProvider)
    case http(status: Int, message: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let p): "No API key for \(p.title). Add one in Settings."
        case .http(let status, let message): "HTTP \(status): \(message)"
        case .badResponse(let detail): "Unexpected answer from the model: \(detail)"
        }
    }
}

/// One JSON POST for the HTTP providers, and one streamed POST for the same
/// providers' event streams. Nothing clever: URLSession, a timeout, and the
/// provider's own error message on a non-2xx status.
enum HTTPTransport {
    static func postJSON(_ url: URL, headers: [String: String], body: [String: Any],
                         timeout: TimeInterval) async throws -> (json: [String: Any], elapsed: Duration) {
        let started = ContinuousClock.now
        let (data, response) = try await URLSession.shared.data(for: request(url, headers: headers, body: body,
                                                                            timeout: timeout))
        let elapsed = started.duration(to: .now)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw failure(status: status, body: data) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.badResponse("not a JSON object")
        }
        return (json, elapsed)
    }

    static func getJSON(_ url: URL, timeout: TimeInterval = 10) async throws -> [String: Any] {
        try await getJSON(URLRequest(url: url, timeoutInterval: timeout))
    }

    static func getJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ProviderError.http(status: status, message: String(decoding: data.prefix(400), as: UTF8.self))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.badResponse("not a JSON object")
        }
        return json
    }

    /// One streamed turn: the provider's deltas and tool calls as they arrive,
    /// then, for a whole turn, the provider's record of it when it keeps one
    /// and the terminal element the assembler only gives once the provider
    /// has declared the turn finished.
    ///
    /// The request is built by the caller, so the body's JSON is serialized
    /// before anything is sent and a malformed one fails at the call rather
    /// than inside the stream. The request is cancelled when the stream is
    /// terminated. A non-2xx status fails before any delta, carrying the
    /// provider's own message.
    static func stream(_ request: URLRequest,
                       assembler: TurnAssembler) -> AsyncThrowingStream<TurnEvent, any Error> {
        stream({ request }, assembler: assembler)
    }

    /// The same turn over a request built when the stream starts, for a
    /// provider that must be asked something first. A failure building it
    /// ends the stream before any delta.
    static func stream(_ request: @escaping @Sendable () async throws -> URLRequest,
                       assembler: TurnAssembler) -> AsyncThrowingStream<TurnEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var assembler = assembler
                do {
                    let started = ContinuousClock.now
                    let (bytes, response) = try await URLSession.shared.bytes(for: try await request())
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        throw failure(status: status, body: await head(of: bytes))
                    }
                    for try await byte in bytes {
                        if let text = try assembler.accept(byte) { continuation.yield(.delta(text)) }
                        for call in assembler.takeToolCalls() { continuation.yield(.toolCall(call)) }
                        if assembler.progress.isFinished { break }
                    }
                    // The record goes out only with a whole turn, ahead of the element that says so.
                    let terminal = try assembler.completion(wallClock: started.duration(to: .now))
                    if let record = assembler.record { continuation.yield(.record(record)) }
                    continuation.yield(terminal)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The provider's own account of a refused request: its JSON `error.message`
    /// when there is one, otherwise the start of the body. Only the body is
    /// read, so nothing the request carried (an API key travels in a header)
    /// can come back out through the error.
    static func failure(status: Int, body: Data) -> ProviderError {
        ProviderError.http(status: status, message: message(in: body))
    }

    /// The provider's own words in an error body: Anthropic's and Google's
    /// `error.message`, Ollama's `error`, otherwise the start of the body.
    static func message(in body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return ((json?["error"] as? [String: Any])?["message"] as? String)
            ?? (json?["error"] as? String)
            ?? String(decoding: body.prefix(400), as: UTF8.self)
    }

    /// One JSON POST, ready to send. Headers carry what identifies the caller:
    /// no key is ever put in the URL, where every proxy on the way logs it.
    static func request(_ url: URL, headers: [String: String], body: [String: Any],
                        timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Enough of a refused answer's body to quote it. A refusal that keeps
    /// sending is not read to the end.
    private static func head(of bytes: URLSession.AsyncBytes) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 2_000 { break }
            }
        } catch {
            // The status is the failure being reported; a body that stops
            // arriving is quoted as far as it got rather than replacing it.
        }
        return data
    }
}
