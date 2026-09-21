import CoreGraphics
import SeatCore
import Testing
@testable import SeatBroker

@Test func parsesLabCommands() {
    #expect(SemanticAction.parse(command: "/click 3") == .click(element: 3))
    #expect(SemanticAction.parse(command: "/click 3 2") == .click(element: 3, count: 2))
    #expect(SemanticAction.parse(command: "/type 2 hello world") == .type(element: 2, text: "hello world"))
    #expect(SemanticAction.parse(command: "/scroll 4 -3") == .scroll(element: 4, deltaY: -3))
    #expect(SemanticAction.parse(command: "/key return") == .key(.return))
    #expect(SemanticAction.parse(command: "/key shift") == nil)
}

/// The rest of the line is the item's title: menu titles carry spaces, so a
/// split on the space would name a different item or none.
@Test func parsesAMenuChoiceByTitle() {
    #expect(SemanticAction.parse(command: "/menu 3 Copia") == .menu(element: 3, item: "Copia"))
    #expect(SemanticAction.parse(command: "/menu 3 Apri con") == .menu(element: 3, item: "Apri con"))
    #expect(SemanticAction.parse(command: "/menu 3") == nil)
    #expect(SemanticAction.parse(command: "/menu 0 Copia") == nil)
}

/// The history line the planner reads is verb, target and label, so a menu
/// action has to name the item there or the step says only which element.
@Test func aMenuActionNamesItsElementAndItsItem() {
    let action = SemanticAction.menu(element: 3, item: "Copia")
    #expect(action.verb == "menu")
    #expect(action.element == 3)
    #expect(action.targetDescription == "[3] \"Copia\"")
}

/// The seam: a menu action is one scoped interaction and never a succession of
/// Commands, so the executor refuses it instead of inventing inputs for it.
@Test func theExecutorHasNoInputsForAMenuAction() {
    #expect(throws: SeatBrokerError.self) {
        try ActionExecutor.inputs(for: .menu(element: 1, item: "Copia"),
                                  in: emptyScene, frame: anyFrame)
    }
}

@Test func parsesShortcuts() {
    #expect(SemanticAction.parse(command: "/key cmd+c") == .key(.c, modifiers: .command))
    #expect(SemanticAction.parse(command: "/key CMD+Shift+N") == .key(.n, modifiers: [.command, .shift]))
    #expect(SemanticAction.parse(command: "/key ⌘⇧a") == .key(.a, modifiers: [.command, .shift]))
    #expect(SemanticAction.parse(command: "/key ctrl+opt+left") == .key(.left, modifiers: [.control, .option]))
    // A written modifier that is not one, and a key that is not one.
    #expect(SemanticAction.parse(command: "/key meta+c") == nil)
    #expect(SemanticAction.parse(command: "/key cmd+f13") == nil)
    #expect(SemanticAction.parse(command: "/key cmd") == nil)
    #expect(SemanticAction.key(.c, modifiers: .command).targetDescription == "cmd+c")
}

/// A key press needs neither, but the signature does: both are untouched on
/// that path, so the emptiest pair that constructs is the honest one.
private let emptyScene = SceneObservation(
    image: CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                     space: CGColorSpaceCreateDeviceRGB(),
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!,
    elements: [], text: "", token: "t")

private let anyFrame = FrameGeometryObservation(
    source: .window(WindowIdentity(
        process: ProcessIdentity(processID: 42, serialNumberHigh: 1, serialNumberLow: 2),
        windowNumber: 1,
        ownerConnectionID: 3
    )),
    screenRect: CGRect(x: 0, y: 0, width: 100, height: 100),
    contentRectInSurface: CGRect(x: 0, y: 0, width: 100, height: 100),
    scaleFactor: 1, contentScale: 1, pixelSize: CGSize(width: 100, height: 100),
    version: GeometryObservationVersion(observerGeneration: 1, sequence: 1),
    capturesFullWindow: true)

@Test func delegatesCharacterShortcutsToMecum() throws {
    let action = try #require(SemanticAction.parse(command: "/key cmd+shift+g"))
    #expect(try ActionExecutor.inputs(for: action, in: emptyScene, frame: anyFrame)
            == [.shortcut(.character("g", holding: [.command, .shift]))])
}

@Test(arguments: KeyName.allCases.filter { $0.rawValue.count == 1 })
func everyLetterKeepsItsSemanticIdentity(key: KeyName) throws {
    let character = try #require(key.rawValue.first)
    #expect(try ActionExecutor.inputs(for: .key(key, modifiers: [.control, .option]),
                                     in: emptyScene, frame: anyFrame)
            == [.shortcut(.character(character, holding: [.control, .option]))])
}

@Test(arguments: [(KeyName.return, "Enter"), (.escape, "Escape"), (.tab, "Tab"),
                  (.space, "Space"), (.delete, "Backspace"), (.up, "ArrowUp"),
                  (.down, "ArrowDown"), (.left, "ArrowLeft"), (.right, "ArrowRight")])
func controlsUseMecumsPhysicalKeyTable(fixture: (KeyName, String)) throws {
    let physical = try #require(KeyNames.key(named: fixture.1))
    #expect(try ActionExecutor.inputs(for: .key(fixture.0), in: emptyScene, frame: anyFrame)
            == [.shortcut(.physical(physical))])
}

@Test func typingIsTwoObservationBoundCommands() throws {
    let scene = SceneObservation(image: emptyScene.image, elements: [
        SceneElement(index: 1, id: "field", kind: "control", label: "Name", role: "AXTextField",
                     state: nil, bounds: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.2)),
    ], text: "", token: "field")

    let inputs = try ActionExecutor.inputs(for: .type(element: 1, text: "hello"),
                                           in: scene, frame: anyFrame)

    #expect(inputs.count == 2)
    guard case .command(.click) = inputs[0] else {
        Issue.record("typing must first focus the observed field")
        return
    }
    #expect(inputs[1] == .command(.insertText("hello")))
}

@Test func rejectsMalformedCommands() {
    #expect(SemanticAction.parse(command: "hello") == nil)
    #expect(SemanticAction.parse(command: "/click") == nil)
    #expect(SemanticAction.parse(command: "/click 0") == nil)
    #expect(SemanticAction.parse(command: "/click 2 extra") == nil)
    #expect(SemanticAction.parse(command: "/click 2 0") == nil)
    #expect(SemanticAction.parse(command: "/click 2 \(InputCommand.maximumClickCount + 1)") == nil)
    #expect(SemanticAction.parse(command: "/type 2") == nil)
    #expect(SemanticAction.parse(command: "/scroll 1 up") == nil)
}
