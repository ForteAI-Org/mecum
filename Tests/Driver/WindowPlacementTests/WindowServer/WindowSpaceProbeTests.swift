//
//  WindowSpaceProbeTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/10/2026.
//

import CoreGraphics
import SeatCore
import Testing
@testable import WindowPlacement

/// How the reply of the desktop listing becomes a layout, and what a Window ID
/// nothing owns answers. The reply is written down: no desktop is read or
/// switched on a real display.
@Suite("The desktop readings")
struct WindowSpaceProbeTests {

    static let builtIn = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    static let external = "276F9282-33E0-4A48-AF95-A4C23751A30A"

    static func row(
        _ identifier: String,
        current     : Int?,
        spaces      : [Int]
    ) -> [String: Any] {
        var row: [String: Any] = [
            "Display Identifier": identifier,
            "Spaces"            : spaces.map { ["ManagedSpaceID": $0, "type": 0] as [String: Any] },
        ]
        if let current { row["Current Space"] = ["ManagedSpaceID": current] }
        return row
    }

    @Test("every display becomes its desktops and the one it shows")
    func parsesTheReply() {
        let layout = WindowSpaceProbe.layout(
            from: [
                Self.row(Self.builtIn, current: 1, spaces: [2419, 1]),
                Self.row(Self.external, current: 2079, spaces: [2079, 2313]),
            ],
            displayID: { $0 == Self.builtIn ? 1 : 3 }
        )
        #expect(layout == DesktopLayout(displays: [
            .init(displayID: 1, spaces: [2419, 1], current: 1),
            .init(displayID: 3, spaces: [2079, 2313], current: 2079),
        ]))
    }

    @Test("a display without a current desktop is left out, and no display at all is nil")
    func malformedRowsAreDropped() {
        let layout = WindowSpaceProbe.layout(
            from: [
                Self.row(Self.builtIn, current: nil, spaces: [2419, 1]),
                Self.row(Self.external, current: 2079, spaces: [2079]),
            ],
            displayID: { _ in nil }
        )
        #expect(layout?.displays == [.init(displayID: nil, spaces: [2079], current: 2079)])
        #expect(WindowSpaceProbe.layout(from: [], displayID: { _ in nil }) == nil)
        #expect(
            WindowSpaceProbe.layout(
                from: [Self.row(Self.builtIn, current: nil, spaces: [1])],
                displayID: { _ in nil }
            ) == nil
        )
    }

    @Test("a Window ID that is not valid answers nothing, it does not trap")
    func invalidWindowNumber() {
        #expect(WindowSpaceProbe.spaces(of: 0) == nil)
        #expect(WindowSpaceProbe.spaces(of: -1) == nil)
    }
}
