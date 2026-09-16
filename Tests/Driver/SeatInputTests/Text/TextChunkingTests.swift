//
//  TextChunkingTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 14/09/2026.
//

import SeatCore
@testable import SeatInput
import Testing

@Suite("Text chunking")
struct TextChunkingTests {

    static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"  // 1 cluster, 8 code units
    static let flag   = "\u{1F1EE}\u{1F1F9}"                            // 1 cluster, 4 code units
    static let accent = "e\u{301}"                                      // 1 cluster, 2 code units

    private func chunks(
        _ text   : String,
        clusters : Int = 8,
        codeUnits: Int = 64
    ) throws -> [String] {
        try TextChunking.chunks(
            of              : text,
            maximumClusters : clusters,
            maximumCodeUnits: codeUnits
        )
    }

    @Test("the pieces put the original back together exactly")
    func chunksAreLossless() throws {
        let text = "agentseat " + Self.family + Self.flag + " " + Self.accent + " coda"

        #expect(try chunks(text, clusters: 3).joined() == text)
    }

    @Test("no piece is ever longer than either bound")
    func chunksRespectBothBounds() throws {
        let text   = String(repeating: Self.family, count: 9)
        let pieces = try chunks(text, clusters: 4, codeUnits: 16)

        // Four clusters would be thirty two code units, so the code unit bound
        // is the one that bites: two clusters a piece, and a remainder of one.
        #expect(pieces.allSatisfy { $0.count <= 4 })
        #expect(pieces.allSatisfy { $0.utf16.count <= 16 })
        #expect(pieces.dropLast().allSatisfy { $0.count == 2 })
        #expect(pieces.map(\.count) == [2, 2, 2, 2, 1])
    }

    @Test("a joined emoji is never cut in half")
    func joinedSequencesStayWhole() throws {
        let pieces = try chunks(String(repeating: Self.family, count: 5), clusters: 2)

        // Every piece is whole families and nothing else. A cut inside one
        // would leave a lone man, a lone woman and a stray joiner.
        #expect(pieces.joined() == String(repeating: Self.family, count: 5))
        #expect(pieces.allSatisfy { $0.unicodeScalars.first != "\u{200D}" })
        #expect(pieces.map(\.count) == [2, 2, 1])
    }

    @Test("a flag is never split into two regional indicators")
    func flagsStayWhole() throws {
        let pieces = try chunks(String(repeating: Self.flag, count: 3), clusters: 1)

        #expect(pieces == [Self.flag, Self.flag, Self.flag])
    }

    @Test("a combining mark is never orphaned from its base")
    func combiningMarksStayWithTheirBase() throws {
        let pieces = try chunks(String(repeating: Self.accent, count: 3), clusters: 1)

        #expect(pieces == [Self.accent, Self.accent, Self.accent])
        #expect(pieces.allSatisfy { $0.utf16.count == 2 })
    }

    @Test("a cluster that does not fit alone is refused, not split")
    func oversizedClusterRefuses() {
        // The family is eight code units and the bound is four. Splitting it
        // would produce different text, so nothing is delivered at all.
        #expect(throws: InputFailure.textClusterTooLarge(codeUnits: 8, maximum: 4)) {
            try chunks(Self.family, codeUnits: 4)
        }
    }

    @Test("an empty string is refused rather than delivered as nothing")
    func emptyTextRefuses() {
        #expect(throws: InputFailure.emptyText) { try chunks("") }
    }

    @Test("a bound that describes no possible chunk is refused", arguments: [
        (0, 64), (8, 0), (-1, -1),
    ])
    func impossibleBoundsRefuse(clusters: Int, codeUnits: Int) {
        #expect(throws: InputFailure.invalidTextLimit(clusters: clusters, codeUnits: codeUnits)) {
            try chunks("agentseat", clusters: clusters, codeUnits: codeUnits)
        }
    }

    @Test("a string that fits is one piece and not many")
    func shortTextIsOnePiece() throws {
        // Nine clusters against the sixteen asked for here. The suite default
        // is eight, which this string does not fit in.
        #expect(try chunks("agentseat", clusters: 16) == ["agentseat"])
    }

    @Test("the cluster bound is what bites on plain text")
    func clusterBoundBitesOnASCII() throws {
        #expect(try chunks("abcdefghij", clusters: 4) == ["abcd", "efgh", "ij"])
    }
}
