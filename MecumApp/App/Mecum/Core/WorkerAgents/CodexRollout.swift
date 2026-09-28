//
//  CodexRollout.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 25/09/2026.
//

import ChatCore
import Foundation

/// CodexRollout reads what Codex writes to its session's rollout file and not
/// to stdout: how much of the context the session fills, the model's window and
/// the account's limits, from the file's last `token_count` events, and whether
/// the session was compacted, from a `compacted` line.
///
/// The rollout is Codex's own record, not an interface it documents, so every
/// read is best effort: a file that is missing, unreadable or in a shape this
/// does not know gives nothing, and never an error.
nonisolated enum CodexRollout {

    /// What the last token counts say. A field they said nothing about is nil or empty.
    struct Reading: Sendable, Hashable {
        let contextTokens: Int?
        let contextWindow: Int?
        let rateLimits   : [ProviderUsage.RateLimit]
    }

    /// Where Codex keeps its sessions for the environment its child ran with:
    /// `$CODEX_HOME/sessions`, else `~/.codex/sessions`.
    static func sessions(environment: [String: String]) -> URL {
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appending(
                path         : "sessions",
                directoryHint: .isDirectory
            )
        }
        let home = environment["HOME"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appending(
            path         : ".codex/sessions",
            directoryHint: .isDirectory
        )
    }

    /// The rollout of `thread`, `YYYY/MM/DD/rollout-<time>-<thread>.jsonl` under
    /// `sessions`: today's and yesterday's folders first, in local time as Codex
    /// names them, then the rest of the tree for a session begun earlier.
    // ponytail: the tree walk stops after 20,000 entries; index the sessions by thread if people keep more.
    static func file(
        of thread  : String,
        in sessions: URL,
        now        : Date     = Date(),
        calendar   : Calendar = .current
    ) -> URL? {
        let files = FileManager.default
        func isRollout(_ name: String) -> Bool { name.hasPrefix("rollout-") && name.hasSuffix("-\(thread).jsonl") }

        for daysAgo in [0, 1] {
            guard let day = calendar.date(
                byAdding: .day,
                value   : -daysAgo,
                to      : now
            ) else { continue }
            let date   = calendar.dateComponents(
                [.year, .month, .day],
                from: day
            )
            let folder = sessions.appending(
                path         : String(
                    format: "%04ld/%02ld/%02ld",
                    date.year ?? 0,
                    date.month ?? 0,
                    date.day ?? 0
                ),
                directoryHint: .isDirectory
            )
            // A folder that is not there is the common case, and simply holds no rollout.
            let names = (try? files.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            if let name = names.first(where: isRollout) { return folder.appending(path: name) }
        }

        guard let walk = files.enumerator(
            at                        : sessions,
            includingPropertiesForKeys: nil
        ) else { return nil }
        var visited = 0
        for case let url as URL in walk {
            if isRollout(url.lastPathComponent) { return url }
            visited += 1
            if visited >= 20_000 { return nil }
        }
        return nil
    }

    /// What the last token counts in the file's tail say, nil when it has none to read.
    static func reading(of file: URL) -> Reading? {
        tail(of: file).flatMap(reading(from:))
    }

    /// The file's last lines, nil when it cannot be read. A tail that starts
    /// inside a line leaves that line unreadable, and readers skip it.
    // ponytail: reads the last 1 MB, which holds the turn's last token count and a compaction's
    // line unless one of them outgrows it.
    static func tail(of file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }

        let tailBytes: UInt64 = 1_048_576
        guard let size = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)) != nil
        else { return nil }
        return try? handle.readToEnd()
    }

    /// True when `lines` hold a `compacted` line stamped at or after `start`,
    /// which is how a compaction during a turn begun at `start` shows.
    static func compacts(
        in lines   : Data,
        since start: Date
    ) -> Bool {
        let stamps = [
            Date.ISO8601FormatStyle(includingFractionalSeconds: true),
            Date.ISO8601FormatStyle(),
        ]
        return lines.split(separator: 10).reversed().contains { line in
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  event["type"] as? String == "compacted",
                  let stamp = event["timestamp"] as? String,
                  let date  = stamps.lazy.compactMap({ try? $0.parse(stamp) }).first
            else { return false }
            return date >= start
        }
    }

    /// What the last `token_count` lines say: the context and window from the
    /// newest one with `info`, the limits from the newest one with `rate_limits`,
    /// which a count written right after a compaction leaves out.
    static func reading(from lines: Data) -> Reading? {
        var info  : [String: Any]?
        var limits: [String: Any]?
        for line in lines.split(separator: 10).reversed() {
            if info != nil, limits != nil { break }
            guard let event   = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  event["type"] as? String == "event_msg",
                  let payload = event["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count"
            else { continue }
            info   = info ?? payload["info"] as? [String: Any]
            limits = limits ?? payload["rate_limits"] as? [String: Any]
        }
        guard info != nil || limits != nil else { return nil }

        let last = info?["last_token_usage"] as? [String: Any]
        return Reading(
            contextTokens: (last?["input_tokens"] as? Int).map { $0 + (last?["output_tokens"] as? Int ?? 0) },
            contextWindow: info?["model_context_window"] as? Int,
            rateLimits   : ["primary", "secondary"].compactMap { window in
                guard let values = limits?[window] as? [String: Any],
                      let used   = values["used_percent"] as? Double
                else { return nil }
                return ProviderUsage.RateLimit(
                    window       : window,
                    usedFraction : used / 100,
                    resetsAt     : (values["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:)),
                    windowMinutes: values["window_minutes"] as? Int
                )
            }
        )
    }
}
