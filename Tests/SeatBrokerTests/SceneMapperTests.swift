//
//  SceneMapperTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 21/09/2026.
//

import CoreGraphics
import Foundation
import PerceptionCore
import struct SeatBroker.SceneElement
import Testing
@testable import SeatBroker

private func blankImage() -> CGImage {
    let ctx = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

@Test func mapsSceneElementsToIndexedObservation() {
    let snapshot = SceneSnapshot(
        bundleID         : "b",
        appName          : "App",
        windowTitle      : "T",
        viewportPixelSize: ViewportPixelSize(width: 100, height: 50),
        elements         : [
            PerceptionCore.SceneElement(id: "control|send", kind: .control, label: "Send",
                                        bounds: NormalizedRect(x: 0.5, y: 0.5, width: 0.2, height: 0.1),
                                        role: "AXButton", state: .off),
            PerceptionCore.SceneElement(id: "text|hi", kind: .text, label: "hi",
                                        bounds: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1)),
        ]
    )
    let observation = SceneMapper.observation(from: snapshot, image: blankImage())

    #expect(observation.elements.map(\.index) == [1, 2])
    #expect(observation.elements[0].label == "Send")
    // The aiming rule: an action lands on the centre of the element's
    // normalized bounds, in the pixels of the frame it was perceived on.
    let center = observation.elements[0].center(in: observation.pixelSize)
    #expect(abs(center.x - 60) < 1e-9)
    #expect(abs(center.y - 27.5) < 1e-9)
    #expect(observation.text.contains("[1] control/AXButton · Send [off]"))
    #expect(observation.token == snapshot.token.rawValue)
}

@Test func theMapNamesEveryPanelAndKeepsTheUnlabeledIconsTargetable() {
    // An unlabeled icon is an honest coverage gap, and it still gets an index:
    // the planner is told what it cannot name and can still click it.
    let sidebar = NormalizedRect(x: 0, y: 0, width: 0.3, height: 1)
    let snapshot = SceneSnapshot(
        bundleID         : "b",
        appName          : "App",
        windowTitle      : "T",
        viewportPixelSize: ViewportPixelSize(width: 100, height: 50),
        elements         : [
            PerceptionCore.SceneElement(id: "icon|0-0", kind: .icon, label: "(unlabeled)",
                                        bounds: NormalizedRect(x: 0.05, y: 0.1, width: 0.05, height: 0.05),
                                        isUnlabeled: true, section: "sidebar"),
            PerceptionCore.SceneElement(id: "text|loose", kind: .text, label: "loose",
                                        bounds: NormalizedRect(x: 0.8, y: 0.9, width: 0.1, height: 0.05)),
        ],
        sections         : [SceneSection(name: "sidebar", bounds: sidebar)]
    )
    let observation = SceneMapper.observation(from: snapshot, image: blankImage())

    #expect(observation.elements.map(\.index) == [1, 2])
    #expect(observation.text.contains("2 elements in 1 sections"))
    #expect(observation.text.contains("section: sidebar"))
    #expect(observation.text.contains("[1] icon · (unlabeled)"))
    #expect(observation.text.contains("section: unsectioned | 1 elements"))
    #expect(observation.text.contains("[2] text · loose"))
}

/// Two unlabeled elements in the same coarse cell carry the same Perception
/// identity, and a list keyed on it draws them as one row. `id` is the index,
/// which is unique by construction; `identity` still names what a before/after
/// reading matches on.
@Test func numbersElementsThatShareOneIdentityApart() {
    let snapshot = SceneSnapshot(
        bundleID         : "b",
        appName          : "App",
        windowTitle      : "T",
        viewportPixelSize: ViewportPixelSize(width: 100, height: 50),
        elements         : [
            PerceptionCore.SceneElement(id: "?|@2,0", kind: .icon, label: "(unlabeled)",
                                        bounds: NormalizedRect(x: 0.20, y: 0.1, width: 0.03, height: 0.05),
                                        isUnlabeled: true),
            PerceptionCore.SceneElement(id: "?|@2,0", kind: .icon, label: "(unlabeled)",
                                        bounds: NormalizedRect(x: 0.24, y: 0.1, width: 0.03, height: 0.05),
                                        isUnlabeled: true),
        ]
    )
    let elements = SceneMapper.observation(from: snapshot, image: blankImage()).elements

    #expect(Set(elements.map(\.id)).count == elements.count)
    #expect(elements.map(\.identity) == ["?|@2,0", "?|@2,0"])
}

@Test func mapsExactNativeTextAndSelection() throws {
    let value = "  Aé🧪\r\n"
    let selection = NSRange(location: 2, length: 4)
    let snapshot = SceneSnapshot(
        bundleID         : "fixture",
        appName          : "Fixture",
        windowTitle      : "Editor",
        viewportPixelSize: ViewportPixelSize(width: 100, height: 50),
        elements         : [PerceptionCore.SceneElement(
            id           : "control|editor",
            kind         : .control,
            label        : "Editor",
            bounds       : NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1),
            role         : "AXTextArea",
            value        : value,
            selectedRange: selection
        )]
    )
    let observation = SceneMapper.observation(from: snapshot, image: blankImage())
    let field = try #require(observation.elements.first)
    #expect(field.value == value)
    #expect(field.selectedRange == selection)
    #expect(observation.text.contains(String(reflecting: value)))
    #expect(observation.text.contains("[selection UTF-16: 2..6 of 8]"))
}

@Test func rejectsBrokerSelectionOutsideTheObservedText() {
    let field = SceneElement(
        index        : 1,
        identity     : "control|editor",
        kind         : "control",
        label        : "Editor",
        role         : "AXTextArea",
        state        : nil,
        value        : "A",
        selectedRange: NSRange(location: 0, length: Int.max),
        bounds       : CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1)
    )
    #expect(field.selectedRange == nil)
}
