//
//  AllowlistTests.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

import Foundation
@testable import Memory
import Testing

@Suite("Allowlist")
struct AllowlistTests {

    @Test("the default allows every application to be observed and acted in, destructive off")
    func defaults() {
        let allowlist = Allowlist()
        #expect(allowlist.allowAll)
        #expect(!allowlist.allowDestructive)
        #expect(allowlist.allows("com.anything.at.all"))
        #expect(allowlist.allowsActive("com.anything.at.all"))
        #expect(Allowlist(allowDestructive: true).allowDestructive)
    }

    @Test("restricted mode is a per-application opt-in where observing does not grant acting")
    func restricted() {
        var allowlist = Allowlist(bundleIDs: ["com.avid.ProTools"], allowAll: false)
        #expect(allowlist.allows("com.avid.ProTools"))
        #expect(!allowlist.allowsActive("com.avid.ProTools"))
        #expect(!allowlist.allows("com.other.app"))
        allowlist.activeBundleIDs.insert("com.avid.ProTools")
        #expect(allowlist.allowsActive("com.avid.ProTools"))
    }

    @Test("old JSON decodes as allow-all and a full value round-trips")
    func coding() throws {
        let encoder = KnowledgeCoding.makeEncoder(), decoder = KnowledgeCoding.makeDecoder()
        let allowlist = Allowlist(bundleIDs: ["com.avid.ProTools"], activeBundleIDs: ["com.avid.ProTools"], allowAll: false)
        #expect(try decoder.decode(Allowlist.self, from: try encoder.encode(allowlist)) == allowlist)
        let old = try decoder.decode(Allowlist.self, from: Data(#"{"bundleIDs":["com.x"]}"#.utf8))
        #expect(old.bundleIDs == ["com.x"])
        #expect(old.activeBundleIDs.isEmpty)
        #expect(old.allowAll)
        #expect(!old.allowDestructive)
    }
}
