//
//  TargetPlatformTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/09/2026.
//

import CoreGraphics
import Foundation
import SeatCore
import SeatInput
import Testing
@testable import SeatBroker

/// The choice on its own: a bundle URL and an identifier in, a platform and
/// the rule that decided it out. No running application, no seat, no window.
@Suite("The platform one application is driven with")
struct TargetPlatformTests {

    /// A bundle on disk with the frameworks the rule looks for, and nothing
    /// else: the reading is a file existence check, so the files are what a
    /// row has to provide.
    private static func bundle(embedding frameworks: [String] = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Row.app")
        let container = url.appendingPathComponent("Contents/Frameworks")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        for framework in frameworks {
            try FileManager.default.createDirectory(
                at: container.appendingPathComponent(framework),
                withIntermediateDirectories: true
            )
        }
        return url
    }

    @Test("Finder is a native application and is driven without preparing its own state")
    func appleApplicationIsAppKit() throws {
        // The case that hurt: every left click on Finder was prepared with the
        // recipe that makes it believe it is active, and the person lost focus.
        let choice = TargetPlatform.chosen(
            bundleURL       : URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            bundleIdentifier: "com.apple.finder"
        )
        #expect(choice == .appleNative)
        #expect(choice.platform is AppKitPlatform)
    }

