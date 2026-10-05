//
//  SelectionDiagnostics.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import ImageIO
import SeatCore
import SeatSession
import UniformTypeIdentifiers

/// SelectionDiagnostics is a developer's record of the dropdown selections of a session: for each call,
/// the images the selector actually perceived (`before`, `menu`, `after`, through its `onCapture`) and a
/// `diagnosis.json` with the call, the windows, the outcome, the typed miss, the opener's label, the menu's
/// labels and the rows as the application named them and as the pixels painted them. It is off unless a
/// caller makes one with a directory; nothing it writes reaches the memory, a tool's arguments or the
/// outcome. A step that did not run, a menu that was not read, rows that were not named are written as
/// such: nothing is captured again or reconstructed. A file it cannot write is said in the diagnosis and
/// never stops the selection.
@MainActor
public final class SelectionDiagnostics {

    /// Where every call's folder goes, one folder per call named by its event id.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The probe for one selection call.
    public func probe(callID: String, control: String, item: String, windowNumber: Int?) -> SelectionProbe {
        SelectionProbe(folder: directory.appendingPathComponent(Self.folderName(callID), isDirectory: true),
                       callID: callID, control: control, item: item, windowNumber: windowNumber)
    }

    /// A call id as one path component, so a call can never write outside its folder.
    static func folderName(_ callID: String) -> String {
        let kept = callID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" }
        return kept.isEmpty ? "call" : String(kept)
    }
}

/// SelectionProbe collects one selection's diagnosis: hand `capture` and `menuObserved` to the selector,
/// then `finish` with its result or its error, once.
@MainActor
public final class SelectionProbe {

    let folder: URL
    private let callID: String
    private let control: String
    private let item: String
    private let windowNumber: Int?
    private var images: [String] = []
    private var menuWindows: [Int] = []
    private var problems: [String] = []
    private var finished = false

    init(folder: URL, callID: String, control: String, item: String, windowNumber: Int?) {
        self.folder       = folder
        self.callID       = callID
        self.control      = control
        self.item         = item
        self.windowNumber = windowNumber
    }

    /// The selector's `onCapture`: writes the image the selector is about to perceive as `<stage>.png`.
    /// A write that fails is noted and the selection goes on.
    public func capture(_ stage: String, _ image: CGImage) {
        let name = SelectionDiagnostics.folderName(stage) + ".png"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            images.append(name)
        } catch {
            problems.append("\(name) not written: \(error)")
        }
    }

    /// The selector's `onMenu`: the menu window it is reading.
    public func menuObserved(_ menu: ContextMenu) {
        menuWindows.append(menu.window.windowNumber)
    }

    /// Writes the diagnosis of a selection that answered.
    public func finish(_ result: SelectionResult) {
        write(outcome: Record.Outcome(kind: result.outcome.kind.rawValue, message: result.outcome.message),
              diagnosis: result.diagnosis, receiptMenuWindow: result.receipt?.menu.window.windowNumber,
              selectionRequested: result.receipt?.selectionRequested, error: nil)
    }

    /// Writes the diagnosis of a selection that threw: the error, and what was captured before it.
    public func finish(_ error: any Error) {
        write(outcome: nil, diagnosis: nil, receiptMenuWindow: nil, selectionRequested: nil, error: String(describing: error))
    }

    private func write(outcome: Record.Outcome?, diagnosis: SelectionDiagnosis?, receiptMenuWindow: Int?,
                       selectionRequested: Bool?, error: String?) {
        guard !finished else { return }
        finished = true
        let read: (Bool) -> String = { $0 ? "read" : "not read" }
        let record = Record(
            call: callID, control: control, item: item, window: windowNumber,
            menuWindowsObserved: menuWindows, menuWindowOfReceipt: receiptMenuWindow,
            selectionRequested: selectionRequested, outcome: outcome, error: error,
            miss: diagnosis?.miss.map(Record.describe), opener: diagnosis?.openerLabel,
            openerSource: diagnosis?.openerSource?.rawValue, menuPath: diagnosis?.menuPath?.rawValue,
            menu: read(diagnosis?.menuLabels != nil), menuLabels: diagnosis?.menuLabels,
            namedRows: diagnosis?.namedRows == nil ? "not read: no row reader in this path" : "read",
            namedRowTitles: diagnosis?.namedRows,
            paintedRows: diagnosis?.paintedRows, route: diagnosis?.route,
            images: images,
            imagesNotCaptured: ["before", "menu", "after"].filter { !images.contains("\($0).png") },
            problems: problems
        )
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: folder.appendingPathComponent("diagnosis.json"), options: .atomic)
        } catch {
            // Nowhere else to say it without touching the outcome: the standard error of the process.
            FileHandle.standardError.write(Data("select diagnostics: \(folder.path) not written: \(error)\n".utf8))
        }
    }

    /// The JSON record of one call.
    struct Record: Encodable {
        struct Outcome: Encodable {
            let kind: String
            let message: String
        }
        let call: String
        let control: String
        let item: String
        let window: Int?
        let menuWindowsObserved: [Int]
        let menuWindowOfReceipt: Int?
        let selectionRequested: Bool?
        let outcome: Outcome?
        let error: String?
        let miss: String?
        let opener: String?
        let openerSource: String?
        let menuPath: String?
        let menu: String
        let menuLabels: [String]?
        let namedRows: String
        let namedRowTitles: [String]?
        let paintedRows: [[String]]?
        let route: String?
        let images: [String]
        let imagesNotCaptured: [String]
        let problems: [String]

        static func describe(_ miss: SelectionMiss) -> String {
            switch miss {
                case .controlNotResolved(let matches): "controlNotResolved(matches: \(matches))"
                case .itemNotResolved(let matches)   : "itemNotResolved(matches: \(matches))"
                case .routeNotPlanned(let named, let painted):
                    "routeNotPlanned(namedRows: \(named.map { "\($0)" } ?? "no reader"), paintedRows: \(painted))"
                case .menuNotRead                    : "menuNotRead"
                case .selectionNotRequested          : "selectionNotRequested"
            }
        }
    }
}
