import Foundation

/// Plans through the Claude Code CLI and the person's own claude.ai sign-in:
/// no API key. `claude -p` with `--json-schema` returns the structured answer
/// in `structured_output`; every built-in tool is disabled so the planner can
/// only answer. Same process runner and environment allow-list as Codex.
actor ClaudeCLIClient: ModelClient {
    private let model: String
    private let effort: ReasoningEffort
    private var authenticated = false
    nonisolated var schemaFlavor: PlanSchema.Flavor { .full }

    init(model: String, effort: ReasoningEffort) {
        self.model = model
        self.effort = effort
    }

    func plan(prompt: String, schema: Data, timeout: TimeInterval) async throws -> PlanReply {
        if !authenticated {
            try await Self.checkAuthentication()
            authenticated = true
        }
        try Task.checkCancellation()
        var arguments = [
            "-p", "--output-format", "json",
            "--json-schema", String(decoding: schema, as: UTF8.self),
            "--model", model,
            "--tools", "", "--max-turns", "3",
            "--no-session-persistence", "--disable-slash-commands", "--strict-mcp-config",
        ]
        // Haiku 4.5 has no effort levels; the flag is left out for it.
        if !model.contains("haiku") { arguments += ["--effort", effort.rawValue] }
        let result = try await CodexCLIClient.run(executable: Self.executableURL(), arguments: arguments,
                                                  input: Data(prompt.utf8), schema: nil, timeout: timeout)
        return try Self.decode(result)
    }

    static func checkAuthentication() async throws {
        let result = try await CodexCLIClient.run(executable: executableURL(), arguments: ["auth", "status"],
                                                  input: Data(), schema: nil, timeout: 15)
        guard result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              json["loggedIn"] as? Bool == true
        else { throw ClaudeClientError.signInRequired }
    }

    static func executableURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            home.appendingPathComponent(".claude/local/claude").path,
        ]
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ClaudeClientError.unavailable
        }
        return URL(fileURLWithPath: path)
    }

    /// `claude -p --output-format json` prints one JSON object. Success carries
    /// `structured_output`; a failure has `is_error` and a `subtype` naming why.
    static func decode(_ result: CodexCLIClient.ProcessResult) throws -> PlanReply {
        guard let json = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any] else {
            let stderr = String(decoding: result.errors.prefix(300), as: UTF8.self)
            throw ClaudeClientError.failed(stderr.isEmpty ? "no JSON answer (exit \(result.status))" : stderr)
        }
        if json["is_error"] as? Bool == true {
            let detail = (json["result"] as? String) ?? (json["subtype"] as? String) ?? "unknown error"
            throw ClaudeClientError.failed(String(detail.prefix(500)))
        }
        guard let structured = json["structured_output"] else {
            throw ClaudeClientError.failed("no structured_output in the answer (\(json["subtype"] as? String ?? "?"))")
        }
        let plan = try JSONDecoder().decode(RawPlan.self, from: try JSONSerialization.data(withJSONObject: structured))
        let usage = json["usage"] as? [String: Any]
        let milliseconds = (json["duration_api_ms"] as? Int) ?? 0
        return PlanReply(plan: plan, usage: ModelUsage(inputTokens: usage?["input_tokens"] as? Int,
                                                       outputTokens: usage?["output_tokens"] as? Int,
                                                       duration: .milliseconds(milliseconds)))
    }
}

public enum ClaudeClientError: LocalizedError {
    case unavailable
    case signInRequired
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Claude Code CLI not found. Install it and sign in with “claude auth login”."
        case .signInRequired: "Claude Code is not signed in. Run “claude auth login” in Terminal."
        case .failed(let reason): "Claude Code: \(reason)"
        }
    }
}
