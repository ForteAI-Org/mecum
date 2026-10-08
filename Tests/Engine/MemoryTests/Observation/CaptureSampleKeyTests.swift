//
//  CaptureSampleKeyTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 02/10/2026.
//

@testable import Memory
import Testing

/// A sample's key is its identity in the file: the event id's bytes, the phase and the ordinal. Two
/// canonically equivalent ids are two keys, as they are two rows; nothing is normalized.
@Suite("A capture sample's key is its bytes")
struct CaptureSampleKeyTests {

    @Test("canonically equivalent event ids are two keys in a set and a dictionary; a key built again from the same bytes is the same key; phase and ordinal each tell keys apart")
    func keysAreBytes() {
        let composed = "café", decomposed = "cafe\u{301}"
        #expect(composed == decomposed && Array(composed.utf8) != Array(decomposed.utf8), "Swift's String equality would make these one key")
        func keys(_ id: String) -> [CaptureSampleKey] {
            [CaptureSampleKey(eventID: id, phase: .after), CaptureSampleKey(eventID: id, phase: .before),
             CaptureSampleKey(eventID: id, phase: .after, ordinal: 1), CaptureSampleKey(eventID: id, phase: .menu),
             CaptureSampleKey(eventID: id, phase: .current)]
        }
        let all = keys(composed) + keys(decomposed)
        for (i, lhs) in all.enumerated() {
            for (j, rhs) in all.enumerated() {
                #expect((lhs == rhs) == (i == j), Comment(rawValue: "\(i) against \(j)"))
            }
        }
        #expect(Set(all).count == 10)
        #expect(Set(all + keys("caf" + "é") + keys("cafe" + "\u{301}")).count == 10, "a key built again from the same bytes is the same key")
        var indexed: [CaptureSampleKey: Int] = [:]
        for (index, key) in all.enumerated() { indexed[key] = index }
        #expect(indexed.count == 10 && indexed[CaptureSampleKey(eventID: decomposed, phase: .after)] == 5)
        #expect(indexed[CaptureSampleKey(eventID: composed, phase: .after)] == 0)
    }
}
