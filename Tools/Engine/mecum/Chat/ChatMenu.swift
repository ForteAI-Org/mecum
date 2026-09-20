import ChatCore
import Darwin
import FileConversations
import Foundation

/// ChatMenu owns terminal questions and local model discovery. It never reads credentials.
enum ChatMenu {
    static func read(_ prompt: String) async -> String? {
        print(prompt, terminator: "")
        fflush(stdout)
        return await Task.detached { readLine() }.value
    }

    static func executable(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static func provider() async throws -> ChatProvider {
        let available = ChatProvider.allCases.filter { executable($0.rawValue) != nil }
        guard !available.isEmpty else { throw problem("Install and sign in to Claude Code or Codex first.") }
        for (index, provider) in available.enumerated() { print("  \(index + 1). \(provider.displayName)") }
        guard let answer = await read("Provider [1] › ") else { throw CancellationError() }
        if let selected = ChatProvider(rawValue: answer), available.contains(selected) { return selected }
        guard let index = Int(answer.isEmpty ? "1" : answer), available.indices.contains(index - 1) else {
            throw problem("Choose one of the listed providers.")
        }
        return available[index - 1]
    }

    static func model(_ provider: ChatProvider) async throws -> String? {
        var choices = ["default"]
        if provider == .claude { choices += ["sonnet", "opus"] }
        else {
            let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
                .map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let cache = home.appendingPathComponent("models_cache.json")
            if FileManager.default.fileExists(atPath: cache.path) {
                do {
                    let data = try Data(contentsOf: cache)
                    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let models = object["models"] as? [[String: Any]] {
                        choices += models.filter { $0["visibility"] as? String == "list" }.compactMap { $0["slug"] as? String }
                    }
                } catch { print("Could not read the model cache; enter a model name or use default.") }
            }
        }
        print("Models (provider validates availability):")
        for (index, choice) in choices.enumerated() { print("  \(index + 1). \(choice)") }
        guard let answer = await read("Model [1], or enter a model name › ") else { throw CancellationError() }
        let selected: String
        if let index = Int(answer.isEmpty ? "1" : answer), choices.indices.contains(index - 1) {
            selected = choices[index - 1]
        } else { selected = answer }
        guard !selected.isEmpty else { throw problem("Model name is empty.") }
        return selected == "default" ? nil : selected
    }

    static func choose(_ saved: [Conversation]) async throws -> Conversation? {
        guard !saved.isEmpty else { return nil }
        print("  0. New conversation")
        for (index, conversation) in saved.prefix(10).enumerated() {
            print("  \(index + 1). [\(conversation.provider.rawValue)] \(conversation.title)")
        }
        guard let answer = await read("Conversation [0] › ") else { throw CancellationError() }
        guard let index = Int(answer.isEmpty ? "0" : answer), index >= 0, index <= min(10, saved.count) else {
            throw problem("Choose a listed conversation.")
        }
        return index == 0 ? nil : saved[index - 1]
    }

    static func problem(_ message: String) -> NSError {
        NSError(domain: "MecumChat", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
