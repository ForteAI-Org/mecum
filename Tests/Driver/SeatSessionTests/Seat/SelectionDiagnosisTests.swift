//
//  SelectionDiagnosisTests.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import CoreGraphics
import EngineCore
import Foundation
import ImageIO
import Perception
import PerceptionCore
import SeatCore
@testable import SeatDriving
@testable import SeatSession
import Testing

/// The dropdown selector's diagnosis: the typed reasons its branches give (on synthetic labels, the menu
/// of the S4 campaign as its message listed it, not a replay of what was perceived), and the session's
/// `SelectionDiagnostics` fed by the real selector on the controlled seat: the image the selector perceived
/// is the one written, a diagnosis is written per call, nothing is written when it is off, and a file that
/// cannot be written changes nothing the selection answers. No display, no application, no menu opened.
@MainActor
@Suite("Dropdown selection: why, and what was seen")
struct SelectionDiagnosisTests {

    /// Reads no text: every scene is empty, so the control never resolves.
    struct NoText: TextRecognizing {
        func recognizeText(in image: CGImage, accuracy: TextRecognitionAccuracy) throws -> [RecognizedText] { [] }
    }

    private static let menuFrame = CGRect(x: 0, y: 0, width: 120, height: 90)

    private static func menu(_ labels: [String]) -> (scene: SceneSnapshot, rows: [[SceneElement]]) {
        let elements = labels.enumerated().map { index, label in
            SceneElement(id: "row|\(index)", kind: .text, label: label,
                         bounds: NormalizedRect(x: 0.1, y: 0.05 + Double(index) * 0.3, width: 0.8, height: 0.2))
        }
        let scene = SceneSnapshot(bundleID: "x", appName: "X", windowTitle: "Dropdown",
                                  viewportPixelSize: ViewportPixelSize(width: 240, height: 180), elements: elements)
        return (scene, PopupRowPick.rows(in: scene, windowFrame: menuFrame, popupFrame: menuFrame))
    }

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mecum-select-diagnosis-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: The reasons, told apart

