//
//  ProviderCatalog+Check.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation

extension ProviderCatalog {

    // MARK: Checking

    /// Checks one connection, and `model` in its catalogue when one is named.
    ///
    /// This is the single authority for a provider's state: `status` is this
    /// check read as a sentence. The request asks and changes nothing: a
    /// model's own entry for an API provider, the listing when no model is
    /// named, `/api/tags` for Ollama, and the sign-in status for a command
    /// line. What came back is classified by `classify`, which touches no
    /// network, so the mapping is tested from each provider's real shapes.
    ///
    /// A missing key is answered without a request. Cancelling the calling
    /// task cancels the request, and the result is then `unreachable`.
    public static func check(
        _ provider: ModelProvider,
        model     : String? = nil,
        settings  : ProviderSettings
    ) async -> ConnectionState {

        let destination = ProviderConnection(provider: provider, settings: settings).destination

        switch provider {
        case .codex:
            return await checkCommandLine(destination: destination, locate: CodexCLIClient.executableURL) {
                let result = try await CodexCLIClient.run(
                    executable: $0,
                    arguments : ["login", "status"],
                    input     : Data(),
                    schema    : nil,
                    timeout   : 10
                )
                return classifyCodexLogin(exitStatus: result.status, output: result.output + result.errors)
            }

        case .claudeCode:
            return await checkCommandLine(destination: destination, locate: ClaudeCLIClient.executableURL) {
                let result = try await CodexCLIClient.run(
                    executable: $0,
                    arguments : ["auth", "status"],
                    input     : Data(),
                    schema    : nil,
                    timeout   : 15
                )
                return classifyClaudeAuth(exitStatus: result.status, output: result.output)
            }

        case .anthropic:
            let key = settings.anthropicAPIKey
            guard !key.isEmpty else { return .credentialMissing }
            let base = "https://api.anthropic.com/v1/models"
            guard let url = modelURL(base: base, model: model, listing: "?limit=1") else {
                return unnamable(model)
            }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return await answer(to: request, provider: provider, model: model, destination: destination,
                                credential: key)

        case .gemini:
            let key = settings.geminiAPIKey
            guard !key.isEmpty else { return .credentialMissing }
            let base = "https://generativelanguage.googleapis.com/v1beta/models"
            guard let url = modelURL(base: base, model: model, listing: "?pageSize=1") else {
                return unnamable(model)
            }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            return await answer(to: request, provider: provider, model: model, destination: destination,
                                credential: key)

        case .ollama:
            let host = settings.ollamaHost.hasSuffix("/") ? String(settings.ollamaHost.dropLast())
                                                          : settings.ollamaHost
            guard let url = URL(string: host + "/api/tags"), url.scheme != nil else {
                return .unreachable(destination: destination, detail: "the address is not a URL")
            }
            return await answer(to: URLRequest(url: url, timeoutInterval: 10), provider: provider,
                                model: model, destination: destination, credential: "")
        }
    }

    /// A replacement to propose for a model the catalogue no longer lists:
    /// the first of the provider's usual models still listed, otherwise the
    /// first listed. It is only a proposal; nothing here applies it.
    public static func replacement(
        for removed: String,
        provider   : ModelProvider,
        catalogue  : [String]
    ) -> String? {

        let candidates = catalogue.filter { $0 != removed }
        return provider.defaultModels.first(where: candidates.contains) ?? candidates.first
    }

    // MARK: Classifying

    /// Classifies an HTTP answer to a check.
    ///
    /// Anthropic: 401 is a refused key; 402 (`billing_error`) and 429
    /// (`rate_limit_error`) are usage limits; 404 on a model's entry is a
    /// removed model. A credit balance that is too low has come back as a
    /// 400 `invalid_request_error`, the same type as any malformed request,
    /// so it cannot be told apart and reads as `refused` in Anthropic's words.
    ///
    /// Google: a bad key is 400 `INVALID_ARGUMENT` whose `ErrorInfo.reason` is
    /// `API_KEY_INVALID`, or 401; 429 `RESOURCE_EXHAUSTED` is a usage limit, and
    /// it covers both a per-minute rate and a daily quota, which the check does
    /// not separate; 404 on a model's entry is a removed model. A 403 means the
    /// key is valid and not allowed here, which is `refused`.
    ///
    /// Ollama: a 2xx carries `/api/tags`, and a named model missing from it is
    /// removed. Ollama reads a bare name as its `:latest` tag, and so does
    /// this. Any other status is `refused`.
    ///
    /// `credential` is removed from every quoted detail. Only an exact copy is
    /// recognised: a provider that quoted a fragment of the key would not be.
    static func classify(
        provider  : ModelProvider,
        status    : Int,
        body      : Data,
        model     : String?,
        credential: String
    ) -> ConnectionState {

        let detail = redacted(HTTPTransport.message(in: body), removing: credential)

        if (200..<300).contains(status) {
            guard provider == .ollama, let model else { return .ready }
            let listed = Set(ollamaNames(in: body))
            let tagged = model.contains(":") ? model : model + ":latest"
            return listed.contains(model) || listed.contains(tagged) ? .ready : .modelRemoved(model: model)
        }

        switch (provider, status) {
        case (.anthropic, 401), (.gemini, 401):
            return .credentialRejected(detail: detail)
        case (.gemini, 400) where googleReasons(in: body).contains("API_KEY_INVALID"):
            return .credentialRejected(detail: detail)
        case (.anthropic, 402), (.anthropic, 429), (.gemini, 429):
            return .usageLimited(detail: detail)
        case (.anthropic, 404), (.gemini, 404):
            guard let model else { return .refused(detail: detail) }
            return .modelRemoved(model: model)
        default:
            return .refused(detail: detail)
        }
    }

