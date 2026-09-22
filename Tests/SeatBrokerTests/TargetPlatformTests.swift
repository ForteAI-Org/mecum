//
//  TargetPlatformTests.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/09/2026.
//

import Foundation
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
        #expect(choice == .embeddedRenderer)
        #expect(choice.platform is ChromiumPlatform)

        let cef = try Self.bundle(embedding: ["Chromium Embedded Framework.framework"])
        #expect(TargetPlatform.chosen(bundleURL: cef, bundleIdentifier: "com.example.cef")
            == .embeddedRenderer)
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

    @Test("the renderer is the one branch of the three that is prepared")
    func onlyTheRendererIsPrepared() {
        let prepared = [TargetPlatform.embeddedRenderer, .appleNative, .unmeasured]
            .filter { $0.platform is ChromiumPlatform }
        #expect(prepared == [.embeddedRenderer])
    }

    @Test("an Apple application that embeds a renderer is that renderer")
    func embeddedRendererOutranksTheAppleIdentifier() throws {
        // The rules are in evidence order: a renderer found in the bundle is
        // what the measurement is about, whoever shipped the bundle.
        let bundle = try Self.bundle(embedding: ["Electron Framework.framework"])
        #expect(TargetPlatform.chosen(bundleURL: bundle, bundleIdentifier: "com.apple.example")
            == .embeddedRenderer)
    }
}
