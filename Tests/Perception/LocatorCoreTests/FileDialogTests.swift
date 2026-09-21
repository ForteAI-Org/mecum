import XCTest
@testable import LocatorCore

final class FileDialogTests: XCTestCase {
    private func el(_ label: String) -> SceneElement {
        SceneElement(id: "?|\(label)", kind: "text", label: label, pos: [0.1, 0.1, 0.1, 0.05])
    }

    private func scene(title: String, labels: [String]) -> SceneSnapshot {
        SceneSnapshot(bundleID: "com.forte-ai.aafchecker", app: "AAF Checker by Forte AI",
                      windowTitle: title, viewportPx: [1200, 800],
                      elements: labels.map(el), commands: [])
    }

    /// The real failure: AAF Checker's Open panel, the labels the log actually showed (truncation and all).
    func testTheAAFCheckerPanelIsRecognised() {
        let s = scene(title: "Open", labels: ["Cancel", "Open", "Desktop", "Applicatio…", "Avid MediaFiles",
                                             "IVUTUEUVVUCULULNUVUVH", "eval-resolve"])
        let hit = FileDialog.detect(s)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.confirm, "Open")
        // The orientation names all three escapes the failing session was never told about.
        let line = FileDialog.orientation(hit!)
        XCTAssertTrue(line.contains("go_to_folder"))
        XCTAssertTrue(line.contains("list_files"))
        XCTAssertTrue(line.contains("make_folder"))
    }

    /// No title to lean on — the standard-places sidebar corroborates instead.
    func testUntitledPanelCorroboratedBySidebar() {
        let s = scene(title: "", labels: ["Cancel", "Import", "Documents", "some-file.wav"])
        let hit = FileDialog.detect(s)
        XCTAssertEqual(hit?.confirm, "Import")
        XCTAssertEqual(hit?.corroboration, "a standard-places sidebar (“Documents”)")
    }

    func testItalianPanel() {
        XCTAssertNotNil(FileDialog.detect(scene(title: "Apri", labels: ["Annulla", "Apri", "Scrivania"])))
    }

    /// Both buttons but nothing corroborating: NOT claimed. An app with a Cancel and a Save is just a
    /// dialog, and a false orientation line is noise on every scene it fires on.
    func testCancelAndSaveAloneIsNotAPanel() {
        XCTAssertNil(FileDialog.detect(scene(title: "Preferences", labels: ["Cancel", "Save", "Bit Depth"])))
    }

    /// A confirmation sheet ("… already exists. Replace?") must not read as a file panel.
    func testReplaceSheetIsNotAPanel() {
        XCTAssertNil(FileDialog.detect(scene(title: "", labels: ["Cancel", "Replace",
                                                                "“Timeline 1.aaf” already exists."])))
    }

    /// Truncation is tolerated; a two-letter stub is not.
    func testTruncationFloor() {
        XCTAssertTrue(FileDialog.isStandardPlace("Applicatio…"))
        XCTAssertTrue(FileDialog.isStandardPlace("Downl..."))
        XCTAssertFalse(FileDialog.isStandardPlace("Do"))
        XCTAssertFalse(FileDialog.isStandardPlace("li"))
        XCTAssertFalse(FileDialog.isStandardPlace("Avid MediaFiles"))
    }
}