    /// Nothing answered at the destination. Every `URLError` is that, from a
    /// refused connection to a failed TLS handshake: none carries an answer.
    static func classify(_ error: URLError, destination: String) -> ConnectionState {
        .unreachable(destination: destination, detail: error.localizedDescription)
    }

    /// Classifies `codex login status`.
    ///
    /// The command has no machine-readable output. A non-zero exit is no
    /// sign-in; on a zero exit the CLI's fixed, unlocalised status line tells
    /// a ChatGPT sign-in from an API key one, and only ChatGPT is used here.
    /// The output is never quoted: an API key sign-in prints part of the key.
    /// A usage limit on the subscription is not visible to this command.
    static func classifyCodexLogin(exitStatus: Int32, output: Data) -> ConnectionState {
        guard exitStatus == 0 else { return .credentialMissing }
        guard String(decoding: output, as: UTF8.self).contains("Logged in using ChatGPT") else {
            return .refused(detail: "the codex command line is signed in, but not with a ChatGPT account, "
                + "which is the only sign-in this app uses")
        }
        return .ready
    }

    /// Classifies `claude auth status`, which prints a JSON object with
    /// `loggedIn`. A usage limit on the subscription is not visible to it.
    static func classifyClaudeAuth(exitStatus: Int32, output: Data) -> ConnectionState {
        let json = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
        switch json?["loggedIn"] as? Bool {
        case true?  where exitStatus == 0: return .ready
        case false?:                       return .credentialMissing
        default:
            return .refused(detail: "claude auth status ended with exit \(exitStatus) and no sign-in state")
        }
    }

    // MARK: Helpers

    private static func answer(
        to request : URLRequest,
        provider   : ModelProvider,
        model      : String?,
        destination: String,
        credential : String
    ) async -> ConnectionState {

        do {
            let (body, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return classify(provider: provider, status: status, body: body, model: model, credential: credential)
        } catch let error as URLError {
            return classify(error, destination: destination)
        } catch {
            return .unreachable(destination: destination, detail: error.localizedDescription)
        }
    }

    /// Runs a command line's status check. A missing executable and a run
    /// that failed, timed out or was cancelled are all "nothing answered".
    private static func checkCommandLine(
        destination: String,
        locate     : () throws -> URL,
        status     : (URL) async throws -> ConnectionState
    ) async -> ConnectionState {

        let executable: URL
        do {
            executable = try locate()
        } catch {
            return .unreachable(destination: destination, detail: "it is not installed where this app looks for it")
        }
        do {
            return try await status(executable)
        } catch {
            return .unreachable(destination: destination, detail: error.localizedDescription)
        }
    }

    /// A model's own entry, or the first page of the listing when none is
    /// named. Nil when the name cannot be a path segment.
    private static func modelURL(base: String, model: String?, listing: String) -> URL? {
        guard let model else { return URL(string: base + listing) }
        guard let segment = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              !segment.isEmpty, !segment.contains("/")
        else { return nil }
        return URL(string: base + "/" + segment)
    }

    private static func ollamaNames(in body: Data) -> [String] {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return (json?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    }

    /// The `ErrorInfo.reason` codes of a Google error body.
    private static func googleReasons(in body: Data) -> [String] {
        let json    = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let details = (json?["error"] as? [String: Any])?["details"] as? [[String: Any]] ?? []
        return details.compactMap { $0["reason"] as? String }
    }

    private static func unnamable(_ model: String?) -> ConnectionState {
        .refused(detail: "\"\(model ?? "")\" cannot be looked up as a model name")
    }

    static func redacted(_ text: String, removing secret: String) -> String {
        secret.isEmpty ? text : text.replacingOccurrences(of: secret, with: "[redacted]")
    }
}
