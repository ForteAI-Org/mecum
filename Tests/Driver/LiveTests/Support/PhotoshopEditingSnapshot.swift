//
//  PhotoshopEditingSnapshot.swift
//  AgentSeatKit
//

import CoreGraphics
import Foundation

/// PhotoshopEditingSnapshot reads a complete native model of one owned document.
/// A fresh nonce and footer exclude stale or partly written fixture output.
nonisolated struct PhotoshopEditingSnapshot {

    enum Failure: Error, Equatable {
        case invalidSnapshot
    }

    let documentID     : Int
    let layerCount     : Int
    let activeLayerName: String
    let canvas         : CGRect
    let selection      : CGRect?
    let histogram      : [Int]
    let historyCount   : Int
    let historyName    : String

    init(parsing source: String, token: String, documentID expected: Int) throws {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count == 2, lines.last == "MECUM_DONE\t\(token)" else {
            throw Failure.invalidSnapshot
        }
        let fields = lines[0].split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 11, fields[0] == "MECUM_EDITING", fields[1] == token,
              let documentID = Int(fields[2]), documentID == expected, documentID > 0,
              let layerCount = Int(fields[3]), layerCount > 0,
              let width = Double(fields[4]), width.isFinite, width > 0,
              let height = Double(fields[5]), height.isFinite, height > 0,
              let activeLayerName = String(fields[6]).removingPercentEncoding,
              !activeLayerName.isEmpty,
              let historyCount = Int(fields[9]), historyCount > 0,
              let historyName = String(fields[10]).removingPercentEncoding, !historyName.isEmpty
        else { throw Failure.invalidSnapshot }

        let selection: CGRect?
        if fields[7] == "none" {
            selection = nil
        } else {
            let components = fields[7].split(separator: ",", omittingEmptySubsequences: false)
            let coordinates = components.compactMap { Double($0) }
            guard components.count == 4, coordinates.count == 4, coordinates.allSatisfy(\.isFinite),
                  coordinates[2] > coordinates[0], coordinates[3] > coordinates[1]
            else { throw Failure.invalidSnapshot }
            selection = CGRect(
                x     : coordinates[0],
                y     : coordinates[1],
                width : coordinates[2] - coordinates[0],
                height: coordinates[3] - coordinates[1]
            )
        }

        let bins = fields[8].split(separator: ",", omittingEmptySubsequences: false)
        let histogram = bins.compactMap { Int($0) }
        guard bins.count == 256, histogram.count == 256, histogram.allSatisfy({ $0 >= 0 }) else {
            throw Failure.invalidSnapshot
        }
        self.documentID = documentID
        self.layerCount = layerCount
        self.activeLayerName = activeLayerName
        self.canvas = CGRect(x: 0, y: 0, width: width, height: height)
        self.selection = selection
        self.histogram = histogram
        self.historyCount = historyCount
        self.historyName = historyName
    }
}