    @Test("an embedded renderer is the measurement's own case and keeps the Chromium recipe")
    func electronApplicationIsChromium() throws {
        let electron = try Self.bundle(embedding: ["Electron Framework.framework"])
        let choice = TargetPlatform.chosen(
            bundleURL       : electron,
            bundleIdentifier: "com.tinyspeck.slackmacgap"
        )
        #expect(choice == .embeddedRenderer(.framework))
        #expect(choice.platform is ChromiumPlatform)

        let cef = try Self.bundle(embedding: ["Chromium Embedded Framework.framework"])
        #expect(TargetPlatform.chosen(bundleURL: cef, bundleIdentifier: "com.example.cef")
            == .embeddedRenderer(.framework))
    }

    @Test("a bundle that ships Qt is driven with the Qt recipe, whichever way it ships it")
    func qtApplicationIsQt() throws {
        // DaVinci Resolve ships Qt 5 as dylibs; a `macdeployqt` bundle ships the framework.
        for library in ["libQt5Core.5.dylib", "libQt6Core.6.dylib", "QtCore.framework"] {
            let bundle = try Self.bundle(embedding: [library])
            let choice = TargetPlatform.chosen(
                bundleURL       : bundle,
                bundleIdentifier: "com.blackmagic-design.DaVinciResolve"
            )
            #expect(choice == .qtToolkit, "\(library)")
            #expect(choice.platform is QtPlatform)
        }

        // A Chromium renderer inside a Qt application is still the renderer.
        let both = try Self.bundle(embedding: ["Chromium Embedded Framework.framework", "QtCore.framework"])
        #expect(TargetPlatform.chosen(bundleURL: both, bundleIdentifier: "com.example.both") == .embeddedRenderer(.framework))
    }

    @Test("a bundle that ships Adobe's UXP host prepares keys only for its leaf modals, and never clicks")
    func uxpApplicationPreparesKeysOnly() throws {
        // Photoshop 2026 ships the host as `Contents/Frameworks/dvauxphost.framework`.
        let bundle = try Self.bundle(embedding: ["dvauxphost.framework"])
        let choice = TargetPlatform.chosen(bundleURL: bundle, bundleIdentifier: "com.adobe.Photoshop")
        #expect(choice == .adobeUXP)

        let platform = choice.platform
        let point    = InputLocation(screenPoint: .zero, windowPointFromTop: .zero)
        let key      = InputCommand.key(virtualKey: 36, text: "\r")
        #expect(platform is UXPPlatform)
        // A prepared Escape to the document window crashed Photoshop on 30/09/2026.
        #expect(platform.preparation(for: key) == .none)
        let leaf = try #require((platform as? UXPPlatform)?.preparingKeys)
        #expect(leaf.preparation(for: .click(point, count: 1)) == .none)
        #expect(leaf.preparation(for: key) == .internalAppKitState)
        #expect(leaf.preparation(for: .text("mecum")) == .internalAppKitState)
    }

    @Test("Photoshop's measured document clicks are enabled only on an attested UXP host")
    func photoshopDocumentRecipe() throws {
        let bundle = try Self.bundle(embedding: ["dvauxphost.framework"])
        let choice = TargetPlatform.chosen(bundleURL: bundle, bundleIdentifier: "com.adobe.Photoshop")
        let point = InputLocation(screenPoint: .zero, windowPointFromTop: .zero)
        let platform = choice.platform(for: "com.adobe.Photoshop")
        #expect(platform.preparation(for: .click(point)) == .internalAppKitState)
        let selectAll = InputCommand.key(virtualKey: 0, text: "", modifiers: .command,
            origin: CharacterShortcutOrigin(character: "a", effectiveModifiers: .command,
                                            commandPlane: true, requiresShift: false))
        #expect(platform.preparation(for: selectAll) == .internalAppKitState)
        #expect(platform.preparation(for: .key(virtualKey: 36, text: "\r")) == .none)
        #expect(platform.preparation(for: .insertText("100")) == .none)
        #expect(platform.preparation(for: .key(virtualKey: 45, text: "", modifiers: [.command, .shift],
            origin: CharacterShortcutOrigin(character: "n", effectiveModifiers: [.command, .shift],
                                            commandPlane: true, requiresShift: false))) == .none)
        #expect(platform.preparation(for: .click(point, button: .right)) == .none)
        #expect(choice.platform(for: "com.adobe.InDesign").preparation(for: .click(point)) == .none)
        #expect(choice.platform(for: nil).preparation(for: .click(point)) == .none)
        #expect(TargetPlatform.unmeasured.platform(for: "com.adobe.Photoshop")
            .preparation(for: .click(point)) == .none)
    }

    @Test("an application nobody has measured is driven without preparation")
    func unknownApplicationIsAppKit() throws {
        let plain = try Self.bundle()
        let choice = TargetPlatform.chosen(
            bundleURL       : plain,
            bundleIdentifier: "com.markedit.MarkEdit"
        )
        #expect(choice == .unmeasured)
        // Nothing known is not evidence of a renderer, and preparing on no
        // evidence is what took the person's focus.
        #expect(choice.platform is AppKitPlatform)

        #expect(TargetPlatform.chosen(bundleURL: nil, bundleIdentifier: nil) == .unmeasured)
        #expect(TargetPlatform.chosen(bundleURL: nil, bundleIdentifier: "com.apple.finder")
            == .appleNative)
    }

    @Test("the renderer is the one branch whose clicks are prepared")
    func onlyTheRendererIsPrepared() {
        let prepared = [
            TargetPlatform.embeddedRenderer(.framework),
            .embeddedRenderer(.rendererHelper),
            .qtToolkit,
            .adobeUXP,
            .appleNative,
            .unmeasured,
        ]
            .filter { $0.platform is ChromiumPlatform }
        #expect(prepared == [.embeddedRenderer(.framework), .embeddedRenderer(.rendererHelper)])
    }

    @Test("an Electron bundle's renderer helper is evidence of a renderer on its own")
    func rendererHelperInFrameworksIsChromium() throws {
        let electron = try Self.bundle(embedding: ["Row Helper (Renderer).app"])
        let choice = TargetPlatform.chosen(
            bundleURL       : electron,
            bundleIdentifier: "com.example.electron"
        )
        #expect(choice == .embeddedRenderer(.rendererHelper))
        #expect(choice.platform is ChromiumPlatform)
        #expect(choice.reason.contains("renderer helper"))
    }

    @Test("Chrome's renderer helper inside its own framework is evidence of a renderer")
    func rendererHelperInsideAFrameworkIsChromium() throws {
        // Google Chrome ships neither known framework: its helper is the evidence.
        let flat = try Self.bundle(embedding: ["Row Framework.framework/Helpers/Row Helper (Renderer).app"])
        #expect(TargetPlatform.chosen(bundleURL: flat, bundleIdentifier: "com.google.Chrome")
            == .embeddedRenderer(.rendererHelper))

        // The real layout: `Helpers` is a symlink to `Versions/Current/Helpers`.
        let linked    = try Self.bundle()
        let framework = linked.appendingPathComponent("Contents/Frameworks/Row Framework.framework")
        try FileManager.default.createDirectory(
            at                         : framework.appendingPathComponent("Versions/1.0/Helpers/Row Helper (Renderer).app"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath             : framework.appendingPathComponent("Versions/Current").path,
            withDestinationPath: "1.0"
        )
        try FileManager.default.createSymbolicLink(
            atPath             : framework.appendingPathComponent("Helpers").path,
            withDestinationPath: "Versions/Current/Helpers"
        )
        let choice = TargetPlatform.chosen(
            bundleURL       : linked,
            bundleIdentifier: "com.google.Chrome"
        )
        #expect(choice == .embeddedRenderer(.rendererHelper))
        #expect(choice.platform is ChromiumPlatform)
    }

    @Test("a helper that is not the renderer's is not evidence of a renderer")
    func otherHelpersAreNotARenderer() throws {
        let helpers = try Self.bundle(embedding: [
            "Row Helper.app",
            "Row Helper (GPU).app",
            "Row Framework.framework/Helpers/Row Helper (Plugin).app",
        ])
        #expect(TargetPlatform.chosen(bundleURL: helpers, bundleIdentifier: "com.example.helpers")
            == .unmeasured)
    }

    @Test("an Apple application that embeds a renderer is that renderer")
    func embeddedRendererOutranksTheAppleIdentifier() throws {
        // The rules are in evidence order: a renderer found in the bundle is
        // what the measurement is about, whoever shipped the bundle.
        let bundle = try Self.bundle(embedding: ["Electron Framework.framework"])
        #expect(TargetPlatform.chosen(bundleURL: bundle, bundleIdentifier: "com.apple.example")
            == .embeddedRenderer(.framework))
    }
}
