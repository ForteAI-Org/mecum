//
//  ShellMetricsTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Testing
import TeamShell

@Suite("The team window's widths and how space is divided")
struct ShellMetricsTests {

    @Test("Each column starts inside its own range, and the ranges are the spec's tokens")
    func theColumnTokensAreConsistent() {
        for column in [ShellMetrics.sidebar, ShellMetrics.inspector] {
            #expect(column.minimum <= column.ideal && column.ideal <= column.maximum)
        }
        #expect(ShellMetrics.sidebar   == ColumnWidth(ideal: 280, minimum: 250, maximum: 340))
        #expect(ShellMetrics.inspector == ColumnWidth(ideal: 360, minimum: 320, maximum: 440))
    }

    @Test("When the three areas do not fit, the inspector closes and the conversation keeps its width")
    func theInspectorClosesFirst() {
        // 1100 = 280 + 360 + 460: all three fit exactly; one point less does not.
        #expect(ShellMetrics.fitsInspector(window: 1100, isSidebarShown: true))
        #expect(!ShellMetrics.fitsInspector(window: 1099, isSidebarShown: true))
        // 900, the restored window that aborted, cannot hold both columns beside the conversation.
        #expect(!ShellMetrics.fitsInspector(window: 900, isSidebarShown: true))
        #expect(ShellMetrics.fitsInspector(window: 900, isSidebarShown: false))
    }

    @Test("A resize across the line closes the inspector once and opens it again only with room to spare")
    func aResizeAcrossTheLineDoesNotFlipTwice() {
        let resize = ShellMetrics.showsInspectorAfterResize
        // Shown: stays down to the line, closes below it.
        #expect(resize(1100, true, true))
        #expect(!resize(1099, true, true))
        // Closed: a few points past the line are not enough to bring it back.
        #expect(!resize(1101, true, false))
        #expect(!resize(1123, true, false))
        #expect(resize(1124, true, false))
        // Walk a jittering resize and count the flips: one close, one reopen.
        var isShown = true
        var flips   = 0
        for width in [1110.0, 1099, 1101, 1098, 1105, 1110, 1130, 1120, 1101] {
            let next = resize(width, true, isShown)
            if next != isShown { flips += 1 }
            isShown = next
        }
        #expect(flips == 2)
        #expect(isShown)
    }

    @Test("Opening the inspector on request hides the sidebar only when that is what makes it fit")
    func openingOnRequestHidesTheSidebarOnlyWhenNeeded() {
        #expect(!ShellMetrics.openingHidesSidebar(window: 1200))
        #expect(ShellMetrics.openingHidesSidebar(window: 900))
        #expect(ShellMetrics.openingHidesSidebar(window: 820))
    }

    @Test("The window's minimum lets the inspector open beside the conversation once the sidebar is hidden")
    func theWindowMinimumAlwaysAdmitsTheInspector() {
        #expect(ShellMetrics.windowMinimum == 820)
        #expect(ShellMetrics.fitsInspector(window: ShellMetrics.windowMinimum, isSidebarShown: false))
        #expect(ShellMetrics.windowMinimum - ShellMetrics.sidebar.ideal >= ShellMetrics.conversationMinimum)
    }
}
