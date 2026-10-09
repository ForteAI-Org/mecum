//
//  TargetPlatform.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 18/09/2026.
//

import Foundation
import SeatInput

/// Which preparation recipe one application is driven with, and the evidence
/// that chose it.
///
/// The lab used to hand every application `.universal`, which is
/// `ChromiumPlatform`: that recipe prepares every click, drag and bulk
/// insertion by making the target's own window briefly believe it is key. A
/// Chromium renderer needs it, since it drops a click from a window it does not
/// consider key. A native application does not, and the preparation is what
/// makes it believe it is active, raises `targetActivated` and sets the focus
/// recovery off. Driving Finder that way took the person's focus over and over.
///
/// The preparation is what is now asked for by positive evidence, and it is the
/// other way round from what this file used to say. The default was Chromium on
/// the argument that it is the safe superset, and it is not one: preparing a
/// native application writes an activation record and two key-window records
/// into it on every click, drag and insertion, which is exactly the recipe the
/// kit's own note describes as making that application believe it is active and
/// taking the focus off the person. An unprepared click on a renderer that
/// wants one is dropped and the agent looks again, which costs a decision; a
/// prepared click on an application that wants none takes the keyboard away
/// from whoever is sitting there, which costs the person their work. The
/// asymmetry is the whole rule, so the evidence has to point at a renderer.
///
/// In evidence order:
///
/// 1. the bundle embeds a Chromium renderer, which is the renderer the
///    measurement is about, whoever shipped the bundle, and the one case whose
///    clicks are prepared. The evidence is either the Electron or the Chromium
///    Embedded Framework under `Contents/Frameworks`, or a renderer helper,
///    `<name> Helper (Renderer).app`, in either place Chromium puts one: directly
///    in `Contents/Frameworks`, as every Electron application on the Mac this was
///    written on does (Slack), or in the `Helpers` folder of a framework there,
///    as Google Chrome does in `Google Chrome Framework.framework/Helpers`, a
///    symlink to `Versions/Current/Helpers`. Chrome ships neither framework, so
///    the helper is what finds it. Edge, Brave, Vivaldi and Chromium itself are
///    expected to follow Chrome's layout, but none was installed to check;
/// 2. the bundle ships Qt's core library, as the framework `macdeployqt`
///    bundles or as the dylib Qt 5 and 6 builds also ship, which DaVinci
///    Resolve does: it is driven with `QtPlatform`, the recipe measured on
///    DaVinci and an owned Qt 6 fixture (Documentation/Driver/platforms/Qt.md), whose
///    clicks are unprepared, since a prepared one activated a followed dialog,
///    whose bulk insertion stays unprepared to preserve Qt Quick focus, and
///    which keeps the window follower awake a second after a click for the
///    native panels Qt opens late;
///    the bundle ships Adobe's UXP host, `dvauxphost.framework`, which Photoshop
///    does: it is driven with `UXPPlatform`, whose attested modal keys use
///    recipient priming. Photoshop also selects the measured document-click
///    recipe; the seat removes that recipe from modal surfaces;
/// 3. the bundle identifier is Safari's, which draws its pages in WebKit and,
///    measured on 09/10/2026 on macOS 27, drops a click, a drag and a bulk
///    insertion from a window its process does not consider key, as a
///    renderer does, while scroll passes (ADR 0038). It is driven with the
///    renderer's preparation and is no embedded renderer: the evidence is the
///    exact identifier, as for Chrome's native composition and Photoshop's
///    clicks;
/// 4. the bundle identifier is Apple's, and Apple ships its applications in
///    AppKit, Finder included;
/// 5. nothing is known, and nothing known is not a renderer: an application
///    nobody has measured is driven without preparation, like the native one.
///
/// **The known limit**: a Chromium-based application that ships neither known
/// framework and no renderer helper in those two places reads as rule 4, or as
/// rule 3 when Apple shipped it, and is driven unprepared. That is not one lost
/// click: on Chrome every unprepared click failed in the kit's measurement
/// (`ChromiumPlatform`), and drags and multi-character key events are dropped
/// the same way, so such an application cannot be driven into from behind.
/// The log line names the platform and the reason, which is where it shows.
enum TargetPlatform: Sendable, Equatable {

    /// Rule 1: a renderer found inside the bundle, and what found it.
    case embeddedRenderer(RendererEvidence)

    /// Rule 2: Qt's core library found inside the bundle.
    case qtToolkit

    /// Rule 2, second half: Adobe's UXP host found inside the bundle.
    case adobeUXP

    /// Rule 3: Safari's bundle identifier, WebKit's page content (ADR 0038).
    case webKitBrowser

    /// Rule 4: an Apple bundle identifier.
    case appleNative

    /// Rule 5: no evidence either way, which is not evidence of a renderer.
    case unmeasured

    /// What inside the bundle said it is a Chromium renderer. It is carried
    /// into `reason`, because the log line is how a choice is diagnosed.
    enum RendererEvidence: Sendable, Equatable {

        /// One of `renderers` under `Contents/Frameworks`.
        case framework

        /// A `<name> Helper (Renderer).app` where Chromium puts it.
        case rendererHelper
    }

    /// The frameworks that say the window is drawn by a Chromium renderer.
    /// Electron ships the first and every CEF host ships the second.
    private static let renderers = [
        "Electron Framework.framework",
        "Chromium Embedded Framework.framework",
    ]

