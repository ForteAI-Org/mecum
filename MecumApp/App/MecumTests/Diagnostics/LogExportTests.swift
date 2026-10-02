//
//  LogExportTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 02/10/2026.
//

import Foundation
import Testing
@testable import Mecum

/// The pure parts of the log export: what `log` is asked, the header that
/// opens the file and the name the save panel proposes.
@Suite("Log export")
struct LogExportTests {

    /// 2 October 2026, 09:42:07 UTC.
    private static let date = Date(timeIntervalSince1970: 1_790_934_127)

    @Test("The log tool is asked for 24 hours of this process and the kit's subsystems")
    func arguments() {
        #expect(LogExport.arguments(processName: "Mecum") == [
            "show",
            "--last", "24h",
            "--info",
            "--style", "compact",
            "--predicate", #"process == "Mecum" OR subsystem BEGINSWITH "dev.forte""#
        ])
    }

    @Test("A quote or backslash in the process name stays inside its string")
    func predicateEscapes() {
        #expect(LogExport.predicate(processName: #"Me"cu\m"#)
                == #"process == "Me\"cu\\m" OR subsystem BEGINSWITH "dev.forte""#)
    }

    @Test("The header names the version, the system and the date, then a blank line")
    func header() {
        let header = LogExport.header(
            version   : "1.0",
            build     : "42",
            system    : "Version 26.3 (Build 25D125)",
            exportedAt: Self.date
        )
        #expect(header == """
            Mecum 1.0 (42)
            macOS Version 26.3 (Build 25D125)
            Exported 2026-10-02T09:42:07Z


            """)
    }

    @Test("The default file name is local time with no colons or slashes")
    func defaultFileName() throws {
        let rome = try #require(TimeZone(identifier: "Europe/Rome"))
        let name = LogExport.defaultFileName(
            at      : Self.date,
            timeZone: rome
        )
        #expect(name == "Mecum Log 2026-10-02 11.42.txt")
        #expect(!name.contains(":"))
        #expect(!name.contains("/"))
    }
}