    @Test("the branches give distinct reasons: item not in the menu, item ambiguous, no route from the current value")
    func distinctReasons() throws {
        let (scene, rows) = Self.menu(["Alpha", "V Beta", "Gamma"])
        #expect(SeatDropdownSelector.menuItem("Delta", in: scene) == .failure(.itemNotResolved(matches: 0)))
        // The scene's resolution drops a leading token of one or two characters (`LabelText.coreKey`): an
        // item asked as "V Alpha" resolves to the Alpha row, so it ends where "Alpha" ends.
        #expect(try SeatDropdownSelector.menuItem("V Alpha", in: scene).get().label == "Alpha")
        let (twice, _) = Self.menu(["Alpha", "Beta", "Alpha"])
        #expect(SeatDropdownSelector.menuItem("Alpha", in: twice) == .failure(.itemNotResolved(matches: 2)))
        let alpha = try SeatDropdownSelector.menuItem("Alpha", in: scene).get()
        // No row reader: the painted rows decide, and the current value "Beta" is not one of them.
        #expect(SeatDropdownSelector.route(named: nil, painted: rows, currentValue: "Beta", target: alpha)
                == .failure(.routeNotPlanned(namedRows: nil, paintedRows: .currentValueNotAmongRows)))
        // A reader that named nothing says so beside the painted rows' reason.
        #expect(SeatDropdownSelector.route(named: [], painted: rows, currentValue: "Beta", target: alpha)
                == .failure(.routeNotPlanned(namedRows: .tooFewRows(0), paintedRows: .currentValueNotAmongRows)))
        // Named rows that carry the value plan the route, as before: one up.
        let named = ["Alpha", "Beta", "Gamma"].enumerated().map { PopupRow(title: $1, order: $0) }
        #expect(try SeatDropdownSelector.route(named: named, painted: rows, currentValue: "Beta", target: alpha).get().delta == -1)
        // The painted rows plan it when the value is read as they read it.
        #expect(try SeatDropdownSelector.route(named: nil, painted: rows, currentValue: "V Beta", target: alpha).get().delta == -1)
    }

    // MARK: The session's record, on the real selector

    /// The real selector on the controlled seat, with no text read: it captures `before` and stops at the
    /// control. `probe` is the session's, or nil for none.
    private static func select(_ target: SeatTarget, probe: SelectionProbe?) async throws -> SelectionResult {
        let selector = SeatDropdownSelector(target: target, pipeline: ScenePipeline(text: NoText()))
        do {
            let result = try await selector.select(
                control: "Probe choices", item: "Alpha",
                identity: ApplicationIdentity(bundleID: "test.dropdown", name: "Probe"),
                onMenu: { probe?.menuObserved($0) },
                onCapture: { probe?.capture($0, $1) }
            )
            probe?.finish(result)
            return result
        } catch {
            probe?.finish(error)
            throw error
        }
    }

    private struct Written: Decodable {
        let call: String
        let miss: String?
        let menu: String
        let namedRows: String
        let images: [String]
        let imagesNotCaptured: [String]
        let outcome: Outcome?
        let problems: [String]
        struct Outcome: Decodable { let kind: String; let message: String }
    }

    @Test("the image written is the one the selector perceived, with the call's diagnosis beside it")
    func theRealSampleIsWritten() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = SelectionDiagnostics(directory: directory)
        var perceived: CGImage?
        let probe = diagnostics.probe(callID: "CALL-1", control: "Probe choices", item: "Alpha", windowNumber: context.window.id)
        let selector = SeatDropdownSelector(target: context.target, pipeline: ScenePipeline(text: NoText()))
        let result = try await selector.select(
            control: "Probe choices", item: "Alpha", identity: ApplicationIdentity(bundleID: "test.dropdown", name: "Probe"),
            onCapture: { stage, image in perceived = image; probe.capture(stage, image) }
        )
        probe.finish(result)
        #expect(result.outcome.kind == .honestMiss)
        #expect(result.diagnosis.miss == .controlNotResolved(matches: 0))
        let folder = directory.appendingPathComponent("CALL-1")
        let source = try #require(CGImageSourceCreateWithURL(folder.appendingPathComponent("before.png") as CFURL, nil))
        let written = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let image = try #require(perceived)
        #expect(written.width == image.width && written.height == image.height, "the very sample, at its size")
        let record = try JSONDecoder().decode(Written.self, from: Data(contentsOf: folder.appendingPathComponent("diagnosis.json")))
        #expect(record.call == "CALL-1")
        #expect(record.miss == "controlNotResolved(matches: 0)")
        #expect(record.menu == "not read" && record.namedRows.hasPrefix("not read"))
        #expect(record.images == ["before.png"] && record.imagesNotCaptured == ["menu", "after"])
        #expect(record.outcome?.kind == "honest_miss" && record.outcome?.message == result.outcome.message)
    }

    @Test("off by default: the same answer and nothing written; two calls keep two folders")
    func offAndSeparated() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let off = try await Self.select(context.target, probe: nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path), "nothing written when off")
        let diagnostics = SelectionDiagnostics(directory: directory)
        let first = try await Self.select(context.target, probe: diagnostics.probe(callID: "A", control: "c", item: "i", windowNumber: nil))
        let second = try await Self.select(context.target, probe: diagnostics.probe(callID: "B", control: "c", item: "i", windowNumber: nil))
        #expect(off.outcome == first.outcome && first.outcome == second.outcome && off.diagnosis == first.diagnosis)
        let folders = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(folders == ["A", "B"])
        for name in folders {
            let record = try JSONDecoder().decode(Written.self, from: Data(contentsOf: directory.appendingPathComponent(name)
                .appendingPathComponent("diagnosis.json")))
            #expect(record.call == name)
        }
    }

    @Test("a diagnosis that cannot be written changes nothing the selection answers")
    func aWriteFailureIsOnlyDeclared() async throws {
        let context = try await BorrowedSeatTargetTests.borrowed()
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A file where the call's folder would go: the folder cannot be made.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: directory.appendingPathComponent("C").path, contents: Data()))
        let probe = SelectionDiagnostics(directory: directory).probe(callID: "C", control: "c", item: "i", windowNumber: nil)
        let reference = try await Self.select(context.target, probe: nil)
        let result = try await Self.select(context.target, probe: probe)
        #expect(result.outcome == reference.outcome && result.diagnosis == reference.diagnosis)
    }
}
