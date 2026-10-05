import AutomationRuntime
//
//  MemoryCommand.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import AppKit
import Foundation
import Memory
import PerceptionCore

/// MemoryCommand reads the living memory of a Knowledge directory without an application open, a
/// Seat or a provider (`MemoryDiagnosis`):
///
///     mecum memory status                                     where the archive stands and what it holds
///     mecum memory traces [--before <order>] [--limit <n>]    the traces, most recent first
///     mecum memory trace <trace-id> [--after <order>] [--limit <n>] [--detail]
///     mecum memory event <event-id> [--detail]                one event: its call, samples and scenes
///     mecum memory app <app> | mecum memory <app> [--detail]  an application's Brain
///
/// `<app>` is a bundle ID the archive holds, even of an application not installed, or the name of an
/// application the archive holds or that is running; a name that fits several is answered with the
/// candidates. A first word that names a subcommand is the subcommand: `memory app <word>` reads an
/// application by that name. `--detail` writes typed texts, window titles and element labels, which
/// are otherwise counted. A limit is at most 500. A missing archive, an empty file, an archive that
/// does not open or a read that fails exits 1 and creates nothing; a valid archive with nothing in
/// it exits 0 and says so. The older JSON knowledge is not read.
enum MemoryCommand {

    static let subcommands: Set<String> = ["status", "traces", "trace", "event", "app"]

    static func run(_ invocation: Invocation) async throws {
        let service = MemoryService(directory: CLIMemory.directory(invocation))
        do {
            try await diagnose(invocation, memory: service, directory: .live)
        } catch {
            await service.close()
            throw error
        }
        await service.close()
    }

    /// Runs the subcommand `invocation` names against `memory`, writing to `output`.
    static func diagnose(_ invocation: Invocation, memory: MemoryService, directory: ApplicationDirectory,
                         output: @escaping (String) -> Void = { print($0) }) async throws {
        let word = try invocation.positional(0, "status, traces, trace <id>, event <id> or <app>")
        let subcommand = subcommands.contains(word) ? word : "app"
        let operand = subcommands.contains(word) ? invocation.positionals.dropFirst().first : word
        let allowed: Set<String> = switch subcommand {
            case "traces": ["knowledge", "before", "limit"]
            case "trace": ["knowledge", "after", "limit"]
            default: ["knowledge"]
        }
        if let stray = invocation.options.keys.first(where: { !allowed.contains($0) }) {
            throw UsageError.invalid(option: stray, value: invocation.options[stray] ?? "", expected: "no such option for memory \(subcommand)")
        }
        let expected = ["status", "traces"].contains(subcommand) ? 1 : (word == subcommand ? 2 : 1)
        guard invocation.positionals.count == expected else {
            throw UsageError.missing(subcommand == "app" || subcommand == "trace" || subcommand == "event"
                                     ? "memory \(subcommand) <one \(subcommand == "app" ? "application" : "id")>"
                                     : "memory \(subcommand) with no further word")
        }
        // Every word is checked before the archive is opened.
        let before = try order(invocation, "before"), after = try order(invocation, "after")
        let count = try limit(invocation, default: subcommand == "traces" ? MemoryDiagnosis.defaultTraces : MemoryDiagnosis.defaultEntries)
        try await MemoryDiagnosis.open(memory, path: memory.url.path)
        let diagnosis = MemoryDiagnosis(memory: memory, directory: directory, detail: invocation.flags.contains("detail"),
                                        output: output)
        switch subcommand {
            case "status":
                try await diagnosis.status()
            case "traces":
                try await diagnosis.traces(before: before, limit: count)
            case "trace":
                try await diagnosis.trace(operand ?? "", after: after, limit: count)
            case "event":
                try await diagnosis.event(operand ?? "")
            default:
                try await diagnosis.app(operand ?? "")
        }
    }

    private static func order(_ invocation: Invocation, _ name: String) throws -> Int64? {
        guard let word = invocation.options[name] else { return nil }
        guard let value = Int64(word), value >= 0 else {
            throw UsageError.invalid(option: name, value: word, expected: "a local order, a whole number from 0")
        }
        return value
    }

    private static func limit(_ invocation: Invocation, default fallback: Int) throws -> Int {
        guard let word = invocation.options["limit"] else { return fallback }
        guard let value = Int(word), (1...MemoryDiagnosis.maximumLimit).contains(value) else {
            throw UsageError.invalid(option: "limit", value: word, expected: "a whole number from 1 to \(MemoryDiagnosis.maximumLimit)")
        }
        return value
    }
}

extension ApplicationDirectory {

    /// The Mac as it is: the installed application's name by Launch Services, and the running regular
    /// applications. Nothing is launched.
    static var live: ApplicationDirectory {
        ApplicationDirectory(
            installedName: { bundleID in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
                    let name = FileManager.default.displayName(atPath: $0.path)
                    return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
                }
            },
            running: {
                NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app in
                    app.bundleIdentifier.map { (name: app.localizedName ?? $0, bundleID: $0) }
                }
            }
        )
    }
}
