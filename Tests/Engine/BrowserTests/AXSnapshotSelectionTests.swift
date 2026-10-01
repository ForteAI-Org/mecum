import BrowserCore
import Testing
@testable import ChromeBrowser

@MainActor
struct AXSnapshotSelectionTests {
    private func row(_ id: String, _ role: String, _ name: String, children: [String] = []) -> CDPValue {
        .object([
            "nodeId": .string(id), "backendDOMNodeId": .number(Double(id) ?? 1),
            "role": .object(["value": .string(role)]), "name": .object(["value": .string(name)]),
            "childIds": .array(children.map(CDPValue.string))
        ])
    }

    @Test func dialogIsSelectedBeforeLimitAndBackgroundIsNotPresentedAsAbsent() throws {
        let background = (1...450).map { row(String($0), "button", "Background \($0)") }
        let tree = AXSnapshotSelection(frames: [("main", background + [
            row("500", "dialog", "Schedule", children: ["501", "503"]),
            row("501", "button", "Confirm", children: ["502"]),
            row("502", "StaticText", "Confirm"), row("503", "StaticText", "Will send tomorrow")
        ])])
        let selection = try tree.select(BrowserObservationOptions())
        #expect(selection.scope == "dialog")
        #expect(selection.entries.map(\.name) == ["Schedule", "Confirm", "Will send tomorrow"])
        #expect(selection.limitations.contains { $0.contains("omitted") })
        #expect(!selection.limitations.contains { $0.contains("Truncated") })
    }

    @Test func identicalLabelsInDifferentControlsStayDistinct() throws {
        let tree = AXSnapshotSelection(frames: [("main", [
            row("1", "button", "Create", children: ["2"]), row("2", "StaticText", "Create"),
            row("3", "StaticText", "Create"), row("4", "button", "Create")
        ])])
        let selection = try tree.select(BrowserObservationOptions(scope: .page))
        #expect(selection.entries.map(\.key) == ["main:1", "main:3", "main:4"])
    }

    @Test func ambiguousDialogsRequireExplicitReadingInsteadOfChoosingOne() throws {
        let tree = AXSnapshotSelection(frames: [("main", [row("1", "dialog", "First"), row("2", "dialog", "Second")])])
        let automatic = try tree.select(BrowserObservationOptions())
        #expect(automatic.scope == "page")
        #expect(automatic.entries.count == 2)
        #expect(automatic.limitations.contains { $0.contains("Multiple dialogs") })
        #expect(throws: BrowserFailure.self) { try tree.select(BrowserObservationOptions(scope: .dialog)) }
    }

    @Test func contentKeepsArticleLinksAndQueryCanFindLateNodes() throws {
        let tree = AXSnapshotSelection(frames: [("main", [
            row("1", "button", "Navigation"),
            row("2", "article", "Synthetic article", children: ["3", "4"]),
            row("3", "link", "Article permalink"), row("4", "button", "Like"),
            row("5", "button", "Target")
        ])])
        let content = try tree.select(BrowserObservationOptions(scope: .content))
        #expect(content.entries.map(\.name) == ["Synthetic article", "Article permalink"])
        let filtered = try tree.select(BrowserObservationOptions(scope: .page, query: "Target", limit: 1))
        #expect(filtered.entries.map(\.name) == ["Target"])
        #expect(filtered.limitations.contains { $0.contains("Filtered") })
    }

    @Test func unnamedArticlesKeepBodyTextWithoutBringingBackReactionControls() throws {
        let tree = AXSnapshotSelection(frames: [("main", [
            row("1", "article", "", children: ["2", "3"]),
            row("2", "StaticText", "Actual article body"),
            row("3", "button", "Like", children: ["4"]), row("4", "StaticText", "Like")
        ])])
        let content = try tree.select(BrowserObservationOptions(scope: .content))
        #expect(content.entries.map(\.name) == ["", "Actual article body"])
    }

    @Test func typedFieldTextIsNotAnOptionAndCannotReappearInAFilteredReading() throws {
        let tree = AXSnapshotSelection(frames: [("main", [
            row("1", "combobox", "Destination", children: ["2", "3"]),
            row("2", "StaticText", "Southhaven"),
            row("3", "listbox", "Suggestions", children: ["4"]),
            row("4", "option", "Southhaven (SHV)", children: ["5"]),
            row("5", "StaticText", "Southhaven (SHV)")
        ])])
        for options in [BrowserObservationOptions(), .init(scope: .content), .init(query: "Southhaven")] {
            let selected = try tree.select(options)
            #expect(!selected.entries.contains { $0.key == "main:2" })
        }
        let selected = try tree.select(.init())
        #expect(selected.entries.contains { $0.role == "option" && $0.name == "Southhaven (SHV)" })
    }

    @Test func aPageTitleMatchDoesNotExpandEveryNodeIntoAQueryResult() throws {
        let tree = AXSnapshotSelection(frames: [("main", [
            row("1", "RootWebArea", "Flights from Torino", children: ["2", "3"]),
            row("2", "button", "Torino (TRN)"), row("3", "button", "Unrelated hotels")
        ])])
        let selected = try tree.select(.init(query: "Torino"))
        #expect(selected.entries.map(\.name) == ["Torino (TRN)"])
    }

    @Test func truncationAndShortenedLabelsAreReported() throws {
        let tree = AXSnapshotSelection(frames: [("main", [row("1", "article", String(repeating: "x", count: 600)), row("2", "button", "Next")])])
        let selected = try tree.select(BrowserObservationOptions(scope: .page, limit: 1))
        #expect(selected.limitations.contains { $0.contains("Truncated") })
        #expect(selected.limitations.contains { $0.contains("512") })
    }
}
