//
//  LogExport.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/10/2026.
//

import Foundation

/// LogExport writes Mecum's unified log from the last 24 hours to a file, so a
/// tester can attach it to a bug report without the Terminal.
///
/// The file starts with a short header naming the app version, the system and
/// the export date, followed by the output of `/usr/bin/log show`. The
/// arguments, the header and the default file name are pure so tests can check
/// them without running `log`.
nonisolated enum LogExport {

    /// LogExport.Failure is why `log` produced no usable file.
    struct Failure: LocalizedError {
        let status      : Int32
        let errorExcerpt: String

        var errorDescription: String? {
            let reason = "The log tool stopped with status \(status)."
            return errorExcerpt.isEmpty ? reason : "\(reason)\n\n\(errorExcerpt)"
        }
    }

    /// How far back the export reaches, in `log show --last` notation.
    static let period = "24h"

    /// Selects this process's entries and every entry of the kit's subsystems.
    static func predicate(processName: String) -> String {
        let quoted = processName
            .replacingOccurrences(
                of  : "\\",
                with: "\\\\"
            )
            .replacingOccurrences(
                of  : "\"",
                with: "\\\""
            )
        return "process == \"\(quoted)\" OR subsystem BEGINSWITH \"dev.forte\""
    }

    /// The arguments to `/usr/bin/log`, one element per word.
    static func arguments(processName: String) -> [String] {
        [
            "show",
            "--last", period,
            "--info",
            "--style", "compact",
            "--predicate", predicate(processName: processName)
        ]
    }

    /// The lines that open the file, ending with a blank line before the log.
    static func header(
        version   : String,
        build     : String,
        system    : String,
        exportedAt: Date
    ) -> String {
        """
        Mecum \(version) (\(build))
        macOS \(system)
        Exported \(exportedAt.ISO8601Format())


        """
    }

    /// The name the save panel proposes, in local time and without colons,
    /// which Finder shows as slashes.
    static func defaultFileName(
        at date : Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter        = DateFormatter()
        formatter.locale     = Locale(identifier: "en_US_POSIX")
        formatter.timeZone   = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Mecum Log \(formatter.string(from: date)).txt"
    }

    /// Writes the header and then streams `log show` into the file at `url`.
    ///
    /// The process runs on a global queue and writes straight into the file,
    /// so the log is never held in memory. On any failure the partial file is
    /// removed and the error is thrown.
    static func export(to url: URL) async throws {
        let info   = Bundle.main.infoDictionary ?? [:]
        let header = header(
            version   : info["CFBundleShortVersionString"] as? String ?? "unknown",
            build     : info["CFBundleVersion"] as? String ?? "unknown",
            system    : ProcessInfo.processInfo.operatingSystemVersionString,
            exportedAt: .now
        )
        let arguments = arguments(processName: ProcessInfo.processInfo.processName)
        do {
            try Data(header.utf8).write(to: url)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(
                        with: Result {
                            try runLog(
                                arguments: arguments,
                                appending: url
                            )
                        }
                    )
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Runs `log` to completion with its output appended to the file, blocking
    /// the calling thread until it exits.
    private static func runLog(
        arguments    : [String],
        appending url: URL
    ) throws {
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        try output.seekToEnd()

        let errors                = Pipe()
        let process               = Process()
        process.executableURL     = URL(filePath: "/usr/bin/log")
        process.arguments         = arguments
        process.standardOutput    = output
        process.standardError     = errors
        try process.run()

        // Read stderr before waiting, so a full pipe cannot hold the process.
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let excerpt = String(decoding: errorData, as: UTF8.self)
                .split(separator: "\n")
                .prefix(5)
                .joined(separator: "\n")
            throw Failure(
                status      : process.terminationStatus,
                errorExcerpt: excerpt
            )
        }
    }
}