    /// The one bundle identifier ADR 0038 measured. Safari Technology Preview and
    /// other WebKit shells are not covered until each is measured.
    static let safariBundleIdentifier = "com.apple.Safari"

    /// What says the interface is drawn by Adobe's UXP host.
    private static let uxpHosts = ["dvauxphost.framework"]

    /// What says the window is drawn by Qt: the core framework of a
    /// `macdeployqt` bundle, or the core dylib of a Qt 5 or Qt 6 build.
    private static let qtLibraries = [
        "QtCore.framework",
        "libQt5Core.5.dylib",
        "libQt6Core.6.dylib",
    ]

    /// The choice for one application, from what `NSRunningApplication` already
    /// answers about it. Both readings are optional because both are, and a
    /// reading that is missing is not evidence.
    ///
    /// It is a few file existence checks, a listing of `Contents/Frameworks` and
    /// of each framework's `Helpers` in it, and a string prefix: nothing is
    /// enumerated recursively and no plist or binary is read. It takes no lock,
    /// launches nothing and throws nothing, which is what lets an adoption ask
    /// for it inline.
    static func chosen(bundleURL: URL?, bundleIdentifier: String?) -> TargetPlatform {
        if let bundleURL, frameworks(of: bundleURL, contain: renderers) { return .embeddedRenderer(.framework) }
        if let bundleURL, shipsRendererHelper(bundleURL) { return .embeddedRenderer(.rendererHelper) }
        if let bundleURL, frameworks(of: bundleURL, contain: qtLibraries) { return .qtToolkit }
        if let bundleURL, frameworks(of: bundleURL, contain: uxpHosts) { return .adobeUXP }
        if bundleIdentifier == Self.safariBundleIdentifier { return .webKitBrowser }
        if bundleIdentifier?.hasPrefix("com.apple.") == true { return .appleNative }
        return .unmeasured
    }

    /// The platform the seat is handed. Only the renderer's and Safari's
    /// clicks are prepared; `AppKitPlatform` prepares nothing and is what the
    /// Apple and the unmeasured cases answer. Safari takes `ChromiumPlatform`
    /// as is: the same three Commands are prepared and keys and scroll are not.
    var platform: any InputPlatform {
        switch self {
            case .embeddedRenderer, .webKitBrowser: ChromiumPlatform()
            case .qtToolkit                       : QtPlatform()
            case .adobeUXP                        : UXPPlatform()
            case .appleNative, .unmeasured        : AppKitPlatform()
        }
    }

    /// Selects measured host features only after positive family and bundle evidence.
    /// Photoshop document preparation excludes attested modals. Chrome admits
    /// bounded native input; other UXP and renderer hosts retain family policy.
    func platform(for bundleIdentifier: String?) -> any InputPlatform {
        if case .embeddedRenderer = self, bundleIdentifier == "com.google.Chrome" {
            return ChromiumPlatform(nativeTextInputIsQualified: true)
        }
        guard self == .adobeUXP, bundleIdentifier == "com.adobe.Photoshop" else { return platform }
        return UXPPlatform().preparingLeftClicks.preparingDocumentShortcuts
    }

    /// The chosen platform's own name. Derived from `platform` rather than
    /// written out again, so the log line cannot come to say one thing while
    /// the seat is handed another.
    var platformName: String { "\(type(of: platform))" }

    /// Which rule decided, in the words the log line uses. A choice nobody can
    /// read back is a choice nobody can diagnose.
    var reason: String {
        switch self {
            case .embeddedRenderer(.framework)     : "the bundle embeds a Chromium renderer framework"
            case .embeddedRenderer(.rendererHelper): "the bundle ships a Chromium renderer helper"
            case .qtToolkit                        : "the bundle ships Qt"
            case .adobeUXP                         : "the bundle ships Adobe's UXP host"
            case .webKitBrowser                    : "the bundle is Safari, whose web content drops unprepared clicks"
            case .appleNative                      : "the bundle identifier is Apple's"
            case .unmeasured                       : "nothing in the bundle says it is a renderer"
        }
    }

    /// Whether the bundle's Contents/Frameworks holds any of `names`.
    private static func frameworks(
        of bundleURL: URL,
        contain names: [String]
    ) -> Bool {
        let frameworks = bundleURL.appending(path: "Contents/Frameworks")
        return names.contains {
            FileManager.default.fileExists(atPath: frameworks.appending(path: $0).path)
        }
    }

    /// Whether the bundle ships a Chromium renderer helper, directly in
    /// Contents/Frameworks or in the `Helpers` of a framework there. A folder
    /// that cannot be listed is a reading that is missing, not evidence.
    private static func shipsRendererHelper(_ bundleURL: URL) -> Bool {
        let frameworks = bundleURL.appending(path: "Contents/Frameworks")
        let entries    = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        if entries.contains(where: isRendererHelper) { return true }
        return entries.filter { $0.hasSuffix(".framework") }.contains { framework in
            let helpers = frameworks.appending(path: framework).appending(path: "Helpers")
            let names   = (try? FileManager.default.contentsOfDirectory(atPath: helpers.path)) ?? []
            return names.contains(where: isRendererHelper)
        }
    }

    /// Chromium's renderer helper, which only a Chromium renderer ships. The
    /// GPU, plugin and plain helpers ship beside it and say nothing on their own.
    private static func isRendererHelper(_ name: String) -> Bool {
        name.hasSuffix(" Helper (Renderer).app")
    }
}
