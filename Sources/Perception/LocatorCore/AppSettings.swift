import Foundation

/// User-tunable defaults shared by every frontend — `~/Library/Application Support/Locator/settings.json`.
/// This exists so the tool is HANDABLE: a teammate configures once through `locator` (the menu) and every
/// binary picks it up — no shell profile exports required. Resolution order everywhere stays:
/// explicit flag > environment variable > this file > built-in default. Env never loses to the file, so
/// existing setups keep working unchanged.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Gemini API key for locator-gemini. Stored locally (0600) — never leaves the machine except in
    /// locator-gemini's own HTTPS calls to Google. Env NANOBANANA_GEMINI_API_KEY still wins.
    public var geminiAPIKey: String?
    /// Gemini model id (default gemini-3.6-flash).
    public var geminiModel: String?
    /// Ollama model tag for locator-chat (default gemma4:e2b).
    public var ollamaModel: String?

    public init(geminiAPIKey: String? = nil, geminiModel: String? = nil, ollamaModel: String? = nil) {
        self.geminiAPIKey = geminiAPIKey
        self.geminiModel = geminiModel
        self.ollamaModel = ollamaModel
    }
}

public struct AppSettingsStore {
    let fileURL: URL
    let fileManager: FileManager

    /// Default: the real settings file. Tests inject their own directory.
    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.fileURL = directory.appendingPathComponent("settings.json")
        } else {
            let appSupport = (try? fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = appSupport.appendingPathComponent("Locator/settings.json")
        }
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    /// Atomic (temp + rename, same volume) and private (0600 — the file can hold an API key).
    public func save(_ settings: AppSettings) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = fileURL.deletingLastPathComponent().appendingPathComponent(".settings-\(UUID().uuidString).tmp")
        try enc.encode(settings).write(to: tmp)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try? fileManager.removeItem(at: fileURL)
        try fileManager.moveItem(at: tmp, to: fileURL)
    }
}
