import Foundation

/// Resolves the on-disk locations Locator owns. Production code uses ``descriptorsDir()``; tests
/// inject their own temp directory into ``DescriptorStore``/``CropStore`` and never touch this.
public enum DescriptorPaths {
    /// `~/Library/Application Support/Locator/descriptors/`, created lazily.
    public static func descriptorsDir(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Locator/descriptors", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Application Support/Locator/flows/`, created lazily.
    public static func flowsDir(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Locator/flows", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Application Support/Locator/debug/`, created lazily — where `run … debug` drops its
    /// per-step relocation artifacts (window / overlay / found / template + manifest.json).
    public static func debugDir(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Locator/debug", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Application Support/Locator/knowledge/`, created lazily — the ambient UI knowledge base
    /// (`<bundleID>.json` per observed app + `allowlist.json`).
    public static func knowledgeDir(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Locator/knowledge", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `./icon-library/` in the CURRENT WORKING DIRECTORY (the project/repo when run from there) — the
    /// labelled ICON database (`<bundleID>.json` per app + `crops/<uuid>.png`). Deliberately project-local
    /// (not `~/Library`) so it's SHAREABLE: commit it, zip it, hand it to a teammate. Run `peek --collect`
    /// and `label` from the same directory so both see the same library.
    public static func iconsDir(fileManager: FileManager = .default) throws -> URL {
        // Resolution order, chosen so BOTH launch contexts work:
        //   1. LOCATOR_ICON_DIR (a usable absolute/~-path) — a CLI or MCP host pins the shared library.
        //   2. ./icon-library, but ONLY when cwd is the repo (a real icon-library already sits there) —
        //      keeps the shareable project-local library when run from the checkout.
        //   3. ~/Library/Application Support/Locator/icon-library — the writable fallback for a GUI host
        //      (Claude Desktop launches the engine with cwd "/", so "./icon-library" = "/icon-library"
        //      is UNWRITABLE; and an MCPB manifest may hand us a literal unexpanded "${HOME}/…" path).
        //      This is what fixes the "cannot resolve local data directories" error under Claude Desktop.
        let env = ProcessInfo.processInfo.environment["LOCATOR_ICON_DIR"]
        if let env, !env.isEmpty, !env.contains("${") {                 // reject unexpanded manifest tokens
            let expanded = (env as NSString).expandingTildeInPath        // honor a leading ~
            let dir = URL(fileURLWithPath: expanded, isDirectory: true)
            if (try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)) != nil {
                return dir
            }
            // fall through to the writable default if the pinned path can't be created
        }
        let cwdLibrary = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("icon-library", isDirectory: true)
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: cwdLibrary.path, isDirectory: &isDir), isDir.boolValue {
            return cwdLibrary                                           // repo checkout: use the shared library
        }
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = appSupport.appendingPathComponent("Locator/icon-library", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<icon-library-parent>/behavior/` — the user-behavior log (`events.ndjson`) + LLM-labeled
    /// `workflows.json`. Sits beside the icon library so it shares the same root (and `LOCATOR_ICON_DIR`),
    /// staying project-local and shareable.
    public static func behaviorDir(fileManager: FileManager = .default) throws -> URL {
        let dir = try iconsDir(fileManager: fileManager).deletingLastPathComponent()
            .appendingPathComponent("behavior", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
