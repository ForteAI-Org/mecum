import Darwin
import Foundation

public enum CodexClientError: LocalizedError {
    case unavailable
    case signInRequired
    case timedOut
    case outputLimit
    case inputLimit
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Codex CLI not found. Install Codex or the ChatGPT app and sign in with your subscription."
        case .signInRequired: "Codex is not signed in with ChatGPT. Run “codex login” in Terminal and choose the ChatGPT login."
        case .timedOut: "Codex did not answer within the limit; the request process was killed."
        case .outputLimit: "The Codex answer exceeds the lab's output limit."
        case .inputLimit: "The prompt exceeds 1,000,000 bytes; nothing was truncated."
        case .failed(let reason): "Codex: \(reason)"
        }
    }
}

/// Plans through the official Codex CLI and its own login store: no token is
/// read, no API key exists, and every desktop tool of the CLI is disabled so
/// the planner can only answer. Ported from the research lab, which validated
/// this exact argument list.
actor CodexCLIClient: ModelClient {
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
        let started = ContinuousClock.now
        let result = try await Self.run(executable: Self.executableURL(), arguments: try arguments(),
                                        input: Data(prompt.utf8), schema: schema, timeout: timeout)
        let output = try Self.decodeStructuredOutput(output: result.output, exitStatus: result.status)
        // The CLI reports no token counts; only the wall clock is known.
        return PlanReply(plan: try JSONDecoder().decode(RawPlan.self, from: output),
                         usage: ModelUsage(inputTokens: nil, outputTokens: nil, duration: started.duration(to: .now)))
    }

    static func checkAuthentication() async throws {
        let result = try await run(executable: executableURL(), arguments: ["login", "status"],
                                   input: Data(), schema: nil, timeout: 10)
        guard result.status == 0,
              String(decoding: result.output + result.errors, as: UTF8.self).contains("Logged in using ChatGPT")
        else { throw CodexClientError.signInRequired }
    }

    static func executableURL() throws -> URL {
        let paths = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
        ]
        guard let path = paths.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw CodexClientError.unavailable
        }
        return URL(fileURLWithPath: path)
    }

    private func arguments() throws -> [String] {
        guard ModelSelection.supportedEfforts(provider: .codex, model: model).contains(effort) else {
            throw CodexClientError.failed("effort \(effort.title) is not supported by \(model)")
        }
        var result = [
            "exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check",
            "--sandbox", "read-only", "--color", "never", "--json", "--model", model,
            "-c", "forced_login_method=\"chatgpt\"",
            "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\"",
            "-c", "model_reasoning_effort=\"\(effort.rawValue)\"", "-c", "project_doc_max_bytes=0",
        ]
        for feature in [
            "shell_tool", "unified_exec", "apps", "plugins", "browser_use", "computer_use",
            "multi_agent", "memories", "hooks", "image_generation", "view_image",
            "skill_search", "code_mode", "code_mode_only", "code_mode_host",
        ] {
            result += ["--disable", feature]
        }
        return result
    }

    /// Only launch environment, login store and TLS/proxy settings reach the
    /// child. API keys and alternate endpoints never do.
    static func environment(from inherited: [String: String]) -> [String: String] {
        let allowed: Set<String> = [
            "HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "SHELL", "LANG", "LC_ALL",
            "CODEX_HOME", "SSL_CERT_FILE", "SSL_CERT_DIR", "CODEX_CA_CERTIFICATE",
            "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
        ]
        return inherited.filter { allowed.contains($0.key) }
    }

    /// The CLI streams JSONL events. A valid answer is one started and completed
    /// turn, no error, and exactly one final agent message holding a JSON object.
    /// Any other item type means the model reached for a tool, which is refused.
    static func decodeStructuredOutput(output: Data, exitStatus: Int32) throws -> Data {
        var finalMessage: String?
        var started = false
        var completed = false
        var reportedError: String?
        for line in output.split(separator: 10) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = event["type"] as? String
            else { throw CodexClientError.failed("invalid JSON stream") }
            if type == "turn.started" { started = true }
            if type == "turn.completed" { completed = true }
            if type == "error" || type == "turn.failed" {
                reportedError = (event["message"] as? String)
                    ?? (event["error"] as? [String: Any])?["message"] as? String
                    ?? "request not completed"
            }
            if type.hasPrefix("item."), let item = event["item"] as? [String: Any] {
                if item["type"] as? String == "error" {
                    // Luna reports before the turn that Code Mode is off because we disabled it: client noise.
                    let message = item["message"] as? String ?? "client error"
                    if started || !message.hasPrefix("Code Mode is unavailable because code-mode host is disabled.") {
                        reportedError = message
                    }
                    continue
                }
                guard let kind = item["type"] as? String, kind == "agent_message" || kind == "reasoning" else {
                    throw CodexClientError.failed("the planner tried to use an external tool")
                }
                if kind == "agent_message", type == "item.completed" {
                    finalMessage = item["text"] as? String
                }
            }
        }
        guard exitStatus == 0, started, completed, reportedError == nil, let finalMessage,
              (try? JSONSerialization.jsonObject(with: Data(finalMessage.utf8))) is [String: Any]
        else {
            // stderr is never surfaced: the CLI may echo the whole prompt into it.
            throw CodexClientError.failed(String((reportedError ?? "incomplete structured answer").prefix(500)))
        }
        return Data(finalMessage.utf8)
    }

    struct ProcessResult: Sendable {
        let status: Int32
        let output: Data
        let errors: Data
    }

    /// Process and file handles stay on the concurrent pool; no child I/O or
    /// waitUntilExit ever runs on the main actor.
    @concurrent
    static func run(executable: URL, arguments: [String], input: Data, schema: Data?,
                    timeout: TimeInterval) async throws -> ProcessResult {
        try Task.checkCancellation()
        guard input.count <= 1_000_000 else { throw CodexClientError.inputLimit }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLab-Codex-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.txt")
        let outputURL = directory.appendingPathComponent("output.jsonl")
        let errorURL = directory.appendingPathComponent("stderr.txt")
        try input.write(to: inputURL)
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let stdin = try FileHandle(forReadingFrom: inputURL)
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.environment = environment(from: ProcessInfo.processInfo.environment)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        var arguments = arguments
        if let schema {
            let schemaURL = directory.appendingPathComponent("schema.json")
            try schema.write(to: schemaURL)
            arguments += ["--output-schema", schemaURL.path, "-"]
        }
        process.arguments = arguments
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CodexClientError.timedOut }
                for url in [outputURL, errorURL] {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 2_000_000 else { throw CodexClientError.outputLimit }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
        } catch {
            stop(process)
            throw error
        }
        let output = try Data(contentsOf: outputURL)
        let errors = try Data(contentsOf: errorURL)
        guard output.count <= 2_000_000, errors.count <= 2_000_000 else { throw CodexClientError.outputLimit }
        return ProcessResult(status: process.terminationStatus, output: output, errors: errors)
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        // The child this request owns, never the person's own Codex.
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}
