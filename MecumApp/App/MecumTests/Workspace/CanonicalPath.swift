//
//  CanonicalPath.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 03/10/2026.
//

import Darwin
import Foundation

/// CanonicalPath is a file URL as the file system names it, compared by components: the longest
/// ancestor that exists is resolved by `realpath(3)`, so `/tmp` and `/private/tmp` are one directory and
/// a symbolic link that leaves a directory is seen leaving it, and the components that do not exist yet
/// follow as written. A file or directory created between two readings therefore does not change what a
/// path is. `URL ==` compares spellings, and `resolvingSymlinksInPath()` gives `/tmp/…` for one path and
/// `/private/tmp/…` for another depending on what exists, so neither is used to compare directories.
///
/// Containment is by whole components, never by string prefix: `…/Support-other` is not inside
/// `…/Support`. Kept apart from the tests and on Foundation alone so the same source can be compiled and
/// run outside the app's test host.
struct CanonicalPath: Equatable, CustomStringConvertible {

    /// The components from the root, `"/"` first.
    let components: [String]

    /// The file system's own identity of the path when it exists: device and inode.
    let identity: FileIdentity?

    /// Device and inode, which name one file whatever the path that reached it.
    struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    init(_ url: URL) {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        let resolved = existing.path.withCString { realpath($0, nil) }.map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? existing.path
        components = URL(fileURLWithPath: resolved).pathComponents + missing.reversed()
        var status = stat()
        identity = missing.isEmpty && stat(resolved, &status) == 0
            ? FileIdentity(device: status.st_dev, inode: status.st_ino)
            : nil
    }

    init(path: String) { self.init(URL(fileURLWithPath: path)) }

    var path: String { NSString.path(withComponents: components) }

    var description: String { path }

    /// The same path by components and, when both exist, the same file by identity.
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.components == rhs.components else { return false }
        guard let left = lhs.identity, let right = rhs.identity else { return true }
        return left == right
    }

    /// True when this path is `root` or lies under it, component by component.
    func isWithin(_ root: CanonicalPath) -> Bool {
        components.count >= root.components.count && Array(components.prefix(root.components.count)) == root.components
    }

    /// This path with `names` appended, the way `URL.appending(path:)` would, canonicalized again.
    func appending(_ names: String...) -> CanonicalPath {
        CanonicalPath(path: NSString.path(withComponents: components + names))
    }
}
