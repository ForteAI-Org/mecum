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

/// One JSON POST for the HTTP providers. Nothing clever: URLSession, a
/// timeout, and the provider's own error message on a non-2xx status.
enum HTTPTransport {
    static func postJSON(_ url: URL, headers: [String: String], body: [String: Any],
                         timeout: TimeInterval) async throws -> (json: [String: Any], elapsed: Duration) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = ContinuousClock.now
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = started.duration(to: .now)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(decoding: data.prefix(400), as: UTF8.self)
            throw ProviderError.http(status: status, message: message)
        }
        guard let json else { throw ProviderError.badResponse("not a JSON object") }
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

    /// Decodes the plan JSON a provider returned as text.
    static func decodePlan(_ text: String) throws -> RawPlan {
        do {
            return try JSONDecoder().decode(RawPlan.self, from: Data(text.utf8))
        } catch {
            throw ProviderError.badResponse(String(text.prefix(300)))
        }
    }
}
