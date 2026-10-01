import BrowserCore
import Foundation

/// ChromeConfiguration supplies local profile discovery and the installed executable, without cookie access.
/// Only the automation directory may be created or launched. Current-profile attachment never launches Chrome.
public struct ChromeConfiguration: Sendable {
    public let executable: URL
    public let currentProfile: URL
    public let automationProfile: URL
    public let commandTimeout: Duration

    public init(executable: URL, currentProfile: URL, automationProfile: URL, commandTimeout: Duration = .seconds(15)) {
        self.executable = executable
        self.currentProfile = currentProfile
        self.automationProfile = automationProfile
        self.commandTimeout = commandTimeout
    }

    /// Resolves the conventional macOS installation and per-user application-support directories.
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return Self(
            executable: URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            currentProfile: support.appendingPathComponent("Google/Chrome", isDirectory: true),
            automationProfile: support.appendingPathComponent("Mecum/Browser/Chrome", isDirectory: true)
        )
    }

    func endpoint(profile: BrowserProfile) throws -> URL {
        let directory = profile == .current ? currentProfile : automationProfile
        let path = directory.appendingPathComponent("DevToolsActivePort")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw BrowserFailure(.setupRequired, profile == .current
                ? "Open chrome://inspect/#remote-debugging in Chrome 144+, enable remote debugging, then connect and approve Chrome's prompt."
                : "The persistent Chrome profile has not published its debugging endpoint yet.")
        }
        let data = try Data(contentsOf: path)
        guard data.count <= 4096, let value = String(data: data, encoding: .utf8) else {
            throw BrowserFailure(.setupRequired, "Invalid Chrome debugging endpoint file.")
        }
        return try Self.endpoint(contents: value)
    }

    static func endpoint(contents: String) throws -> URL {
        let lines = contents.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count == 2, let port = UInt16(lines[0]), port > 0,
              lines[1].hasPrefix("/devtools/browser/"),
              !lines[1].dropFirst("/devtools/browser/".count).isEmpty,
              lines[1].dropFirst("/devtools/browser/".count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let url = URL(string: "ws://127.0.0.1:\(port)\(lines[1])") else {
            throw BrowserFailure(.setupRequired, "Invalid local Chrome debugging endpoint. Re-enable Chrome remote debugging.")
        }
        return url
    }

    func launchAutomationProfile() throws -> Process {
        let managed = automationProfile.resolvingSymlinksInPath().standardizedFileURL
        let current = currentProfile.resolvingSymlinksInPath().standardizedFileURL
        guard managed != current, !managed.path.hasPrefix(current.path + "/"),
              !current.path.hasPrefix(managed.path + "/") else {
            throw BrowserFailure(.invalidArgument, "The automation profile must be separate from the current Chrome profile.")
        }
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BrowserFailure(.setupRequired, "Google Chrome is not installed at the configured executable.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--user-data-dir=\(managed.path)", "--remote-debugging-port=0",
                             "--remote-debugging-address=127.0.0.1", "--no-first-run", "--no-default-browser-check",
                             "about:blank"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
