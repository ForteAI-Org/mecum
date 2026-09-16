//
//  ProbePageContractTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 10/09/2026.
//

import Foundation
import Testing

/// The page and its reader must agree before a browser is launched. A renamed
/// title marker otherwise makes every browser row disappear from the matrix.
@MainActor
struct ProbePageContractTests {

    @Test("the probe page publishes the marker used to discover its browser window")
    func probePageTitleMatchesDiscovery() throws {
        let page = try #require(Bundle.module.url(forResource: "probe-page", withExtension: "html"))
        let html = try String(contentsOf: page, encoding: .utf8)
        #expect(html.contains("<title>\(ChromeTarget.titleMark)"))
        #expect(html.contains("document.title=`\(ChromeTarget.titleMark)"))
    }
}
