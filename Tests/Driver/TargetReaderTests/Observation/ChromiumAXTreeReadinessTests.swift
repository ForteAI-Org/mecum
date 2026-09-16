//
//  ChromiumAXTreeReadinessTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

@testable import TargetReader
import Testing

@Suite("Chrome web accessibility readiness")
struct ChromiumAXTreeReadinessTests {
    @Test("reading a container role exposes its lazily published web child")
    func lazyContent() {
        var containerRead = false
        let reading = ChromiumAXTreeReadiness.read(
            root: 0,
            role: { node in
                if node == 1 { containerRead = true; return "AXGroup" }
                return node == 2 ? "AXWebArea" : "AXWindow"
            },
            children: { node in
                if node == 0 { return [1] }
                return node == 1 && containerRead ? [2] : []
            }
        )
        #expect(reading.hasWebArea)
        #expect(!reading.wasTruncated)
    }

    @Test("browser chrome alone is distinct from both a page and a native dialog")
    func toolbarOnly() {
        let toolbar = ChromiumAXTreeReadiness.read(
            root: 0,
            role: { $0 == 1 ? "AXTabGroup" : "AXWindow" },
            children: { $0 == 0 ? [1] : [] }
        )
        #expect(toolbar.hasTabs && !toolbar.hasWebArea && !toolbar.wasTruncated)
        let dialog = ChromiumAXTreeReadiness.read(root: 0, role: { _ in "AXDialog" }, children: { _ in [] })
        #expect(!dialog.hasTabs && !dialog.hasWebArea && !dialog.wasTruncated)
    }

    @Test("a bounded walk cannot be called a fully read native dialog")
    func boundedWalk() {
        let reading = ChromiumAXTreeReadiness.read(
            root: 0,
            limit: 2,
            role: { _ in "AXGroup" },
            children: { [$0 + 1] }
        )
        #expect(reading.wasTruncated)
        #expect(!reading.hasWebArea)
    }

    @Test("cyclic or shared elements are read only once")
    func repeatedElements() {
        var readCount = 0
        let reading = ChromiumAXTreeReadiness.read(
            root: 0,
            role: { _ in readCount += 1; return "AXGroup" },
            children: { $0 == 0 ? [1, 1] : [0] }
        )
        #expect(readCount == 2)
        #expect(!reading.wasTruncated)
    }
}
