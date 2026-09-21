//
//  TargetPlatform.swift
//  AgentLab
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
/// 1. the bundle embeds Electron or the Chromium Embedded Framework, which is
///    the renderer the measurement is about, whoever shipped the bundle, and
///    the one case that is prepared;
/// 2. the bundle identifier is Apple's, and Apple ships its applications in
///    AppKit, Finder included;
/// 3. nothing is known, and nothing known is not a renderer: an application
///    nobody has measured is driven without preparation, like the native one.
///
/// **The known limit**: a Chromium-based browser that ships neither framework
/// under `Contents/Frameworks` reads as rule 3 and is driven unprepared, so its
/// first click on a window it does not consider key is dropped. That is visible
/// in the step history, it costs one decision, and it is the side this rule
/// deliberately errs on.
enum TargetPlatform: Sendable, Equatable {

    /// Rule 1: a renderer found inside the bundle.
    case embeddedRenderer

    /// Rule 2: an Apple bundle identifier.
    case appleNative

    /// Rule 3: no evidence either way, which is not evidence of a renderer.
    case unmeasured

    /// The frameworks that say the window is drawn by a Chromium renderer.
    /// Electron ships the first and every CEF host ships the second.
    private static let renderers = [
        "Electron Framework.framework",
        "Chromium Embedded Framework.framework",
    ]

    /// The choice for one application, from what `NSRunningApplication` already
    /// answers about it. Both readings are optional because both are, and a
    /// reading that is missing is not evidence.
    ///
    /// It is a file existence check and a string prefix: it takes no lock,
    /// launches nothing and throws nothing, which is what lets an adoption ask
    /// for it inline.
    static func chosen(bundleURL: URL?, bundleIdentifier: String?) -> TargetPlatform {
        if let bundleURL, embedsRenderer(bundleURL) { return .embeddedRenderer }
        if bundleIdentifier?.hasPrefix("com.apple.") == true { return .appleNative }
        return .unmeasured
    }

    /// The platform the seat is handed. Only the renderer is prepared;
    /// `AppKitPlatform` prepares nothing and is what the other two answer.
    var platform: any InputPlatform {
        self == .embeddedRenderer ? ChromiumPlatform() : AppKitPlatform()
    }

    /// The chosen platform's own name. Derived from `platform` rather than
    /// written out again, so the log line cannot come to say one thing while
    /// the seat is handed another.
    var platformName: String { "\(type(of: platform))" }

    /// Which rule decided, in the words the log line uses. A choice nobody can
    /// read back is a choice nobody can diagnose.
    var reason: String {
        switch self {
            case .embeddedRenderer: "the bundle embeds a Chromium renderer"
            case .appleNative     : "the bundle identifier is Apple's"
            case .unmeasured      : "nothing in the bundle says it is a renderer"
        }
    }

    private static func embedsRenderer(_ bundleURL: URL) -> Bool {
        let frameworks = bundleURL.appending(path: "Contents/Frameworks")
        return renderers.contains {
            FileManager.default.fileExists(atPath: frameworks.appending(path: $0).path)
        }
    }
}
