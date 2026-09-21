import Foundation

/// Where Locator INSTALLS itself: the engine bundle, the run-path symlink, logs and fixtures.
///
/// Separate from ``DescriptorPaths``, which owns the DATA (`~/Library/Application Support/Locator`).
/// This is only about the executable and its run-time scaffolding.
///
/// The root is `~/.fflow`, deliberately NOT `~/.forte`: that directory belongs to the shipping FManager
/// product, and sharing it means an FManager install/update can take Locator's binary with it — which is
/// exactly what happened (`~/.forte/bin` vanished and every MCP client failed to connect). One product per
/// root, so neither can delete the other.
///
/// Every path is derived here, never spelled as a string literal elsewhere, so moving the root again is a
/// one-line change instead of a grep-and-pray.
public enum InstallPaths {
    /// `~/.fflow` — the install root. Locator owns this directory exclusively.
    public static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".fflow", isDirectory: true)
    }

    /// `~/.fflow/bin` — holds the `locator` symlink that everything execs.
    public static var binDir: URL { root.appendingPathComponent("bin", isDirectory: true) }

    /// `~/.fflow/bin/locator` — THE run path. A symlink into the engine bundle. Never run `.build/...`
    /// directly: TCC grants attach to this stable path, and a rebuild-churned `.build` identity hangs
    /// captures.
    public static var binary: URL { binDir.appendingPathComponent("locator") }

    /// `~/.fflow/Forte Locator Engine.app` — the engine as a real app bundle, so TCC keys its
    /// Screen-Recording grant on the stable CFBundleIdentifier rather than a per-build signature.
    /// Named distinctly from the user-facing "Forte Locator.app" GUI so the two never collide in the
    /// permission lists — only the engine needs Screen Recording.
    public static var engineApp: URL {
        root.appendingPathComponent("Forte Locator Engine.app", isDirectory: true)
    }

    /// The engine bundle's actual executable — what ``binary`` points at.
    public static var engineExecutable: URL {
        engineApp.appendingPathComponent("Contents/MacOS/locator")
    }

    /// `~/.fflow/logs` — engine stderr lands here (`engine.log`) so Apple's SCK continuation-leak
    /// warnings never flood a chat UI.
    public static var logsDir: URL { root.appendingPathComponent("logs", isDirectory: true) }

    /// `~/.fflow/fixtures` — frozen screenshots for `scripts/check-fixtures.sh`. Kept OUT of the repo:
    /// the Slack capture contains private messages.
    public static var fixturesDir: URL { root.appendingPathComponent("fixtures", isDirectory: true) }

    /// `~/.fflow/.signing-identity` — remembers which certificate the install was signed with.
    ///
    /// Without this, re-installing after the bundle is gone falls back to "first Apple Development cert in
    /// the keychain", which is keychain-order dependent. Picking a different cert changes the code
    /// signature's designated requirement, so macOS treats it as a DIFFERENT app and the existing Screen
    /// Recording grant silently stops applying. Persisting the choice keeps the TCC identity stable even
    /// if the bundle is deleted.
    public static var signingIdentityRecord: URL { root.appendingPathComponent(".signing-identity") }
}
