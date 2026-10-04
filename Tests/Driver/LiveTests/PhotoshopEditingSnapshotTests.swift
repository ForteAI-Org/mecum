//
//  PhotoshopEditingSnapshotTests.swift
//  AgentSeatKit
//

import CoreGraphics
import Foundation
import Testing

@Suite("Scoped Photoshop editing snapshots")
struct PhotoshopEditingSnapshotTests {

    private func snapshot(
        token    : String = "fresh",
        id       : Int = 9,
        selection: String = "0,0,40,30",
        histogram: String? = nil,
        history  : String = "2\tInvert"
    ) -> String {
        let bins = histogram ?? Array(repeating: "0", count: 255).joined(separator: ",") + ",1200"
        return "MECUM_EDITING\t\(token)\t\(id)\t1\t40\t30\tLayer%20%C3%A8\t\(selection)\t\(bins)\t\(history)\nMECUM_DONE\t\(token)"
    }

    @Test("selection and pixels come from the exact complete owned document")
    func readsEditingState() throws {
        let reading = try PhotoshopEditingSnapshot(parsing: snapshot(), token: "fresh", documentID: 9)
        #expect(reading.documentID == 9)
        #expect(reading.activeLayerName == "Layer è")
        #expect(reading.selection == reading.canvas)
        #expect(reading.histogram[255] == 1200)
        #expect(reading.historyCount == 2 && reading.historyName == "Invert")
        #expect(try PhotoshopEditingSnapshot(
            parsing   : snapshot(selection: "none"),
            token     : "fresh",
            documentID: 9
        ).selection == nil)
    }

    @Test("another document, stale output and a missing footer cannot prove an effect")
    func refusesUnownedSnapshots() {
        let invalid = [snapshot(token: "old"), snapshot(id: 4),
                       snapshot().components(separatedBy: "\n")[0], snapshot() + "\nextra"]
        for source in invalid {
            #expect(throws: PhotoshopEditingSnapshot.Failure.invalidSnapshot) {
                try PhotoshopEditingSnapshot(parsing: source, token: "fresh", documentID: 9)
            }
        }
    }

    @Test("malformed geometry and incomplete pixel bins cannot become empty selection")
    func refusesInvalidEditingState() {
        let invalid = [snapshot(selection: "0,0,nan,30"), snapshot(selection: "0,0,0,30"),
                       snapshot(selection: "0,0,40"), snapshot(selection: "0,0,bad,40,30"),
                       snapshot(histogram: "0,1,2"), snapshot(history: "0\tInvert"),
                       snapshot(history: "2\t"), snapshot(history: "bad\tInvert"),
                       snapshot(histogram: Array(repeating: "-1", count: 256).joined(separator: ","))]
        for source in invalid {
            #expect(throws: PhotoshopEditingSnapshot.Failure.invalidSnapshot) {
                try PhotoshopEditingSnapshot(parsing: source, token: "fresh", documentID: 9)
            }
        }
    }
}
